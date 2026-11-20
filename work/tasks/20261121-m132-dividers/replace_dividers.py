#!/usr/bin/env python3
"""Replace confirmed bare Divider() lines with WorkspaceListDivider().

Run: python3 -I work/tasks/20261121-m132-dividers/replace_dividers.py
Prints per-file replacement counts, then verifies the remaining bare
Divider() set equals KEEP exactly.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / "Sources" / "VoiceOSApp"

REPLACE = {
    "AssistantExecutionView.swift": [123, 159, 209, 234],
    "BilingualView.swift": [44, 116],
    "ClaimReviewHistoryView.swift": [36],
    "CorrectionImpactView.swift": [53, 67],
    "DiscussionHistoryView.swift": [23, 50],
    "DiscussionView.swift": [82, 86],
    "EnglishPracticeView.swift": [101],
    "QuestionAnswerSection.swift": [180],
    "RecentContentHome.swift": [371, 378],
    "ReflectionChangeView.swift": [37, 96, 115],
    "ReflectionGraphView.swift": [117, 128, 371, 482, 505],
    "ReflectionQuestionsView.swift": [85, 198],
    "ReverifyControls.swift": [51, 67],
    "TaskInitiationView.swift": [281, 383, 431, 537],
    "TextCaptureView.swift": [52, 275],
    "ThoughtPanoramaView.swift": [46, 500, 591, 712, 715, 903, 913, 1033],
    "TranscriptSegmentationView.swift": [31],
    "VoiceOSApp.swift": [4982],
    "WeeklyReviewView.swift": [284, 290, 294, 459, 549, 559, 569, 616, 702, 715, 761],
    "WorkspaceActivityViews.swift": [710, 763, 776, 789, 956, 1403, 1414, 1430],
    "WorkspaceDiscussionView.swift": [38, 125],
    "WorkspaceSourceView.swift": [382, 512, 568, 571, 849, 884, 931, 953, 971],
    "WorkspaceTopicReadingView.swift": [332, 416],
    "WorkspaceView.swift": [595, 1185, 1222, 1598, 1620, 1755, 1981, 2456, 2695],
}

KEEP = {
    "AssistantExecutionView.swift": [151],
    "PanoramaConstellation.swift": [1143],
    "RecentContentHome.swift": [885],
    "ReflectionChangeView.swift": [42],
    "ReflectionGraphView.swift": [134],
    "ReflectionQuestionsView.swift": [88],
    "TextCaptureView.swift": [223],
    "ThoughtPanoramaView.swift": [50, 218, 220],
    "VoiceOSApp.swift": [4607, 4614],
    "WorkspaceSourceView.swift": [610, 617, 625],
    "WorkspaceView.swift": [419, 422, 855, 2148],
}

# Whole-line rewrites: (file, line) -> new content without indentation.
# The header rule carries a text-tint overlay from before the component
# existed; the component supplies palette.border, so the overlay goes away.
LINE_REWRITES = {("ReflectionGraphView.swift", 117): "WorkspaceListDivider()"}

def line_ending(s: str) -> str:
    if s.endswith("\r\n"):
        return "\r\n"
    if s.endswith("\n"):
        return "\n"
    return ""

def main() -> int:
    total = 0
    for name, numbers in REPLACE.items():
        path = SRC / name
        rows = path.read_text().splitlines(keepends=True)
        for number in numbers:
            line = rows[number - 1]
            if "Divider()" not in line:
                print(f"FAIL {name}:{number} has no Divider()", file=sys.stderr)
                return 1
            if "WorkspaceListDivider()" in line:
                print(f"FAIL {name}:{number} already converted", file=sys.stderr)
                return 1
            if (name, number) in LINE_REWRITES:
                indent = line[: len(line) - len(line.lstrip())]
                rows[number - 1] = indent + LINE_REWRITES[(name, number)] + line_ending(line)
            else:
                rows[number - 1] = line.replace("Divider()", "WorkspaceListDivider()", 1)
            total += 1
        path.write_text("".join(rows))
        print(f"{name}: {len(numbers)}")

    remaining = set()
    for path in sorted(SRC.glob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if "Divider()" in line and "WorkspaceListDivider()" not in line:
                remaining.add((path.name, number))

    expected = {(name, number) for name, numbers in KEEP.items() for number in numbers}
    extra = sorted(remaining - expected)
    missing = sorted(expected - remaining)
    print(f"replaced={total} keep={len(expected)} remaining_bare={len(remaining)}")
    for name, number in extra:
        print(f"UNEXPECTED {name}:{number}", file=sys.stderr)
    for name, number in missing:
        print(f"MISSING KEEP {name}:{number}", file=sys.stderr)
    return 0 if not extra and not missing else 1

if __name__ == "__main__":
    raise SystemExit(main())