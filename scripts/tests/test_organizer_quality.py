import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import organizer_quality  # noqa: E402


class ApplySpanCorrectionsTests(unittest.TestCase):
    def setUp(self):
        self.original = {
            "text": "第一段文字。第二段文字。",
            "spans": [
                {"id": "span-a", "textStart": 0, "textEnd": 6, "startMS": 0, "endMS": 1000},
                {"id": "span-b", "textStart": 6, "textEnd": 12, "startMS": 1000, "endMS": 2000},
            ],
        }

    def apply(self, corrections, issues=None, user_corrected=False):
        result = {"corrections": corrections, "remaining_issues": issues or []}
        return organizer_quality._apply_span_corrections(self.original, result, user_corrected)

    def assertCorrectionError(self, corrections, issues=None, user_corrected=False):
        with self.assertRaises(organizer_quality._TranscriptCorrectionError) as caught:
            self.apply(corrections, issues, user_corrected)
        return str(caught.exception)

    def test_changes_one_of_two_spans_and_reflows_offsets(self):
        checked, changes, issues = self.apply([{"span_id": "span-a", "text": "第一段的长文字。", "note": "补字"}])
        self.assertEqual(checked["text"], "第一段的长文字。第二段文字。")
        self.assertEqual([(s["textStart"], s["textEnd"]) for s in checked["spans"]], [(0, 8), (8, 14)])
        self.assertEqual("".join(checked["text"][s["textStart"]:s["textEnd"]] for s in checked["spans"]), checked["text"])
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0], {"span_id": "span-a", "before": "第一段文字。",
                                      "after": "第一段的长文字。", "reason": "补字"})
        self.assertEqual(issues, [])
        self.assertEqual(self.original["text"], "第一段文字。第二段文字。")
        self.assertEqual(self.original["spans"][1]["textStart"], 6)

    def test_unknown_span_id_raises(self):
        message = self.assertCorrectionError([{"span_id": "missing", "text": "改。", "note": ""}])
        self.assertIn("第 1 项", message)
        self.assertIn("missing", message)

    def test_duplicate_span_id_raises(self):
        message = self.assertCorrectionError([{"span_id": "span-a", "text": "改一。", "note": ""},
                                              {"span_id": "span-a", "text": "改二。", "note": ""}])
        self.assertIn("第 2 项", message)
        self.assertIn("span-a", message)

    def test_blank_text_raises(self):
        message = self.assertCorrectionError([{"span_id": "span-b", "text": "  ", "note": ""}])
        self.assertIn("span-b", message)
        self.assertIn("text 为空", message)

    def test_unknown_issue_span_id_raises(self):
        message = self.assertCorrectionError([], [{"span_id": "missing", "reason": "听不清"}])
        self.assertIn("第 1 项", message)
        self.assertIn("missing", message)

    def test_user_corrected_keeps_original_and_records_issue(self):
        checked, changes, issues = self.apply([{"span_id": "span-b", "text": "第二段的文字。", "note": "疑似漏字"}],
                                              user_corrected=True)
        self.assertEqual(checked["text"], self.original["text"])
        self.assertEqual([(s["textStart"], s["textEnd"]) for s in checked["spans"]], [(0, 6), (6, 12)])
        self.assertEqual(changes, [])
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0]["span_id"], "span-b")
        self.assertIn("用户更正原文保持不变；模型建议需结合原话核对：疑似漏字", issues[0]["reason"])


class MergeRepairTests(unittest.TestCase):
    SPAN_IDS = {"span-a", "span-b"}

    def merge(self, first, repaired):
        return organizer_quality._merge_repair(first, repaired, self.SPAN_IDS)

    def test_keeps_first_round_correction_repair_dropped(self):
        first = {"corrections": [{"span_id": "span-a", "text": "改好的第一段。", "note": "术语"}],
                 "remaining_issues": [{"span_id": "span-b", "reason": "听不清"}]}
        repaired = {"corrections": [], "remaining_issues": []}
        merged = self.merge(first, repaired)
        self.assertEqual([entry["span_id"] for entry in merged["corrections"]], ["span-a"])
        self.assertEqual(merged["corrections"][0]["text"], "改好的第一段。")
        self.assertEqual(merged["remaining_issues"], [{"span_id": "span-b", "reason": "听不清"}])

    def test_rejects_repair_rewriting_a_valid_first_round_entry(self):
        first = {"corrections": [{"span_id": "span-a", "text": "改好的第一段。", "note": ""}], "remaining_issues": []}
        repaired = {"corrections": [{"span_id": "span-a", "text": "另一段话。", "note": ""}], "remaining_issues": []}
        with self.assertRaises(organizer_quality._TranscriptCorrectionError):
            self.merge(first, repaired)

    def test_repair_fixes_flagged_entry_and_drops_unknown(self):
        first = {"corrections": [{"span_id": "span-a", "text": "  ", "note": "空文字被报错"},
                                 {"span_id": "missing", "text": "未知片段。", "note": ""}],
                 "remaining_issues": [{"span_id": "missing", "reason": "未知疑点"}]}
        repaired = {"corrections": [{"span_id": "span-a", "text": "补好的第一段。", "note": "空文字被报错"}],
                    "remaining_issues": []}
        merged = self.merge(first, repaired)
        self.assertEqual(merged["corrections"], [{"span_id": "span-a", "text": "补好的第一段。", "note": "空文字被报错"}])
        self.assertEqual(merged["remaining_issues"], [])

    def test_repair_cannot_introduce_a_span_the_first_round_never_judged(self):
        first = {"corrections": [{"span_id": "span-a", "text": "改好的第一段。", "note": ""}], "remaining_issues": []}
        repaired = {"corrections": [{"span_id": "span-a", "text": "改好的第一段。", "note": ""},
                                    {"span_id": "span-b", "text": "修复轮新写的第二段。", "note": ""}],
                    "remaining_issues": []}
        merged = self.merge(first, repaired)
        self.assertEqual([entry["span_id"] for entry in merged["corrections"]], ["span-a"])

    def test_repair_duplicate_span_id_keeps_first_entry(self):
        first = {"corrections": [{"span_id": "span-a", "text": "改好的第一段。", "note": ""}], "remaining_issues": []}
        repaired = {"corrections": [{"span_id": "span-a", "text": "改好的第一段。", "note": ""},
                                    {"span_id": "span-a", "text": "重复的第二条。", "note": ""}],
                    "remaining_issues": []}
        merged = self.merge(first, repaired)
        self.assertEqual(len(merged["corrections"]), 1)


if __name__ == "__main__":
    unittest.main()