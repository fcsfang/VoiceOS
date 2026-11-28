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
        (Path("Sources/VoiceOSPlatform/KeychainCredential.swift"),),
        re.compile(r"\bSecItem(?:Add|Update|Delete|CopyMatching)\b"),
        "Keychain access belongs in",
    ),
    (
        (Path("Sources/VoiceOSCore/TimestampFormatting.swift"),),
        re.compile(r"\.formatOptions\s*=\s*\[\.withInternetDateTime"),
        "ISO 8601 formatOptions belong in",
    ),
    (
        (Path("Sources/VoiceOSCore/Digest.swift"),),
        re.compile(r'"%02x"'),
        "Hex-encoded SHA-256 belongs in",
    ),
    (
        (Path("Sources/VoiceOSCore/StableJSON.swift"),),
        re.compile(r"outputFormatting\s*=\s*\[\.sortedKeys\]"),
        "Deterministic JSON encoder configuration belongs in",
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
    (
        (),
        re.compile(r"\bcandidateClaims\([^()]*\)\s*\.first\s*(?:\(where:\s*)?\{\s*\$0\.id\s*=="),
        "Use a claim ID lookup from",
    ),
    (
        (),
        re.compile(r"\bsources\(\)\s*\.first\s*(?:\(where:\s*)?\{\s*\$0\.id\s*=="),
        "Use a material ID lookup from",
    ),
    (
        (Path("Sources/VoiceOSCore/TranscriptRevision.swift"),),
        re.compile(
            r"\b(?:INSERT\s+INTO\s+(?:transcripts|transcript_versions)\b|"
            r"UPDATE\s+transcripts\s+SET\s+current_version_id\b)",
            re.IGNORECASE,
        ),
        "Transcript creation and current revision writes belong in",
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
                    allowed = " or ".join(str(owner) for owner in owners) or "VoiceOSStore"
                    violations.append(f"{relative}:{number}: {diagnostic} {allowed}")
    for violation in violations:
        print(violation, file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main())
