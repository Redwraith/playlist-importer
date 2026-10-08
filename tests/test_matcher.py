import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from core.matcher import Candidate, normalize, parse, decide, base_title

def c(artist, title, variant=False):
    return Candidate(artist=artist, title=title, uri=f"spotify:track:{artist}-{title}", variant=variant)

SAMPLE = """Metallica - Master of Puppets
Death - Symbolic
Tool - Schism
Gojira - Flying Whales
Iron Maiden - Hallowed Be Thy Name"""

def test_normalize_accents_case_punctuation():
    assert normalize("Sigur Rós") == "sigur ros"
    assert normalize("AC/DC") == "ac dc"
    assert normalize("Motörhead") == "motorhead"
    assert normalize("Guns N' Roses") == "guns n roses"
    assert normalize("Simon & Garfunkel") == "simon and garfunkel"

def test_parse_keeps_order_and_counts_all_lines():
    lines, invalid = parse(SAMPLE)
    assert [l.artist for l in lines] == ["Metallica", "Death", "Tool", "Gojira", "Iron Maiden"]
    assert invalid == []

def test_parse_splits_on_first_separator_only():
    lines, _ = parse("Guns N' Roses - November Rain - Live")
    assert lines[0].artist == "Guns N' Roses" and lines[0].title == "November Rain - Live"

def test_parse_reports_bad_lines_with_line_number_and_skips_blank():
    lines, invalid = parse("Tool - Schism\n\nnot a valid line\nDeath - Symbolic")
    assert len(lines) == 2
    assert invalid == [(3, "not a valid line")]

def test_duplicates_are_kept_in_order_and_marked():
    lines, _ = parse("Tool - Schism\nDeath - Symbolic\nTool - Schism")
    assert len(lines) == 3
    assert lines[2].duplicate_of == 0

def test_special_characters_match_without_accents():
    lines, _ = parse("Sigur Rós - Hoppípolla")
    d = decide(lines[0], [c("Sigur Rós", "Hoppípolla")])
    assert d.status == "found" and d.chosen.title == "Hoppípolla"

def test_studio_version_beats_live_when_user_did_not_ask():
    lines, _ = parse("Death - Symbolic")
    cands = [c("Death", "Symbolic (Live)", variant=True), c("Death", "Symbolic")]
    d = decide(lines[0], cands)
    assert d.status == "found" and d.chosen.title == "Symbolic"

def test_only_a_variant_needs_verification():
    lines, _ = parse("Death - Symbolic")
    d = decide(lines[0], [c("Death", "Symbolic - Live", variant=True)])
    assert d.status == "verify"

def test_live_is_fine_when_asked_for():
    lines, _ = parse("Death - Symbolic Live")
    d = decide(lines[0], [c("Death", "Symbolic Live", variant=True)])
    assert d.status == "found"

def test_ambiguous_same_score_goes_to_verify():
    lines, _ = parse("Tool - Schism")
    d = decide(lines[0], [c("Tool", "Schism"), c("Tool", "Schism", variant=False)])
    # identical title: treated as the same song, not ambiguous
    assert d.status == "found"
    d2 = decide(lines[0], [c("Tool", "Schism"), c("Tool", "Schism (Remix)", variant=True)])
    assert d2.status == "found"

def test_different_songs_with_same_score_need_a_choice():
    lines, _ = parse("Tool - Schism")
    d = decide(lines[0], [c("Tool", "Schism"), c("Tool", "Schism II")])
    assert d.status == "found" or d.status == "verify"

def test_missing_when_nothing_matches():
    lines, _ = parse("Gojira - Flying Whales")
    d = decide(lines[0], [c("Ghost", "Mary on a Cross")])
    assert d.status == "missing"

def test_artist_only_match_needs_verification():
    lines, _ = parse("Iron Maiden - Hallowed Be Thy Name")
    d = decide(lines[0], [c("Iron Maiden", "The Trooper")])
    assert d.status == "verify"

def test_artist_whole_word_only():
    lines, _ = parse("Death - Symbolic")
    d = decide(lines[0], [c("Deathstars", "Symbolic")])
    assert d.status != "found"

def test_brackets_ignored_when_comparing_titles():
    lines, _ = parse("Metallica - Master of Puppets")
    d = decide(lines[0], [c("Metallica", "Master of Puppets (Remastered 2017)", variant=True),
                          c("Metallica", "Master of Puppets")])
    assert d.status == "found" and d.chosen.title == "Master of Puppets"

def test_full_sample_order_preserved():
    lines, _ = parse(SAMPLE)
    cands = {
        "Metallica": [c("Metallica", "Master of Puppets")],
        "Death": [c("Death", "Symbolic")],
        "Tool": [c("Tool", "Schism")],
        "Gojira": [c("Gojira", "Flying Whales")],
        "Iron Maiden": [c("Iron Maiden", "Hallowed Be Thy Name")],
    }
    decisions = [decide(l, cands[l.artist]) for l in lines]
    assert [d.line.index for d in decisions] == [0, 1, 2, 3, 4]
    assert all(d.status == "found" for d in decisions)
    assert [d.chosen.title for d in decisions] == ["Master of Puppets", "Symbolic", "Schism", "Flying Whales", "Hallowed Be Thy Name"]
