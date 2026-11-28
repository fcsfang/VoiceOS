#!/usr/bin/env python3
"""Check source boundaries that SwiftPM cannot express within a target."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
RULES = (
    (
        (Path("Sources/VoiceOSCore/SQLiteConnection.swift"),),
        re.compile(r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?CSQLite\b"),
        "CSQLite belongs in",
    ),
    (
        (Path("Sources/VoiceOSCore/ResponsesEndpoint.swift"),),
        re.compile(r'\bappendingPathComponent\(\s*"responses"|https://[^"\s]+/v1/responses'),
        "Responses URL construction belongs in",
    ),
    (
        (Path("Sources/VoiceOSCore/LibraryLayout.swift"),),
        re.compile(r'\bappendingPathComponent\(\s*"(?:voiceos\.sqlite|Library/Application Support/VoiceOS)"'),
        "Library path construction belongs in",
    ),
    (
        (Path("Sources/VoiceOSPlatform/KeychainCredential.swift"),
         Path("Sources/VoiceOSApp/NoteHistoryMemory.swift")),
        re.compile(r"\bSecItem(?:Add|Update|Delete|CopyMatching)\b"),
        "Keychain access belongs in",
    ),
    (
        (Path("Sources/VoiceOSCore/TimestampFormatting.swift"),),
        re.compile(r"\.formatOptions\s*=\s*\[\.withInternetDateTime"),
        "ISO 8601 formatOptions belong in",
    ),
    (
        (Path("Sources/VoiceOSCore/SourcePolicy.swift"),),
        re.compile(
            r"\b(?:INSERT\s+INTO\s+source_policy_revisions|"
            r"UPDATE\s+sources\s+SET\s+local_only|"
            r"SELECT\s+from_local_only\s+FROM\s+source_policy_revisions)\b",
            re.IGNORECASE,
        ),
        "Source policy writes and historical permission lookup belong in",
    ),
    (
        (Path("Sources/VoiceOSCore/CognitiveStore.swift"),),
        re.compile(r"\bprompt_version\s+NOT\s+IN\s*\(\s*'topic-", re.IGNORECASE),
        "Claim producer eligibility belongs in",
    ),
)


def main() -> int:
    violations = []
    for source in sorted((ROOT / "Sources").rglob("*.swift")):
        relative = source.relative_to(ROOT)
        for number, line in enumerate(source.read_text().splitlines(), start=1):
            if line.lstrip().startswith("//"):
                continue
            for owners, pattern, diagnostic in RULES:
                if relative not in owners and pattern.search(line):
                    allowed = " or ".join(str(owner) for owner in owners)
                    violations.append(f"{relative}:{number}: {diagnostic} {allowed}")
    for violation in violations:
        print(violation, file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main())
