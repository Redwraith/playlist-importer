import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Spotify Web API with the official PKCE login: no client secret, tokens only in the Keychain.
/// Endpoints after the February 2026 changes: POST /me/playlists, POST /playlists/{id}/items.
@MainActor
final class Spotify: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case notConfigured, cancelled, http(Int, String), noToken
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Client ID Spotify mancante."
            case .cancelled: "Accesso a Spotify annullato."
            case .noToken: "Accedi a Spotify."
            case .http(let code, let message):
                code == 403 ? "Spotify ha rifiutato l'operazione (403): l'account deve essere tra gli utenti dell'app sviluppatore e avere Premium. \(message)"
                            : "Errore Spotify \(code): \(message)"
            }
        }
    }

    private let clientID = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
    private let redirectURI = Bundle.main.object(forInfoDictionaryKey: "SpotifyRedirectURI") as? String ?? ""
    private let scope = "playlist-modify-private"
    private let api = URL(string: "https://api.spotify.com/v1")!
    private let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    @Published private(set) var isLoggedIn = Keychain.read("refresh") != nil
    private var accessToken: String?
    private var expiry = Date.distantPast

    // MARK: Login (PKCE)

    func login() async throws {
        guard !clientID.isEmpty, let scheme = URL(string: redirectURI)?.scheme else { throw Failure.notConfigured }
        let verifier = Self.randomVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: scope),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) } else {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    cont.resume(throwing: cancelled ? Failure.cancelled : (error ?? Failure.cancelled))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw Failure.cancelled }
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                         "client_id": clientID, "code_verifier": verifier])
    }

    func logout() {
        Keychain.delete("refresh")
        accessToken = nil
        isLoggedIn = false
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private func token(_ form: [String: String]) async throws {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            if form["grant_type"] == "refresh_token" { logout() }
            throw Failure.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        accessToken = access
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { Keychain.save("refresh", refresh) }
        isLoggedIn = true
    }

    private func validToken() async throws -> String {
        if let accessToken, Date() < expiry { return accessToken }
        guard let refresh = Keychain.read("refresh") else { throw Failure.noToken }
        try await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let accessToken else { throw Failure.noToken }
        return accessToken
    }

    // MARK: API

    /// One request with the bearer token; waits on 429 (Retry-After) and refreshes once on 401.
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        for attempt in 1...4 {
            let bearer = try await validToken()
            var request = URLRequest(url: c.url!)
            request.httpMethod = method
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200...299:
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            case 429 where attempt < 4:
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt * 2)
                try await Task.sleep(for: .seconds(min(wait, 30)))
            case 401 where attempt < 4:
                accessToken = nil
            default:
                let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
                throw Failure.http(http?.statusCode ?? 0, message)
            }
        }
        throw Failure.http(429, "troppe richieste, riprova tra poco")
    }

    /// Up to 10 tracks (the Development Mode limit). Field search first, plain text if it finds nothing.
    func search(artist: String, title: String) async throws -> [Track] {
        let base = Matcher.baseTitle(title)
        let precise = try await searchTracks("track:\"\(base)\" artist:\"\(artist)\"")
        if !precise.isEmpty { return precise }
        return try await searchTracks("\(artist) \(base)")
    }

    func searchTracks(_ query: String) async throws -> [Track] {
        let json = try await send("GET", "search", query: [.init(name: "q", value: query), .init(name: "type", value: "track"),
                                                           .init(name: "limit", value: "10")])
        let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String, let uri = item["uri"] as? String, let name = item["name"] as? String else { return nil }
            let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let album = (item["album"] as? [String: Any])?["name"] as? String ?? ""
            return Track(id: id, uri: uri, name: name, artists: artists, album: album)
        }
    }

    /// Creates a private playlist and adds the tracks in the given order, 100 at a time (appending keeps order).
    func createPlaylist(name: String, uris: [String]) async throws -> (id: String, url: URL?) {
        let created = try await send("POST", "me/playlists", body: ["name": name, "public": false,
                                                                     "description": "Creata con Playlist Importer"])
        guard let id = created["id"] as? String else { throw Failure.http(0, "playlist senza id") }
        for start in stride(from: 0, to: uris.count, by: 100) {
            let chunk = Array(uris[start..<min(start + 100, uris.count)])
            _ = try await send("POST", "playlists/\(id)/items", body: ["uris": chunk])
        }
        let web = (created["external_urls"] as? [String: Any])?["spotify"] as? String
        return (id, web.flatMap(URL.init(string:)))
    }

    static func randomVerifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// The refresh token, in the iPhone Keychain only.
enum Keychain {
    private static let service = "app.playlistimporter.spotify"

    static func save(_ key: String, _ value: String) {
        delete(key)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
