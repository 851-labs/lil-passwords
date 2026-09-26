#!/usr/bin/env python3
"""Fails if a user-facing string literal is passed to a text-display API without going through
`String(localized:)` (or, for SwiftUI's own auto-localizing APIs, without a `+`-concatenation bug
that silently opts it back out) — see docs/accessibility.md and 851-2466.

Why this exists
---------------
`Text("literal")` / `Button("literal") { }` / `Toggle("literal", isOn: ...)` / `Label("literal",
systemImage:)` auto-localize a *bare string literal* argument: SwiftUI resolves these to the
`LocalizedStringKey`-taking overload when given a literal directly, and Xcode's string-extraction
(`SWIFT_EMIT_LOC_STRINGS`) picks the call site up automatically. So this script does NOT flag a bare
literal passed to one of those four APIs — that's already correct.

What *does* silently break, and is exactly what this script catches:

1. AppKit APIs that never auto-localize, regardless of literal-vs-variable — `NSTextField(labelWithString:
   "...")`, `NSButton(title: "...")`, `.title = "..."`, etc. Every one of these needs its string
   wrapped in `String(localized: "...")` (see docs/accessibility.md's existing call sites for the
   pattern) or it's just never in `Localizable.xcstrings` at all.

2. The one confirmed regression pattern found live in this codebase during 851-2466's audit:
   `Text("part one " + "part two")` (or the same for Button/Toggle/Label). `+` has no
   `LocalizedStringKey` overload, so *both* literals default-infer to plain `String` — the call
   silently resolves to the non-localizing `Text(String)` initializer, with on-screen text that looks
   identical to a correctly-localized string. Found in 7 places (all in App/Sources/Settings/) before
   851-2466 fixed them; this check exists so it can't come back. The fix is to wrap each fragment in
   its own `String(localized:)` call and join those (already-`String`-typed) results with `+` — see
   any of the fixed call sites for the pattern this script expects.

Usage
-----
    scripts/check-localization.py                 # scan the whole repo, print violations
    scripts/check-localization.sh                  # same, thin wrapper (what `make lint`/CI call)

Suppressing a false positive
-----------------------------
- Put `// l10n-ignore` anywhere on the violating line, or the line directly above it (for a
  multi-line call where the flagged token isn't on the same line as a good comment anchor).
- Or add an entry to scripts/localization-allowlist.txt: either `path/to/File.swift` (whole file) or
  `path/to/File.swift:123` (one line). One entry per line; `#`-prefixed lines and blank lines are
  ignored.

Scope / limitations (read before assuming a clean run means "fully localized")
-------------------------------------------------------------------------------
- This is a regex-and-bracket-matching scan, not a real Swift parser. It cannot verify that a bare
  identifier/property passed to Text(_:)/NSButton(title:)/etc. (e.g. `Text(someComputedString)`) is
  itself built from `String(localized:)` somewhere upstream — that's a real gap, mitigated only by
  code review. `AppSettings.AutoLockInterval.displayName` (Packages/LilPasswordsKit) is exactly this
  shape and is a known, pre-existing, unlocalized computed property (out of scope for 851-2466) that
  this script cannot and does not catch, because nothing passes a *literal* to a flagged API there.
- A literal that has no actual words once `\(...)` interpolation is stripped out — `""`, `"\(count)"`,
  `"  \(title)"` — is treated the same as an empty string and not flagged: there's nothing
  translatable in it, only a number or whitespace framing an already-localized interpolated value
  (e.g. `button.title = "  \(title)"` where every call site passes `title: String(localized: ...)`).
- Only scans `*.swift` files, skips anything under Packages/*/Tests, .build, DerivedData, and build/.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ALLOWLIST_PATH = os.path.join(REPO_ROOT, "scripts", "localization-allowlist.txt")

EXCLUDED_DIR_NAMES = {".git", ".build", "DerivedData", "build", ".swiftpm", "Pods"}


def should_skip_dir(name: str) -> bool:
    return name in EXCLUDED_DIR_NAMES


def should_skip_path(path: str) -> bool:
    parts = path.split(os.sep)
    return "Tests" in parts


def find_swift_files(root: str) -> list[str]:
    results = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not should_skip_dir(d)]
        for filename in filenames:
            if filename.endswith(".swift"):
                full = os.path.join(dirpath, filename)
                rel = os.path.relpath(full, root)
                if not should_skip_path(rel):
                    results.append(rel)
    return sorted(results)


# ---------------------------------------------------------------------------
# A tiny Swift lexer: just enough to (a) blank out comments so doc-comment
# example code never matches, and (b) find string-literal spans (including
# interpolation) so argument extraction can tell "a literal at the top level
# of this argument" from "a literal safely nested inside String(localized:)".
# ---------------------------------------------------------------------------


def consume_string(text: str, i: int) -> int:
    """`text[i]` is the opening `"` of a string literal (plain or triple-quoted). Returns the index
    just past the closing quote(s), correctly skipping over `\\(...)` interpolation (which can itself
    contain nested strings/parens)."""
    n = len(text)
    if text[i : i + 3] == '"""':
        j = i + 3
        while j < n:
            if text[j] == "\\" and j + 1 < n:
                j += 2
                continue
            if text[j : j + 3] == '"""':
                return j + 3
            j += 1
        return n

    j = i + 1
    while j < n:
        c = text[j]
        if c == "\\" and j + 1 < n and text[j + 1] == "(":
            depth = 1
            j += 2
            while j < n and depth > 0:
                if text[j] == '"':
                    j = consume_string(text, j)
                    continue
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            continue
        if c == "\\":
            j += 2
            continue
        if c == '"':
            return j + 1
        if c == "\n":
            return j  # unterminated on this line; bail rather than eat the rest of the file
        j += 1
    return n


