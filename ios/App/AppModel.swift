import Foundation
import UIKit

/// The whole workflow: paste -> analyze -> fix -> Spotify / Demus. Order is the input order, always.
@MainActor
final class AppModel: ObservableObject {
    enum Step { case input, summary, review, destination, spotify, done, demus }

    struct Item: Identifiable {
        let line: Matcher.Line
        var status: Matcher.Status
        var chosen: Track?
        var alternatives: [Track]
        var skipped = false
        var id: Int { line.index }
    }

    @Published var text = ""
    @Published var step: Step = .input
    @Published var items: [Item] = []
    @Published var invalid: [Matcher.Invalid] = []
    @Published var progress = 0
    @Published var busy = false
    @Published var error: String?
    @Published var playlistName = ""
    @Published var created: (id: String, url: URL?)?
    @Published var createdCount = 0

    let spotify = Spotify()

    /// The rock/metal playlist (165 songs) that ships with the app: filled in on first launch.
    static let bundledPlaylist: String = {
        guard let url = Bundle.main.url(forResource: "rock_metal_165", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    init() {
        if !UserDefaults.standard.bool(forKey: "bundledPlaylistShown") {
            text = Self.bundledPlaylist
            UserDefaults.standard.set(true, forKey: "bundledPlaylistShown")
        }
    }

#if DEBUG
    /// Screenshots in the simulator: `-screenshotStep summary` shows that screen with sample results
    /// built from the bundled playlist (no Spotify login in the simulator). Debug builds only.
    func applyScreenshotStep() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotStep"), i + 1 < args.count else { return }
        text = Self.bundledPlaylist
        let lines = Matcher.parse(text).lines
        func track(_ line: Matcher.Line, _ name: String? = nil) -> Track {
            Track(id: "\(line.index)-\(name ?? line.title)", uri: "spotify:track:\(line.index)", name: name ?? line.title,
                  artists: [line.artist], album: "Album")
        }
        items = lines.map { line in
            switch line.index {
            case 19:  // the typo: Funeraloplis
                return Item(line: line, status: .verify, chosen: nil,
                            alternatives: [track(line, "Funeralopolis"), track(line, "Funeralopolis - Live")])
            case 90:  // Obscura with "The"
                return Item(line: line, status: .verify, chosen: nil, alternatives: [track(line, "Anticosmic Overload")])
            case 112:
                return Item(line: line, status: .missing, chosen: nil, alternatives: [])
            default:
                return Item(line: line, status: .found, chosen: track(line), alternatives: [])
            }
        }
        playlistName = "THE HEAVY ARCHIVE"
        switch args[i + 1] {
        case "summary": step = .summary
        case "review": step = .review
        case "destination", "spotify", "done", "demus":
            for item in pending { if let first = item.alternatives.first { choose(first, for: item) } else { skip(item) } }
            switch args[i + 1] {
            case "destination": step = .destination
            case "spotify": step = .spotify
            case "done":
                created = ("demo", URL(string: "https://open.spotify.com/playlist/demo"))
                createdCount = readyTracks.count
                step = .done
            default: step = .demus
            }
        default: step = .input
        }
    }
#endif

    func loadBundledPlaylist() {
        text = Self.bundledPlaylist
        invalid = []
    }

    var lineCount: Int { Matcher.parse(text).lines.count }

    /// A duplicate follows the song it repeats: fixing one fixes both.
    func source(_ item: Item) -> Item { item.line.duplicateOf.map { items[$0] } ?? item }

    func status(_ item: Item) -> Matcher.Status { source(item).status }

    /// The track that goes in the playlist for this line, or nil (not resolved, or skipped).
    func resolved(_ item: Item) -> Track? {
        let s = source(item)
        return s.status == .found && !s.skipped ? s.chosen : nil
    }

    func count(_ status: Matcher.Status) -> Int { items.filter { self.status($0) == status && !source($0).skipped }.count }

    /// Lines the user still has to look at (duplicates follow their first occurrence).
    var pending: [Item] { items.filter { $0.line.duplicateOf == nil && $0.status != .found && !$0.skipped } }

    var readyTracks: [Track] { items.compactMap(resolved) }

    // MARK: Analyze

    func analyze() async {
        error = nil
        let parsed = Matcher.parse(text)
        invalid = parsed.invalid
        guard !parsed.lines.isEmpty else { error = "Incolla almeno una riga nel formato Artista - Titolo."; return }
        if !spotify.isLoggedIn {
            do { try await spotify.login() } catch { self.error = error.localizedDescription; return }
        }
        busy = true
        progress = 0
        defer { busy = false }
        var results = [Item?](repeating: nil, count: parsed.lines.count)
        let unique = parsed.lines.filter { $0.duplicateOf == nil }
        do {
            // 4 searches at a time; results are stored by position, so order never depends on timing
            for start in stride(from: 0, to: unique.count, by: 4) {
                let batch = Array(unique[start..<min(start + 4, unique.count)])
                let found = try await withThrowingTaskGroup(of: (Int, [Track]).self) { group in
                    for line in batch {
                        group.addTask { [spotify] in (line.index, try await spotify.search(artist: line.artist, title: line.title)) }
                    }
                    var out: [(Int, [Track])] = []
                    for try await pair in group { out.append(pair) }
                    return out
                }
                for (index, tracks) in found {
                    let line = parsed.lines[index]
                    let decision = Matcher.decide(line, tracks)
                    results[index] = Item(line: line, status: decision.status, chosen: decision.chosen, alternatives: decision.alternatives)
                }
                progress = min(start + batch.count, unique.count)
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        for line in parsed.lines where line.duplicateOf != nil {
            results[line.index] = Item(line: line, status: .found, chosen: nil, alternatives: [])
        }
        items = results.compactMap { $0 }
        step = .summary
    }

    // MARK: Review

    func choose(_ track: Track, for item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].chosen = track
        items[i].status = .found
        items[i].skipped = false
    }

    func skip(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].skipped = true
    }

    func manualSearch(_ query: String) async -> [Track] {
        do { return try await spotify.searchTracks(query) } catch { self.error = error.localizedDescription; return [] }
    }

    func next() {
        step = pending.isEmpty ? .destination : .review
    }

    // MARK: Spotify

    func createPlaylist() async {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { error = "Dai un nome alla playlist."; return }
        busy = true
        defer { busy = false }
        do {
            let tracks = readyTracks
            created = try await spotify.createPlaylist(name: name, uris: tracks.map(\.uri))
            createdCount = tracks.count
            step = .done
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openInSpotify() {
        guard let created else { return }
        let app = URL(string: "spotify:playlist:\(created.id)")!
        if UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web = created.url {
            UIApplication.shared.open(web)
        }
    }

    // MARK: Demus

    /// Demus has no documented import: the most useful output is the list in order, one song per line,
    /// with the names as Spotify wrote them when found (so searching them in Demus is exact).
    var demusText: String {
        items.map { item in
            if let t = resolved(item) { return "\(t.artists.first ?? item.line.artist) - \(t.name)" }
            return item.line.raw
        }.joined(separator: "\n")
    }

    func reset() {
        items = []
        invalid = []
        created = nil
        step = .input
    }
}
