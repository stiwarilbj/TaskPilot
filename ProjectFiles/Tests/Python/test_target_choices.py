"""Grounded target choices are bounded, distinguishable and task-scoped."""
from pathlib import Path
import os
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from target_choices import candidate_fingerprint, grounded_candidates, validate_choice_shape
from task_evidence import TaskEvidenceLedger
from task_inputs import EXACT_INPUT_REFERENCE_VERSION
from response_validation import ResponseValidationError, validate_response
import openclaw_runtime as runtime


def explicit_reference(request: str, value: str, kind: str) -> dict:
    encoded = request.encode("utf-8")
    needle = value.encode("utf-8")
    start = encoded.index(needle)
    return {"version": EXACT_INPUT_REFERENCE_VERSION, "kind": kind,
            "utf8_start": start, "utf8_length": len(needle), "value": value}


def ledger_for(request: str, paths=(), kinds=(), *, generation="target-choice-test"):
    refs = [explicit_reference(request, path, kind) for path, kind in zip(paths, kinds)]
    ledger = TaskEvidenceLedger(request, generation,
        input_scope="1234567890abcdef", exact_input_references=refs)
    ledger.add_requirements([{
        "source": request,
        "description": "Use the intended target for this requirement",
        "check": {"type": "answer", "expected": "the selected target was used"},
    }])
    return ledger


