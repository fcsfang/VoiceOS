#!/usr/bin/env python3
"""Check source boundaries that SwiftPM cannot express within a target."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
SQLITE_OWNER = Path("Sources/VoiceOSCore/SQLiteConnection.swift")
SQLITE_IMPORT = re.compile(
    r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?CSQLite\b"
)


def main() -> int:
    violations = []
    for source in sorted((ROOT / "Sources").rglob("*.swift")):
        relative = source.relative_to(ROOT)
        if relative == SQLITE_OWNER:
            continue
        for number, line in enumerate(source.read_text().splitlines(), start=1):
            if not line.lstrip().startswith("//") and SQLITE_IMPORT.search(line):
                violations.append(f"{relative}:{number}: CSQLite belongs in {SQLITE_OWNER}")
    for violation in violations:
        print(violation, file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main())
