import json
import os
import runpy
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import organizer_quality  # noqa: E402


def obj(fields):
    return {"type": "object", "properties": fields, "required": list(fields), "additionalProperties": False}


ORIGINAL = {
    "text": "第一段文字。第二段文字。",
    "spans": [
        {"id": "span-a", "textStart": 0, "textEnd": 6, "startMS": 0, "endMS": 1000},
        {"id": "span-b", "textStart": 6, "textEnd": 12, "startMS": 1000, "endMS": 2000},
    ],
}


class ReviewTranscriptFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        (self.folder / "Qwen完整逐字稿.json").write_text(json.dumps(ORIGINAL, ensure_ascii=False))
        (self.folder / "source.json").write_text("{}")

    def fake_ask(self, results):
        calls = []

        def ask(payload, instructions, cache, schema, **options):
            calls.append(cache)
            result = results[len(calls) - 1]
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"response_id": "resp-" + str(len(calls)), "result": result}, ensure_ascii=False))
            return result
        return ask, calls

    def test_subprocess_failure_record_preserves_service_retries_and_diagnostics(self):
        script = Path(__file__).resolve().parents[1] / "organize_podcast.py"
        failure_file = self.folder / "failure.json"
        opener = mock.Mock()
        opener.open.side_effect = urllib.error.HTTPError("https://example.invalid/v1/responses", 503, "fixture", {}, None)
        env = {
            "VOICEOS_TEXT_BASE_URL": "https://example.invalid/v1",
            "VOICEOS_TEXT_API_KEY": "fixture-key",
            "VOICEOS_TEXT_MODEL": "fixture",
            "VOICEOS_TEXT_EFFORT": "high",
            "VOICEOS_ORGANIZER_FAILURE_FILE": str(failure_file),
        }
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            sys, "argv", [str(script), str(self.folder), "--review-transcript-only"]
        ), mock.patch("urllib.request.build_opener", return_value=opener), mock.patch(
            "time.sleep"
        ) as sleep, redirect_stdout(StringIO()):
            with self.assertRaisesRegex(RuntimeError, "^Text service HTTP 503; no response saved$"):
                runpy.run_path(str(script), run_name="__main__")
        self.assertEqual(sleep.call_args_list, [mock.call(5), mock.call(15)])
        self.assertEqual(opener.open.call_count, 3)
        self.assertEqual(json.loads(failure_file.read_text()), {"kind": "http", "status": 503})

    def test_receipt_path_follows_model_identity(self):
        first, first_calls = self.fake_ask([
            {"corrections": [{"span_id": "span-a", "text": "第一段文字。", "note": ""}], "remaining_issues": []}])
        organizer_quality.review_transcript(self.folder, first, obj, identity_scope="https://a|gpt-6.2-sol|high")
        other = Path(self.temp.name) / "other"
        other.mkdir()
        (other / "Qwen完整逐字稿.json").write_text(json.dumps(ORIGINAL, ensure_ascii=False))
        (other / "source.json").write_text("{}")
        second, second_calls = self.fake_ask([
            {"corrections": [], "remaining_issues": []}])
        organizer_quality.review_transcript(other, second, obj, identity_scope="https://a|gpt-6.1-sol|high")
        self.assertNotEqual(first_calls[0].parent.name, second_calls[0].parent.name)

    def test_repair_round_keeps_first_round_corrections(self):
        ask, calls = self.fake_ask([
            {"corrections": [{"span_id": "span-b", "text": "第二段的文字。", "note": "补字"},
                             {"span_id": "missing", "text": "未知片段。", "note": ""}],
             "remaining_issues": []},
            {"corrections": [], "remaining_issues": []}])
        checked = organizer_quality.review_transcript(self.folder, ask, obj, identity_scope="scope")
        self.assertEqual(len(calls), 2)
        self.assertEqual(checked["text"], "第一段文字。第二段的文字。")
        review = checked["transcription_review"]
        self.assertEqual(review["correction_count"], 1)
        self.assertEqual(review["corrections"][0]["span_id"], "span-b")
        self.assertEqual(review["original_digest"], organizer_quality.hashlib.sha256(
            json.dumps(ORIGINAL, ensure_ascii=False, sort_keys=True).encode()).hexdigest())


if __name__ == "__main__":
    unittest.main()
