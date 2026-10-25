"""Grounded, task-local candidates for resolving consequential ambiguity.

Candidates come only from explicit resource references in the submitted task
or the current native observation. This module never searches directories or
the wider filesystem.
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
import uuid
from typing import Any

PROTOCOL_VERSION = 1
MAX_VISIBLE_CANDIDATES = 8
MAX_CANDIDATES = 160


def file_identity(path: str) -> dict[str, int] | None:
    try:
        info = os.lstat(os.path.expanduser(path))
    except (OSError, ValueError):
        return None
    if stat.S_ISLNK(info.st_mode) or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
        return None
    return {
        "device": int(info.st_dev), "inode": int(info.st_ino),
        "mode": int(stat.S_IFMT(info.st_mode)), "size": int(info.st_size),
        "mtime_ns": int(getattr(info, "st_mtime_ns", int(info.st_mtime * 1_000_000_000))),
    }


def _candidate(identifier: str, kind: str, label: str, detail: str, binding: dict) -> dict:
    return {"id": identifier, "kind": kind, "label": label[:160], "detail": detail[:480],
            "binding": binding}


def grounded_candidates(observation: dict[str, Any], ledger) -> list[dict[str, Any]]:
    """Return bounded candidates with private native-binding operands."""
    values: dict[str, dict[str, Any]] = {}
    for entry in ledger.inputs.resource_inputs:
        if entry.resource_kind not in {"path", "filename", "file", "folder"} or not entry.value.startswith(("/", "~/")):
            continue
        identity = file_identity(entry.value)
        if identity is None:
            continue
        path = os.path.normpath(os.path.expanduser(entry.value))
        # S_IFMT returns the type bits. Compare against the standard type value.
        if identity["mode"] == stat.S_IFDIR:
            kind = "folder"
        elif identity["mode"] == stat.S_IFREG:
            kind = "file"
        else:
            continue
        label = os.path.basename(path.rstrip(os.sep)) or path
        parent = os.path.dirname(path.rstrip(os.sep)) or os.sep
        values[entry.identifier] = _candidate(entry.identifier, kind, label, parent, {
            "kind": kind, "path": path, "identity": identity,
        })

    rows = observation.get("working_document_candidates", [])
    if isinstance(rows, list):
        for row in rows[:32]:
            if not isinstance(row, dict):
                continue
            identifier = row.get("selection_id")
            title = row.get("title")
            application = row.get("application")
            if not isinstance(identifier, str) or not isinstance(title, str) or not isinstance(application, str):
                continue
            try:
                import uuid
                if str(uuid.UUID(identifier)).lower() != identifier:
                    continue
            except (ValueError, TypeError, AttributeError):
                continue
            location = row.get("location")
            detail = application + (f" — {location}" if isinstance(location, str) and location else "")
            values[identifier] = _candidate(identifier, "document", title or "Untitled window", detail, {
                "kind": "document", "selection_id": identifier,
            })
    # Exact inputs are already bounded to 128, and native window discovery is
    # bounded to 32. Preserve the whole bounded set so a choice validator can
    # ask for narrower instructions instead of silently hiding candidates.
    return list(values.values())[:MAX_CANDIDATES]


def candidate_fingerprint(reference: str, scope: str, candidates: list[dict]) -> str:
    projection = []
    for candidate in candidates:
        binding = candidate.get("binding", {})
        # Window selection IDs are short lived and change on each observation;
        # compare stable descriptive/native document identity instead.
        if candidate.get("kind") == "document":
            identity = [candidate.get("label"), candidate.get("detail")]
        else:
            identity = [binding.get("path"), binding.get("identity")]
        projection.append([candidate.get("kind"), *identity])
    projection.sort(key=lambda row: json.dumps(row, ensure_ascii=False, sort_keys=True,
                                               separators=(",", ":")))
    canonical = json.dumps([reference, scope, projection], ensure_ascii=False,
                           sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def public_candidates(candidates: list[dict], identifiers: list[str]) -> list[dict]:
    by_id = {candidate["id"]: candidate for candidate in candidates}
    return [{key: by_id[identifier][key] for key in ("id", "kind", "label", "detail")}
            for identifier in identifiers]


def native_candidate_payload(candidates: list[dict], identifier: str) -> dict | None:
    candidate = next((item for item in candidates if item.get("id") == identifier), None)
    if candidate is None:
        return None
    return {"id": candidate["id"], **candidate["binding"]}


def validate_choice_shape(choice: Any, observation: dict[str, Any], ledger, fail,
                          requirement_ids: set[str] | None = None) -> dict:
    path = "choice"
    if not isinstance(choice, dict) or set(choice) != {"reference", "requirement_id", "scope", "candidate_ids"}:
        fail(path, "must contain reference, requirement_id, scope, and candidate_ids only")
    reference = choice.get("reference")
    requirement_id = choice.get("requirement_id")
    scope = choice.get("scope")
    identifiers = choice.get("candidate_ids")
    if not isinstance(reference, str) or not reference.strip() or len(reference.encode("utf-8")) > 240:
        fail(path + ".reference", "must be a short exact phrase from the current user instructions")
    if reference not in ledger.task:
        fail(path + ".reference", "must quote the current task or an applied correction exactly")
    allowed_requirements = requirement_ids if requirement_ids is not None else set(ledger.requirements)
    if not isinstance(requirement_id, str) or requirement_id not in allowed_requirements:
        fail(path + ".requirement_id", "must reference a requirement in this task's checklist")
    existing_requirement = ledger.requirements.get(requirement_id)
    if ((existing_requirement is not None and existing_requirement.get("state") == "superseded") or
            (requirement_id not in ledger.requirements and requirement_id not in allowed_requirements)):
        fail(path + ".requirement_id", "cannot reference a superseded requirement")
    if scope not in {"source", "destination", "document"}:
        fail(path + ".scope", "must be source, destination, or document")
    if not isinstance(identifiers, list) or not 2 <= len(identifiers) <= MAX_VISIBLE_CANDIDATES:
        fail(path + ".candidate_ids", "must list two to eight grounded candidates; ask for narrower instructions when more fit")
    if any(not isinstance(identifier, str) or not identifier for identifier in identifiers) or len(set(identifiers)) != len(identifiers):
        fail(path + ".candidate_ids", "must contain unique candidate IDs")
    candidates = grounded_candidates(observation, ledger)
    by_id = {candidate["id"]: candidate for candidate in candidates}
    compatible = {"document"} if scope == "document" else {"file", "folder"}
    compatible_candidates = [candidate for candidate in candidates if candidate["kind"] in compatible]
    if len(compatible_candidates) > MAX_VISIBLE_CANDIDATES:
        fail(path + ".candidate_ids", "more than eight plausible targets remain; ask the user to narrow the request")
    if any(identifier not in by_id for identifier in identifiers):
        fail(path + ".candidate_ids", "must reference only candidates in the current native observation or explicit task inputs")
    compatible = {"source": {"file", "folder"},
                  "destination": {"file", "folder"},
                  "document": {"document"}}[scope]
    selected = [by_id[identifier] for identifier in identifiers]
    if any(candidate["kind"] not in compatible for candidate in selected):
        fail(path + ".candidate_ids", "must match the selected source, destination, or document scope")
    visible_descriptions = [(candidate["kind"], candidate["label"].casefold(), candidate["detail"].casefold())
                            for candidate in selected]
    if len(set(visible_descriptions)) != len(visible_descriptions):
        fail(path + ".candidate_ids", "native details cannot distinguish these targets; use a correction to narrow the request")
    task_text = ledger.task.casefold()
    intentionally_multiple = any(term in task_text for term in (
        "compare", "comparison", "combine", "merge", "each file", "every file", "all files",
        "each document", "every document", "all documents", "side by side",
    ))
    if scope == "source" and intentionally_multiple and len(ledger.inputs.resource_inputs) >= 2:
        fail(path + ".scope", "cannot reduce an explicitly multi-input task to one source; resolve inputs independently or compare them together")
    return {"reference": reference, "requirement_id": requirement_id, "scope": scope,
            "candidate_ids": list(identifiers)}
