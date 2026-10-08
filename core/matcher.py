"""Parsing and matching for the playlist importer.

Pure logic, no network: the caller passes the search results and gets back one decision per input line,
in the same order as the input. The same rules are ported to Swift for the iOS app.
"""
import re
import unicodedata
from dataclasses import dataclass, field
from typing import List, Optional

# Words that mark a version that is not the studio original. They count against a candidate unless the
# user's line asks for them (for example "Live" in the title).
VARIANT_WORDS = ["live", "remix", "acoustic", "instrumental", "remaster", "remastered", "edit", "version",
                 "karaoke", "demo", "mix", "radio"]


@dataclass
class Line:
    index: int           # position in the original list, 0-based
    artist: str
    title: str
    raw: str
    duplicate_of: Optional[int] = None


@dataclass
class Candidate:
    artist: str
    title: str
    uri: str
    variant: bool       # live, remix, remaster, ... (see VARIANT_WORDS)


@dataclass
class Decision:
    line: Line
    status: str         # "found" | "verify" | "missing" | "invalid"
    chosen: Optional[Candidate] = None
    alternatives: List[Candidate] = field(default_factory=list)


def normalize(text: str) -> str:
    """Lowercase, no accents, no punctuation, single spaces. 'Sigur Rós' == 'sigur ros'."""
    text = text.replace("&", " and ")
    decomposed = unicodedata.normalize("NFKD", text)
    no_accents = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    lowered = no_accents.lower()
    cleaned = re.sub(r"[^a-z0-9]+", " ", lowered)
    return " ".join(cleaned.split())


def base_title(title: str) -> str:
    """'Hoppípolla (Live)' and 'Symbolic - Live' -> the song name, for comparison only.
    Removes a bracketed part and anything after a ' - ' separator (Spotify writes versions that way)."""
    without_brackets = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", title)
    return without_brackets.split(" - ", 1)[0].strip()


def parse(text: str) -> tuple:
    """Returns (lines, invalid). Each non-empty line must be 'Artista - Titolo', split on the first ' - '.
    Lines that do not match are returned in 'invalid' with their original line number (1-based)."""
    lines: List[Line] = []
    invalid: List[tuple] = []
    seen = {}
    for number, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()
        if not stripped:
            continue
        if " - " not in stripped:
            invalid.append((number, stripped))
            continue
        artist, title = stripped.split(" - ", 1)
        artist, title = artist.strip(), title.strip()
        if not artist or not title:
            invalid.append((number, stripped))
            continue
        key = (normalize(artist), normalize(title))
        index = len(lines)
        line = Line(index=index, artist=artist, title=title, raw=stripped)
        if key in seen:
            line.duplicate_of = seen[key]
        else:
            seen[key] = index
        lines.append(line)
    return lines, invalid


def _variant(title: str) -> bool:
    words = set(normalize(title).split())
    return any(w in words for w in VARIANT_WORDS)


def _artist_matches(wanted: str, found: str) -> bool:
    """Same artist: equal after normalization, or the wanted name is a whole-word part of the found credit
    (so 'Death' matches 'Death feat. X' but not 'Deathstars')."""
    w, f = normalize(wanted), normalize(found)
    if not w:
        return False
    return f == w or f" {w} " in f"  {f} "


def _title_matches(wanted: str, found: str) -> bool:
    w, f = normalize(base_title(wanted)), normalize(base_title(found))
    return w == f


def _score(line: Line, c: Candidate) -> int:
    score = 0
    if _artist_matches(line.artist, c.artist):
        score += 10
    if _title_matches(line.title, c.title):
        score += 10
    if c.variant and not _variant(line.title):
        score -= 5    # the studio version wins unless the user asked for the variant
    return score


def decide(line: Line, candidates: List[Candidate]) -> Decision:
    """One decision: found (clear winner), verify (ambiguous or only a variant), missing (no artist+title match)."""
    if line.duplicate_of is not None:
        # Same song twice in the input: it is still added twice, in order; no new search needed.
        return Decision(line=line, status="found", chosen=None)
    scored = sorted(((_score(line, c), c) for c in candidates), key=lambda pair: -pair[0])
    strong = [(s, c) for s, c in scored if s >= 20]        # artist AND title match
    if not strong:
        if scored and scored[0][0] >= 10:                    # one side matches only
            return Decision(line=line, status="verify", alternatives=[c for _, c in scored[:4]])
        return Decision(line=line, status="missing")
    best_score, best = strong[0]
    alternatives = [c for _, c in scored[1:5]]
    if best.variant and not _variant(line.title):
        return Decision(line=line, status="verify", chosen=best, alternatives=[c for _, c in scored[:4]])
    if len(strong) > 1 and strong[1][0] == best_score and strong[1][1].title != best.title:
        return Decision(line=line, status="verify", chosen=best, alternatives=[c for _, c in strong[:4]])
    return Decision(line=line, status="found", chosen=best, alternatives=alternatives)


def summary(decisions: List[Decision]) -> dict:
    counts = {"found": 0, "verify": 0, "missing": 0}
    for d in decisions:
        counts[d.status] = counts.get(d.status, 0) + 1
    return counts
