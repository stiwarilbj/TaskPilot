import importlib.util
import io
from pathlib import Path
import unittest
import urllib.error


source = Path(__file__).resolve().parents[2] / "Resources/OpenClaw/gemini-probe.py"
spec = importlib.util.spec_from_file_location("gemini_probe", source)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class GeminiProbeTests(unittest.TestCase):
    def test_promotes_first_model_with_a_real_text_reply(self):
        seen = []

        def opener(request, timeout):
            seen.append(request.full_url)
            self.assertEqual(request.get_header("X-goog-api-key"), "private-key")
            if len(seen) == 1:
                raise urllib.error.HTTPError(request.full_url, 503, "busy", {}, io.BytesIO(b"{}"))
            return io.BytesIO(b'{"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}')

        model, error = probe.choose_model(
            "private-key", ("google/gemini-3.5-flash", "google/gemini-3.1-flash-lite"), opener
        )
        self.assertEqual(model, "google/gemini-3.1-flash-lite")
        self.assertEqual(error, "")
        self.assertEqual(len(seen), 2)

    def test_rejected_key_stops_without_trying_other_models(self):
        seen = []

        def opener(request, timeout):
            seen.append(request.full_url)
            raise urllib.error.HTTPError(
                request.full_url, 400, "bad key", {},
                io.BytesIO(b'{"error":{"message":"API key not valid"}}'),
            )

        model, error = probe.choose_model("private-key", probe.MODELS, opener)
        self.assertIsNone(model)
        self.assertIn("rejected", error)
        self.assertNotIn("private-key", error)
        self.assertEqual(len(seen), 1)

    def test_model_specific_forbidden_error_tries_the_next_model(self):
        seen = []

        def opener(request, timeout):
            seen.append(request.full_url)
            if len(seen) == 1:
                raise urllib.error.HTTPError(
                    request.full_url, 403, "model restricted", {},
                    io.BytesIO(b'{"error":{"message":"Permission denied for this model"}}'),
                )
            return io.BytesIO(b'{"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}')

        model, error = probe.choose_model(
            "private-key", ("google/gemini-2.5-flash-lite", "google/gemini-3.8-flash"), opener
        )
        self.assertEqual(model, "google/gemini-3.8-flash")
        self.assertEqual(error, "")
        self.assertEqual(len(seen), 2)


if __name__ == "__main__":
    unittest.main()