def strip_comments(text: str) -> str:
    """Replaces `//...` and `/* ... */` spans with spaces (preserving newlines/columns) so later
    regex matching never fires on example code quoted inside a doc comment. Leaves string literals
    untouched (a `//`/`/*` inside a string literal isn't a comment)."""
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if c == '"':
            i = consume_string(text, i)
            continue
        if text[i : i + 2] == "//":
            j = i
            while j < n and text[j] != "\n":
                out[j] = " "
                j += 1
            i = j
            continue
        if text[i : i + 2] == "/*":
            j = i
            depth = 0
            while j < n:
                if text[j : j + 2] == "/*":
                    depth += 1
                    out[j] = out[j + 1] = " "
                    j += 2
                    continue
                if text[j : j + 2] == "*/":
                    depth -= 1
                    out[j] = out[j + 1] = " "
                    j += 2
                    if depth == 0:
                        break
                    continue
                if text[j] != "\n":
                    out[j] = " "
                j += 1
            i = j
            continue
        i += 1
    return "".join(out)


def strip_interpolation(inner: str) -> str:
    """`inner` is a string literal's contents with the surrounding quotes already removed. Removes
    every top-level `\\(...)` interpolation span (recursively handling nested strings/parens inside
    it, same as `consume_string`), leaving only the literal text that actually surrounds them. Also
    collapses `\\`-escape pairs to a single placeholder character so e.g. `\\n` doesn't get treated
    as two meaningful characters."""
    out = []
    i = 0
    n = len(inner)
    while i < n:
        c = inner[i]
        if c == "\\" and i + 1 < n and inner[i + 1] == "(":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if inner[i] == '"':
                    i = consume_string(inner, i)
                    continue
                if inner[i] == "(":
                    depth += 1
                elif inner[i] == ")":
                    depth -= 1
                i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append("x")  # escape sequence (\n, \t, \", \\, ...) — one opaque char, not text
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def literal_has_translatable_text(literal: str) -> bool:
    """`literal` is a full string-literal token as returned by `consume_string` (including its
    quotes — plain `"..."` or triple `\"\"\"...\"\"\"`). Returns False for a literal that has no
    actual words left once `\\(...)` interpolation is stripped out and escape sequences are ignored
    — e.g. `""`, `"\\(count)"` (a bare number), or `"  \\(title)"` (whitespace padding around an
    already-localized interpolated value, the shape `button.title = "  \\(title)"` uses). None of
    those need — or would meaningfully populate — a String Catalog entry, so they're exempt from
    the "unwrapped literal" checks the same way a plain `""` already was."""
    if literal.startswith('"""') and literal.endswith('"""') and len(literal) >= 6:
        inner = literal[3:-3]
    elif literal.startswith('"') and literal.endswith('"') and len(literal) >= 2:
        inner = literal[1:-1]
    else:
        inner = literal.strip("'\"")
    return strip_interpolation(inner).strip() != ""


@dataclass
class ArgumentInfo:
    text: str
    end_index: int
    has_top_level_literal: bool
    has_nonempty_top_level_literal: bool
    has_top_level_plus: bool


