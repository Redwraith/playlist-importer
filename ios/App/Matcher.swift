import Foundation

/// Parsing and matching, no network. Same rules as `core/matcher.py`, which has the reference tests.
enum Matcher {
    /// Words that mark a version that is not the studio original; they count against a candidate unless
    /// the user's line asks for them.
    static let variantWords: Set<String> = ["live", "remix", "acoustic", "instrumental", "remaster", "remastered",
                                            "edit", "version", "karaoke", "demo", "mix", "radio"]

    struct Line: Equatable {
        var index: Int
        var artist: String
        var title: String
        var raw: String
        var duplicateOf: Int?
    }

    struct Invalid: Equatable {
        var lineNumber: Int
        var text: String
    }

    /// Lowercase, no accents, only a-z and 0-9 separated by single spaces: "Sigur Rós" -> "sigur ros".
    static func normalize(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            let v = scalar.value
            let isWordChar = (97...122).contains(v) || (48...57).contains(v)   // a-z, 0-9
            if isWordChar {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The song name for comparison: "Hoppípolla (Live)" and "Symbolic - Live" -> "Hoppípolla", "Symbolic".
    static func baseTitle(_ title: String) -> String {
        let noBrackets = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        let head = noBrackets.components(separatedBy: " - ").first ?? noBrackets
        return head.trimmingCharacters(in: .whitespaces)
    }

    static func isVariant(_ title: String) -> Bool {
        !variantWords.isDisjoint(with: normalize(title).split(separator: " ").map(String.init))
    }

    /// "Artista - Titolo" per line, split on the first " - ". Order is kept; duplicates are kept and marked.
    static func parse(_ text: String) -> (lines: [Line], invalid: [Invalid]) {
        var lines: [Line] = []
        var invalid: [Invalid] = []
        var seen: [String: Int] = [:]
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let stripped = raw.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            guard let range = stripped.range(of: " - ") else {
                invalid.append(Invalid(lineNumber: offset + 1, text: stripped))
                continue
            }
            let artist = String(stripped[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(stripped[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty, !title.isEmpty else {
                invalid.append(Invalid(lineNumber: offset + 1, text: stripped))
                continue
            }
            let key = normalize(artist) + "|" + normalize(title)
            var line = Line(index: lines.count, artist: artist, title: title, raw: stripped)
            if let first = seen[key] { line.duplicateOf = first } else { seen[key] = line.index }
            lines.append(line)
        }
        return (lines, invalid)
    }

    static func artistMatches(_ wanted: String, _ found: String) -> Bool {
        let w = normalize(wanted), f = normalize(found)
        guard !w.isEmpty else { return false }
        return f == w || " \(f) ".contains(" \(w) ")
    }

    static func titleMatches(_ wanted: String, _ found: String) -> Bool {
        normalize(baseTitle(wanted)) == normalize(baseTitle(found))
    }

    static func score(_ line: Line, _ c: Track) -> Int {
        var s = 0
        if c.artists.contains(where: { artistMatches(line.artist, $0) }) { s += 10 }
        if titleMatches(line.title, c.name) { s += 10 }
        if isVariant(c.name) && !isVariant(line.title) { s -= 5 }
        return s
    }

    enum Status: String { case found, verify, missing }

    /// Found (one clear winner), verify (ambiguous, only a variant, or only artist/title matches), missing.
    static func decide(_ line: Line, _ candidates: [Track]) -> (status: Status, chosen: Track?, alternatives: [Track]) {
        // stable: equal scores keep Spotify's relevance order
        let scored = candidates.enumerated()
            .map { (score(line, $0.element), $0.offset, $0.element) }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map { ($0.0, $0.2) }
        let strong = scored.filter { $0.0 >= 20 }
        guard let best = strong.first else {
            if let top = scored.first, top.0 >= 10 { return (.verify, nil, Array(scored.prefix(4).map(\.1))) }
            return (.missing, nil, [])
        }
        let alternatives = Array(scored.dropFirst().prefix(4).map(\.1))
        if isVariant(best.1.name) && !isVariant(line.title) {
            return (.verify, best.1, Array(scored.prefix(4).map(\.1)))
        }
        if strong.count > 1, strong[1].0 == best.0,
           normalize(baseTitle(strong[1].1.name)) != normalize(baseTitle(best.1.name)) {
            return (.verify, best.1, Array(strong.prefix(4).map(\.1)))
        }
        return (.found, best.1, alternatives)
    }

    /// A name for a new playlist: the imported file's name when there is one,
    /// otherwise the two most frequent artists ("Metallica, Gojira e altri").
    static func suggestedName(fileName: String?, lines: [Line]) -> String {
        if let fileName {
            let words = (fileName as NSString).deletingPathExtension
                .replacingOccurrences(of: "_", with: " ").split(separator: " ").joined(separator: " ")
            if !words.isEmpty { return words.prefix(1).uppercased() + words.dropFirst() }
        }
        // artists compared normalized ("metallica" = "Metallica"), shown as first written
        var counts: [String: Int] = [:]
        var order: [(key: String, name: String)] = []
        for line in lines {
            let key = normalize(line.artist)
            if counts[key] == nil { order.append((key, line.artist)) }
            counts[key, default: 0] += 1
        }
        // most frequent first, ties in list order
        let top = order.enumerated().sorted { (counts[$0.element.key]!, -$0.offset) > (counts[$1.element.key]!, -$1.offset) }
            .map(\.element.name)
        switch top.count {
        case 0: return "Nuova playlist"
        case 1: return top[0]
        case 2: return "\(top[0]) e \(top[1])"
        default: return "\(top[0]), \(top[1]) e altri"
        }
    }
}

/// A Spotify track as the app needs it.
struct Track: Identifiable, Hashable, Codable {
    var id: String
    var uri: String
    var name: String
    var artists: [String]
    var album: String

    var label: String { "\(name) — \(artists.joined(separator: ", "))" }
}
