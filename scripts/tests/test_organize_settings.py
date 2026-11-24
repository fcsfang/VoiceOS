import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import organize_podcast  # noqa: E402


class SettingsMergeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.file = Path(self.folder.name) / ".env"

    def settings_with(self, text, env):
        self.file.write_text(text)
        base = {"VOICEOS_MODEL_CONFIG_FILE": str(self.file),
                "VOICEOS_TEXT_BASE_URL": "", "VOICEOS_TEXT_API_KEY": "",
                "VOICEOS_TEXT_MODEL": "", "VOICEOS_TEXT_EFFORT": ""}
        base.update(env)
        with mock.patch.dict(os.environ, base):
            return organize_podcast.settings()

    def test_file_fills_model_and_effort_missing_from_env(self):
        address, key, model, effort = self.settings_with(
            'OPENAI_BASE_URL="https://api.example.com/v1"\nOPENAI_API_KEY="file-key"\n'
            'OPENAI_MODEL="gpt-6.1-sol"\nOPENAI_REVIEW_EFFORT="xhigh"\n',
            {"VOICEOS_TEXT_BASE_URL": "https://env.example.com/v1", "VOICEOS_TEXT_API_KEY": "env-key"})
        self.assertEqual(address, "https://env.example.com/v1")
        self.assertEqual(key, "env-key")
        self.assertEqual(model, "gpt-6.1-sol")
        self.assertEqual(effort, "xhigh")

    def test_injected_key_is_not_replaced_by_stale_file_key(self):
        address, key, _, _ = self.settings_with(
            'OPENAI_BASE_URL="https://api.example.com/v1"\nOPENAI_API_KEY="old-key"\n',
            {"VOICEOS_TEXT_API_KEY": "fresh-key"})
        self.assertEqual(address, "https://api.example.com/v1")
        self.assertEqual(key, "fresh-key")

    def test_env_accepts_the_importer_alias_names(self):
        _, _, model, effort = self.settings_with(
            'OPENAI_BASE_URL="https://api.example.com/v1"\nOPENAI_API_KEY="file-key"\n'
            'VOICEOS_TEXT_MODEL="gpt-6.2-sol"\nVOICEOS_REVIEW_EFFORT="low"\n', {})
        self.assertEqual(model, "gpt-6.2-sol")
        self.assertEqual(effort, "low")

    def test_missing_config_file_falls_back_to_env_only(self):
        os.environ.pop("VOICEOS_MODEL_CONFIG_FILE", None)
        with mock.patch.dict(os.environ, {"VOICEOS_MODEL_CONFIG_FILE": str(Path(self.folder.name) / "absent.env"),
                                          "VOICEOS_TEXT_BASE_URL": "https://env.example.com/v1",
                                          "VOICEOS_TEXT_API_KEY": "env-key",
                                          "VOICEOS_TEXT_MODEL": "gpt-6.2-sol",
                                          "VOICEOS_TEXT_EFFORT": "high"}):
            address, key, model, effort = organize_podcast.settings()
        self.assertEqual((address, key, model, effort),
                         ("https://env.example.com/v1", "env-key", "gpt-6.2-sol", "high"))


if __name__ == "__main__":
    unittest.main()