def scan_argument_text(arg_text: str) -> tuple[bool, bool, bool]:
    """Returns (has_top_level_literal, has_nonempty_top_level_literal, has_top_level_plus) for an
    already-extracted argument/statement substring, tracking paren/bracket depth *within that
    substring* (starting fresh at depth 0)."""
    depth = 0
    has_literal = False
    has_nonempty_literal = False
    has_plus = False
    i = 0
    n = len(arg_text)
    while i < n:
        c = arg_text[i]
        if c == '"':
            j = consume_string(arg_text, i)
            literal = arg_text[i:j]
            if depth == 0:
                has_literal = True
                if literal_has_translatable_text(literal):
                    has_nonempty_literal = True
            i = j
            continue
        if c in "([{":
            depth += 1
            i += 1
            continue
        if c in ")]}":
            depth -= 1
            i += 1
            continue
        if c == "+" and depth == 0:
            has_plus = True
        i += 1
    return has_literal, has_nonempty_literal, has_plus


def extract_argument(text: str, start: int) -> ArgumentInfo:
    """`start` is the index of the first character of an argument expression (right after a `(` or a
    `label:`). Extracts up to the matching top-level `,` or the enclosing call's closing `)`."""
    depth = 0
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i = consume_string(text, i)
            continue
        if c in "([{":
            depth += 1
            i += 1
            continue
        if c in ")]}":
            if depth == 0:
                break
            depth -= 1
            i += 1
            continue
        if c == "," and depth == 0:
            break
        i += 1
    arg_text = text[start:i]
    has_literal, has_nonempty, has_plus = scan_argument_text(arg_text)
    return ArgumentInfo(arg_text, i, has_literal, has_nonempty, has_plus)


def extract_statement(text: str, start: int) -> ArgumentInfo:
    """`start` is right after a `= ` in a property assignment (e.g. `.title = `). Extracts up to the
    end of the statement — a newline at bracket-depth 0 whose preceding non-space text doesn't end
    with a binary operator (`+`), so a `Text(...)`-style multi-line `"a" + \\n "b"` continuation is
    still captured as one statement."""
    depth = 0
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i = consume_string(text, i)
            continue
        if c in "([{":
            depth += 1
            i += 1
            continue
        if c in ")]}":
            depth -= 1
            i += 1
            continue
        if c == "\n" and depth <= 0:
            prior = text[start:i].rstrip()
            if prior.endswith("+"):
                i += 1
                continue
            break
        i += 1
    arg_text = text[start:i]
    has_literal, has_nonempty, has_plus = scan_argument_text(arg_text)
    return ArgumentInfo(arg_text, i, has_literal, has_nonempty, has_plus)


