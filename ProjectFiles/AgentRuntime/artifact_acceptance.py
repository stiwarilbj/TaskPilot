"""Bounded task-local artifact facts. No I/O, inference, or model requests."""
from __future__ import annotations

from dataclasses import dataclass
import os

from action_contract_generated import (ActionContractError, NativeProtocolError, expected_file_format,
                                       validate_native_payload)

ARTIFACT_ACCEPTANCE_VERSION = 1


def structure_matches(proof, path) -> bool:
    expected = expected_file_format(path)
    if not expected or not isinstance(proof, dict):
        return False
    try:
        validate_native_payload('artifact_format', proof)
    except (ActionContractError, NativeProtocolError):
        return False
    return proof['format'] == expected


@dataclass(frozen=True)
class ArtifactMember:
    path: str
    requirement_ids: tuple[str, ...]
    evidence_ids: tuple[str, ...]
    status: str
    format: str | None


@dataclass(frozen=True)
class ArtifactSetReport:
    members: tuple[ArtifactMember, ...]
    bounded: bool = True

    @property
    def complete(self):
        return self.bounded and all(item.status != 'pending' for item in self.members)

    def prompt_state(self):
        return {
            'version': ARTIFACT_ACCEPTANCE_VERSION,
            'complete': self.complete,
            'scope': 'exact_requested_destinations_and_native_structure',
            'members': [dict(path=item.path, requirement_ids=list(item.requirement_ids),
                             evidence_ids=list(item.evidence_ids), status=item.status, format=item.format)
                        for item in self.members],
            'limits': 'Structure facts do not prove semantic contents, rendering, or unsupported formats.',
        }


def inspect_output_set(ledger) -> ArtifactSetReport:
    """Match every declared outcome at its exact requested path. A proof for a
    sibling file, similarly named file, or just one member cannot fill the set.
    Full-request coverage remains the independent verifier's responsibility.
    Historical write facts stay historical; mutable facts obey ledger freshness.
    """
    by_path = {}
    for identifier, requirement in ledger.requirements.items():
        check = requirement['check']
        if (requirement.get('state') == 'superseded' or requirement.get('scope') == 'prerequisite' or
                check.get('type') not in {'file_exists', 'file_contents', 'file_written', 'file_append'}):
            continue
        path = os.path.normpath(os.path.expanduser(check['path']))
        by_path.setdefault(path, []).append((identifier, requirement))
        if len(by_path) > 100:
            return ArtifactSetReport((), bounded=False)
    members = []
    for path, requirements in by_path.items():
        expected = expected_file_format(path)
        refs = []
        ready = True
        for identifier, requirement in requirements:
            matches = []
            # Use the maintained requirement index, never scan all evidence.
            for ref in reversed(ledger._evidence_by_requirement.get(identifier, {})):
                evidence = ledger.evidence.get(ref)
                if (evidence and ledger.requirement_matches(identifier, evidence) and
                        (not expected or structure_matches(evidence['fact'].get('file_format'), path))):
                    matches.append(ref)
                    break
            if not matches or requirement['state'] != 'proven':
                ready = False
            refs.extend(matches[-1:])
        members.append(ArtifactMember(path, tuple(i for i, _ in requirements),
                                      tuple(dict.fromkeys(refs)),
                                      ('structure_verified' if expected else 'bytes_only_structure_unverified') if ready else 'pending',
                                      expected))
    return ArtifactSetReport(tuple(members))