class TargetChoiceTests(unittest.TestCase):
    def test_duplicate_folder_and_file_names_are_distinguished_by_full_parent(self):
        with tempfile.TemporaryDirectory() as root:
            downloads = Path(root) / "Downloads" / "Reports"
            archive = Path(root) / "Project Archive" / "Reports"
            downloads.mkdir(parents=True)
            archive.mkdir(parents=True)
            first = downloads / "summary.pdf"
            second = archive / "summary.pdf"
            first.write_bytes(b"one")
            second.write_bytes(b"two")
            request = f"Use {downloads} or {archive} as the Reports folder"
            ledger = ledger_for(request, (str(downloads), str(archive)), ("folder", "folder"))
            candidates = grounded_candidates({}, ledger)
            self.assertEqual([row["label"] for row in candidates], ["Reports", "Reports"])
            self.assertNotEqual(candidates[0]["detail"], candidates[1]["detail"])
            self.assertIn("Downloads", candidates[0]["detail"])
            self.assertIn("Project Archive", candidates[1]["detail"])

            file_request = f"Choose {first} or {second} as the report"
            file_ledger = ledger_for(file_request, (str(first), str(second)), ("file", "file"))
            file_candidates = grounded_candidates({}, file_ledger)
            self.assertEqual([row["label"] for row in file_candidates], ["summary.pdf", "summary.pdf"])
            self.assertNotEqual(file_candidates[0]["detail"], file_candidates[1]["detail"])

    def test_symlinks_missing_files_and_non_files_are_never_candidates(self):
        with tempfile.TemporaryDirectory() as root:
            real = Path(root) / "real.txt"
            real.write_text("evidence", encoding="utf-8")
            link = Path(root) / "alias.txt"
            link.symlink_to(real)
            missing = Path(root) / "missing.txt"
            known_folder = Path(root) / "Folder"
            known_folder.mkdir()
            request = f"Use {link}, {missing}, or {known_folder} as input"
            ledger = ledger_for(request, (str(link), str(missing), str(known_folder)), ("file", "file", "folder"))
            rows = grounded_candidates({}, ledger)
            self.assertEqual([row["binding"]["path"] for row in rows], [os.path.normpath(known_folder)])

    def test_document_candidates_require_native_uuid_and_distinguishing_metadata(self):
        first, second = str(uuid.uuid4()), str(uuid.uuid4())
        request = "Edit the open Reports document"
        ledger = ledger_for(request)
        rows = [
            {"selection_id": first, "title": "Reports", "application": "Numbers", "location": "Downloads"},
            {"selection_id": second, "title": "Reports", "application": "Numbers", "location": "Project Archive"},
            {"selection_id": "not-a-window", "title": "Reports", "application": "Numbers"},
        ]
        candidates = grounded_candidates({"working_document_candidates": rows}, ledger)
        self.assertEqual(len(candidates), 2)
        self.assertEqual(candidates[0]["kind"], "document")
        self.assertNotEqual(candidates[0]["detail"], candidates[1]["detail"])
        self.assertEqual(
            candidate_fingerprint("Reports", "document", candidates),
            candidate_fingerprint("Reports", "document", list(reversed(candidates))),
        )
        prompt = runtime.desktop_instruction(request, {"working_document_candidates": rows}, [], ledger)
        self.assertIn("2 to 8 matching IDs from target_choice_candidates", prompt)

        indistinguishable = [dict(row, location=None) for row in rows[:2]]
        candidates = grounded_candidates({"working_document_candidates": indistinguishable}, ledger)
        with self.assertRaisesRegex(ValueError, "cannot distinguish"):
            validate_choice_shape({"reference": "Reports", "requirement_id": "r1", "scope": "document",
                                   "candidate_ids": [row["id"] for row in candidates]},
                                  {"working_document_candidates": indistinguishable}, ledger,
                                  lambda path, message: (_ for _ in ()).throw(ValueError(f"{path} {message}")))

    def test_choice_shape_rejects_unquoted_or_unrelated_candidates_and_multi_input_collapse(self):
        with tempfile.TemporaryDirectory() as root:
            a, b = Path(root) / "a.pdf", Path(root) / "b.pdf"
            a.write_bytes(b"a")
            b.write_bytes(b"b")
            request = f"Compare each file {a} and {b}"
            ledger = ledger_for(request, (str(a), str(b)), ("file", "file"))
            candidates = grounded_candidates({}, ledger)
            choice = {"reference": str(a), "requirement_id": "r1", "scope": "source",
                      "candidate_ids": [row["id"] for row in candidates]}
            fail = lambda path, message: (_ for _ in ()).throw(ValueError(f"{path} {message}"))
            with self.assertRaisesRegex(ValueError, "cannot reduce"):
                validate_choice_shape(choice, {}, ledger, fail)
            choice["reference"] = "not present in the request"
            with self.assertRaisesRegex(ValueError, "quote the current task"):
                validate_choice_shape(choice, {}, ledger, fail)

    def test_response_validator_accepts_only_grounded_current_choice(self):
        with tempfile.TemporaryDirectory() as root:
            a, b = Path(root) / "Reports", Path(root) / "Archive" / "Reports"
            a.mkdir(parents=True)
            b.mkdir(parents=True)
            request = f"Choose {a} or {b} as the output folder"
            ledger = ledger_for(request, (str(a), str(b)), ("folder", "folder"))
            candidates = grounded_candidates({}, ledger)
            decision = {"status": "needs_choice", "choice": {
                "reference": str(a), "requirement_id": "r1", "scope": "destination",
                "candidate_ids": [row["id"] for row in candidates],
            }}
            accepted = validate_response(decision, "planning", {}, ledger)
            self.assertEqual(accepted["choice"]["candidate_ids"], [row["id"] for row in candidates])
            malformed = dict(decision, action={"type": "click", "x": 1, "y": 1})
            with self.assertRaisesRegex(ResponseValidationError, "must be omitted"):
                validate_response(malformed, "planning", {}, ledger)
            forged = {"status": "needs_choice", "choice": dict(decision["choice"], candidate_ids=["invented", candidates[1]["id"]])}
            with self.assertRaisesRegex(ResponseValidationError, "only candidates"):
                validate_response(forged, "planning", {}, ledger)

    def test_more_than_eight_plausible_targets_requires_narrower_request(self):
        with tempfile.TemporaryDirectory() as root:
            paths = []
            for index in range(9):
                path = Path(root) / f"Reports-{index}"
                path.mkdir()
                paths.append(str(path))
            request = "Choose one Reports folder: " + " or ".join(paths)
            ledger = ledger_for(request, paths, ["folder"] * len(paths))
            candidates = grounded_candidates({}, ledger)
            fail = lambda path, message: (_ for _ in ()).throw(ValueError(f"{path} {message}"))
            with self.assertRaisesRegex(ValueError, "more than eight"):
                validate_choice_shape({"reference": "Reports", "requirement_id": "r1", "scope": "destination",
                                       "candidate_ids": [row["id"] for row in candidates[:2]]}, {}, ledger, fail)


if __name__ == "__main__":
    unittest.main()