def line_number(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


# ---------------------------------------------------------------------------
# The checks themselves.
# ---------------------------------------------------------------------------

# AppKit-style APIs: never auto-localize, so *any* top-level, non-empty string literal in the
# extracted argument/statement is a violation, `+`-concatenated or not.
APPKIT_CALL_PATTERNS = [
    # (regex matching up through the point argument-extraction should start, human-readable name)
    (r"NSTextField\(\s*labelWithString:\s*", "NSTextField(labelWithString:)"),
    (r"NSTextField\(\s*wrappingLabelWithString:\s*", "NSTextField(wrappingLabelWithString:)"),
    (r"NSButton\(\s*title:\s*", "NSButton(title:)"),
    (r"NSMenuItem\(\s*title:\s*", "NSMenuItem(title:)"),
    (r"\baccessibilityDescription:\s*", "accessibilityDescription:"),
    (r"\bsetAccessibilityLabel\(\s*", "setAccessibilityLabel(:)"),
    (r"\bsetAccessibilityValue\(\s*", "setAccessibilityValue(:)"),
]
# The `(?!=)` after each `=` keeps these from matching the first `=` of an `==` equality
# comparison (e.g. `$0.title == "GitHub"` in a `.first { }` predicate, found live in
# MenuBarExtraDebugMenu.swift) and misreading the rest of the comparison as an assignment RHS.
# `!=`/`<=`/`>=` can't match here in the first place — they require a non-whitespace, non-`=`
# character immediately before the `=`, which `\.title\s*=` never allows.
APPKIT_ASSIGNMENT_PATTERNS = [
    (r"\.title\s*=(?!=)\s*", ".title ="),
    (r"\.stringValue\s*=(?!=)\s*", ".stringValue ="),
    (r"\.placeholderString\s*=(?!=)\s*", ".placeholderString ="),
    (r"\.messageText\s*=(?!=)\s*", ".messageText ="),
    (r"\.informativeText\s*=(?!=)\s*", ".informativeText ="),
    (r"\.nameFieldStringValue\s*=(?!=)\s*", ".nameFieldStringValue ="),
]

# SwiftUI APIs: a bare literal argument auto-localizes correctly and is NOT a violation. Only a
# top-level `+` combined with a top-level literal (the confirmed regression pattern) is.
SWIFTUI_CALL_PATTERNS = [
    (r"\bText\(\s*", "Text(_:)"),
    (r"\bButton\(\s*", "Button(_:)"),
    (r"\bToggle\(\s*", "Toggle(_:isOn:)"),
    (r"\bLabel\(\s*", "Label(_:systemImage:)"),
]


@dataclass
class Violation:
    path: str
    line: int
    api: str
    detail: str


def check_file(rel_path: str, original_text: str) -> list[Violation]:
    cleaned = strip_comments(original_text)
    violations: list[Violation] = []
    seen_starts: set[int] = set()

    def record(start_index: int, api: str, detail: str) -> None:
        if start_index in seen_starts:
            return
        seen_starts.add(start_index)
        violations.append(Violation(rel_path, line_number(original_text, start_index), api, detail))

    for pattern, api in APPKIT_CALL_PATTERNS:
        for m in re.finditer(pattern, cleaned):
            info = extract_argument(cleaned, m.end())
            if info.has_nonempty_top_level_literal:
                record(
                    m.start(),
                    api,
                    "passes a string literal directly — wrap it in String(localized: \"...\")",
                )

    for pattern, api in APPKIT_ASSIGNMENT_PATTERNS:
        for m in re.finditer(pattern, cleaned):
            info = extract_statement(cleaned, m.end())
            if info.has_nonempty_top_level_literal:
                record(
                    m.start(),
                    api,
                    "assigns a string literal directly — wrap it in String(localized: \"...\")",
                )

    for pattern, api in SWIFTUI_CALL_PATTERNS:
        for m in re.finditer(pattern, cleaned):
            info = extract_argument(cleaned, m.end())
            if info.has_top_level_plus and info.has_top_level_literal:
                record(
                    m.start(),
                    api,
                    "concatenates string literals with '+' before this auto-localizing API — "
                    "'+' has no LocalizedStringKey overload, so the whole expression silently "
                    "resolves to the non-localizing String initializer. Wrap each fragment in its "
                    "own String(localized: \"...\") and join those with '+' instead (851-2466).",
                )

    return violations


# ---------------------------------------------------------------------------
# Allowlist / l10n-ignore suppression.
# ---------------------------------------------------------------------------


@dataclass
class Allowlist:
    whole_files: set[str] = field(default_factory=set)
    lines: set[tuple[str, int]] = field(default_factory=set)

    def allows(self, path: str, line: int) -> bool:
        return path in self.whole_files or (path, line) in self.lines


def load_allowlist(path: str) -> Allowlist:
    allowlist = Allowlist()
    if not os.path.isfile(path):
        return allowlist
    with open(path, encoding="utf-8") as f:
        for raw_line in f:
            entry = raw_line.strip()
            if not entry or entry.startswith("#"):
                continue
            if ":" in entry:
                file_part, _, line_part = entry.rpartition(":")
                try:
                    allowlist.lines.add((file_part, int(line_part)))
                    continue
                except ValueError:
                    pass
            allowlist.whole_files.add(entry)
    return allowlist


def l10n_ignore_lines(text: str) -> set[int]:
    ignored = set()
    for i, raw_line in enumerate(text.split("\n"), start=1):
        if "l10n-ignore" in raw_line:
            ignored.add(i)
    return ignored


def main() -> int:
    allowlist = load_allowlist(ALLOWLIST_PATH)
    files = find_swift_files(REPO_ROOT)

    all_violations: list[Violation] = []
    suppressed_count = 0

    for rel_path in files:
        full_path = os.path.join(REPO_ROOT, rel_path)
        with open(full_path, encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()

        violations = check_file(rel_path, text)
        if not violations:
            continue

        ignore_lines = l10n_ignore_lines(text)
        for v in violations:
            if allowlist.allows(v.path, v.line):
                suppressed_count += 1
                continue
            if v.line in ignore_lines or (v.line - 1) in ignore_lines:
                suppressed_count += 1
                continue
            all_violations.append(v)

    if not all_violations:
        print(f"check-localization: scanned {len(files)} Swift files, no violations found.")
        if suppressed_count:
            print(f"  ({suppressed_count} suppressed via l10n-ignore/allowlist)")
        return 0

    print(f"check-localization: {len(all_violations)} violation(s) found:\n")
    for v in sorted(all_violations, key=lambda v: (v.path, v.line)):
        print(f"{v.path}:{v.line}: [{v.api}] {v.detail}")
    print(
        "\nSuppress a false positive with a trailing `// l10n-ignore` comment (same line or the "
        "line above), or by adding an entry to scripts/localization-allowlist.txt. See "
        "scripts/check-localization.py's module docstring for details."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
