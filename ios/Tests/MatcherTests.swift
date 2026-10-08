@testable import PlaylistImporter
import XCTest

/// Same cases as core/matcher.py tests, plus the sizes the brief asks for (10, 50, 165 songs).
final class MatcherTests: XCTestCase {
    private func t(_ artist: String, _ name: String) -> Track {
        Track(id: "\(artist)-\(name)", uri: "spotify:track:\(artist)-\(name)", name: name, artists: [artist], album: "")
    }

    private let sample = """
    Metallica - Master of Puppets
    Death - Symbolic
    Tool - Schism
    Gojira - Flying Whales
    Iron Maiden - Hallowed Be Thy Name
    """

    func testNormalize() {
        XCTAssertEqual(Matcher.normalize("Sigur Rós"), "sigur ros")
        XCTAssertEqual(Matcher.normalize("AC/DC"), "ac dc")
        XCTAssertEqual(Matcher.normalize("Motörhead"), "motorhead")
        XCTAssertEqual(Matcher.normalize("Guns N' Roses"), "guns n roses")
        XCTAssertEqual(Matcher.normalize("Simon & Garfunkel"), "simon and garfunkel")
    }

    func testParseKeepsOrder() {
        let (lines, invalid) = Matcher.parse(sample)
        XCTAssertEqual(lines.map(\.artist), ["Metallica", "Death", "Tool", "Gojira", "Iron Maiden"])
        XCTAssertTrue(invalid.isEmpty)
    }

    func testSplitsOnFirstSeparator() {
        let line = Matcher.parse("Guns N' Roses - November Rain - Live").lines[0]
        XCTAssertEqual(line.artist, "Guns N' Roses")
        XCTAssertEqual(line.title, "November Rain - Live")
    }

    func testInvalidLinesAndBlanks() {
        let (lines, invalid) = Matcher.parse("Tool - Schism\n\nnot a valid line\nDeath - Symbolic")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(invalid, [Matcher.Invalid(lineNumber: 3, text: "not a valid line")])
    }

    func testDuplicatesKeptAndMarked() {
        let lines = Matcher.parse("Tool - Schism\nDeath - Symbolic\nTool - Schism").lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[2].duplicateOf, 0)
    }

    func testSpecialCharacters() {
        let line = Matcher.parse("Sigur Rós - Hoppípolla").lines[0]
        let d = Matcher.decide(line, [t("Sigur Rós", "Hoppípolla")])
        XCTAssertEqual(d.status, .found)
    }

    func testStudioBeatsLive() {
        let line = Matcher.parse("Death - Symbolic").lines[0]
        let d = Matcher.decide(line, [t("Death", "Symbolic (Live)"), t("Death", "Symbolic")])
        XCTAssertEqual(d.status, .found)
        XCTAssertEqual(d.chosen?.name, "Symbolic")
    }

    func testOnlyVariantNeedsVerification() {
        let line = Matcher.parse("Death - Symbolic").lines[0]
        XCTAssertEqual(Matcher.decide(line, [t("Death", "Symbolic - Live")]).status, .verify)
    }

    func testLiveWhenAsked() {
        let line = Matcher.parse("Death - Symbolic Live").lines[0]
        XCTAssertEqual(Matcher.decide(line, [t("Death", "Symbolic Live")]).status, .found)
    }

    func testRemasterSkippedWhenOriginalExists() {
        let line = Matcher.parse("Metallica - Master of Puppets").lines[0]
        let d = Matcher.decide(line, [t("Metallica", "Master of Puppets (Remastered 2017)"), t("Metallica", "Master of Puppets")])
        XCTAssertEqual(d.chosen?.name, "Master of Puppets")
    }

    func testMissingAndArtistOnly() {
        let a = Matcher.parse("Gojira - Flying Whales").lines[0]
        XCTAssertEqual(Matcher.decide(a, [t("Ghost", "Mary on a Cross")]).status, .missing)
        let b = Matcher.parse("Iron Maiden - Hallowed Be Thy Name").lines[0]
        XCTAssertEqual(Matcher.decide(b, [t("Iron Maiden", "The Trooper")]).status, .verify)
    }

    func testArtistWholeWordOnly() {
        let line = Matcher.parse("Death - Symbolic").lines[0]
        XCTAssertNotEqual(Matcher.decide(line, [t("Deathstars", "Symbolic")]).status, .found)
    }

    /// 10, 50 and 165 lines (with duplicates): every line kept, in the original order.
    func testOrderAtScale() {
        for size in [10, 50, 165] {
            let text = (0..<size).map { "Artist \($0 % 40) - Song \($0)" }.joined(separator: "\n") + "\nArtist 1 - Song 1"
            let lines = Matcher.parse(text).lines
            XCTAssertEqual(lines.count, size + 1)
            XCTAssertEqual(lines.map(\.index), Array(0..<(size + 1)))
            XCTAssertEqual(lines.last?.duplicateOf, 1)
            for line in lines where line.duplicateOf == nil {
                let d = Matcher.decide(line, [t("Artist \(line.index % 40)", "Song \(line.index)")])
                XCTAssertEqual(d.status, .found, "line \(line.index)")
            }
        }
    }
}
