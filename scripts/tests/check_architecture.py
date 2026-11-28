#!/usr/bin/env python3
"""Check source boundaries that SwiftPM cannot express within a target."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
RULES = (
    (
        Path("Sources/VoiceOSCore/SQLiteConnection.swift"),
        re.compile(r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?CSQLite\b"),
        "CSQLite belongs in",
    ),
    (
        Path("Sources/VoiceOSCore/ResponsesEndpoint.swift"),
        re.compile(r'\bappendingPathComponent\(\s*"responses"|https://[^"\s]+/v1/responses'),
        "Responses URL construction belongs in",
    ),
)


def main() -> int:
    violations = []
    for source in sorted((ROOT / "Sources").rglob("*.swift")):
        relative = source.relative_to(ROOT)
        for number, line in enumerate(source.read_text().splitlines(), start=1):
            if line.lstrip().startswith("//"):
                continue
            for owner, pattern, diagnostic in RULES:
                if relative != owner and pattern.search(line):
                    violations.append(f"{relative}:{number}: {diagnostic} {owner}")
    for violation in violations:
        print(violation, file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main())
