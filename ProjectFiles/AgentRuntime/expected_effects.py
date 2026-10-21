"""Bounded, read-only postconditions. Free text is never executed or guessed."""
from __future__ import annotations

import base64
import hashlib
import os
import time
from typing import Any, Callable

from action_contract_generated import ActionContractError, validate_contract_field, validate_outcome_check
from observation_context import structural_identity, observation_indexes

EXPECTED_EFFECT_VERSION = 1
FILE_EFFECTS = {"file_contents", "file_exists", "directory_exists", "path_absent"}
FIELD_ROLES = {"AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"}


class ExpectedEffectError(RuntimeError): pass


def fail(path: str, message: str) -> None: raise ExpectedEffectError(path + " " + message)


def field(name, value, path):
    try: return validate_contract_field(name, value, path)
    except ActionContractError as error: raise ExpectedEffectError(str(error)) from error


def validate_expectation(value: Any, observation: dict | None = None) -> Any:
    if isinstance(value, str): return field('text', value, 'expected_result')
    if not isinstance(value, dict): fail('expected_result', 'must be a string or a check object')
    kind = value.get('type')
    field('element_id', kind, 'expected_result.type')
    if kind in FILE_EFFECTS:
        try: return validate_outcome_check(value, 'expected_result')
        except ActionContractError as error: raise ExpectedEffectError(str(error)) from error
    if kind not in {'dialog_appeared', 'field_value'}:
        return dict(value)  # Unrecognized expectations are unconfirmed, never executed.
    required = {'pid', 'title'} if kind == 'dialog_appeared' else {'element_id', 'value'}
    allowed = required | {'type', 'pid', 'window_title'} if kind == 'dialog_appeared' else required | {'type', 'pid'}
    if set(value) - allowed: fail('expected_result', 'contains unsupported parameters')
    for key in sorted(required):
        if key not in value: fail('expected_result.' + key, 'is required')
    if 'pid' in value: field('pid', value['pid'], 'expected_result.pid')
    if kind == 'dialog_appeared':
        field('element_id', value['title'], 'expected_result.title')
        if 'window_title' in value: field('text', value['window_title'], 'expected_result.window_title')
        if observation is not None and value['pid'] not in observation_indexes(observation).applications_by_pid:
            fail('expected_result.pid', 'must reference an app in the current observation')
    else:
        field('element_id', value['element_id'], 'expected_result.element_id')
        field('text', value['value'], 'expected_result.value')
        if observation is not None:
            target = observation_indexes(observation).element(value['element_id'])
            if target is None: fail('expected_result.element_id', 'must reference the current observation')
            if target.get('role') not in FIELD_ROLES or 'secure' in str(target.get('subrole', '')).casefold():
                fail('expected_result.element_id', 'must reference a nonsecure observed text field')
            field('pid', target.get('pid'), 'expected_result.element_id')
            if 'pid' in value and value['pid'] != target.get('pid'): fail('expected_result.pid', "must match the selected field's app")
    return dict(value)


def path_key(path: str) -> str: return os.path.normpath(os.path.expanduser(path))


def content_bytes(value: dict) -> bytes:
    return base64.b64decode(value['content'], validate=True) if value.get('encoding') == 'base64' else value['content'].encode('utf-8')


class ExpectedEffect:
    def __init__(self, value: Any, before: dict):
        self.spec = validate_expectation(value, before) if value is not None else None
        self.kind = self.spec.get('type') if isinstance(self.spec, dict) else None
        self.supported = self.kind in FILE_EFFECTS | {'dialog_appeared', 'field_value'}
        indexes = observation_indexes(before) if self.supported else None
        self.target = indexes.element(self.spec.get('element_id')) if self.kind == 'field_value' else None
        self.before = before
        pid = self.target.get('pid') if self.target else self.spec.get('pid') if self.supported and isinstance(self.spec, dict) else None
        self.application = indexes.application(pid) if indexes else None
        self.baseline_dialogs = self.dialogs(before) if self.kind == 'dialog_appeared' else []

    def result(self, verified=False, reason=None, **evidence):
        return {'outcome': 'verified' if verified else 'unconfirmed',
                'check': self.kind if self.supported else 'unsupported',
                **({'reason': reason} if reason else {}), **evidence}

    def unknown(self): return self.result(reason='unsupported_expectation' if self.spec is not None else 'expectation_not_supplied')

    def dialogs(self, observation):
        return [e for e in observation_indexes(observation).elements_by_pid.get(self.spec['pid'], ())
                if (e.get('role') in {'AXSheet', 'AXDialog'} or e.get('subrole') == 'AXDialog')
                and e.get('title') == self.spec['title']
                and ('window_title' not in self.spec or e.get('window_title') == self.spec['window_title'])]

    @staticmethod
    def unique(elements):
        return list({e.get('native_identity') or e.get('id'): e for e in elements}.values())

    def field_candidates(self, observation: dict) -> list[dict]:
        """Identity matching shared by effect checks and prerequisite guards."""
        target = self.target
        if not target: return []
        indexes, before_indexes = observation_indexes(observation), observation_indexes(self.before)
        if self.application:
            current = indexes.application(self.application['pid']) or {}
            if any(current.get(k) != self.application.get(k) for k in ('pid', 'name', 'bundle_id')): return []
        identity = structural_identity(target, self.before, before_indexes)
        return [e for e in indexes.elements_by_pid.get(target.get('pid'), ())
                if e.get('role') == target.get('role') and e.get('title') == target.get('title')
                and e.get('window_title') == target.get('window_title')
                and ('secure' not in str(e.get('subrole', '')).casefold())
                and structural_identity(e, observation, indexes) == identity
                and (not target.get('native_identity') or e.get('native_identity') == target['native_identity'])]

    def observe(self, observation: dict) -> dict:
        if not self.supported: return self.unknown()
        if self.kind in FILE_EFFECTS: return self.result(reason='readback_required')
        if self.before.get('task_generation_id') and observation.get('task_generation_id') != self.before['task_generation_id']:
            return self.result(reason='foreign_observation')
        if self.application:
            current = observation_indexes(observation).application(self.application['pid']) or {}
            if any(current.get(k) != self.application.get(k) for k in ('pid', 'name', 'bundle_id')):
                return self.result(reason='application_changed')
        if self.kind == 'dialog_appeared':
            candidates = self.unique(self.dialogs(observation))
            if len(candidates) != 1: return self.result(reason='ambiguous_target' if candidates else 'expected_dialog_missing')
            target = candidates[0]
            if self.baseline_dialogs:
                baseline = {e.get('native_identity') for e in self.baseline_dialogs}
                if not target.get('native_identity') or None in baseline or target['native_identity'] in baseline:
                    return self.result(reason='dialog_already_present')
        else:
            target = self.target
            if not target: return self.result(reason='target_missing')
            candidates = self.field_candidates(observation)
            if len(self.unique(candidates)) != 1: return self.result(reason='ambiguous_target' if candidates else 'target_missing')
            complete = [e for e in candidates if e.get('value_complete') is True]
            if not complete or any(e.get('value', '') != self.spec['value'] for e in complete):
                return self.result(reason='field_value_incomplete' if not complete else 'field_value_mismatch')
            target = complete[0]
        return self.result(True, element_id=target['id'], observation_revision=observation.get('observation_revision'))

    def native_check(self, response: dict) -> dict:
        from action_contract_generated import validate_check_batch
        validate_check_batch(response, requested_checks=[self.spec])
        if not isinstance(response, dict) or response.get('requested_checks') != [self.spec]: return self.result(reason='check_response_mismatch')
        checks = response.get('checks')
        if not isinstance(checks, list) or len(checks) != 1 or not isinstance(checks[0], dict): return self.result(reason='check_response_mismatch')
        actual = checks[0]
        if actual.get('type') != self.kind or actual.get('path') != path_key(self.spec['path']): return self.result(reason='check_response_mismatch')
        if actual.get('verified') is not True: return self.result(reason='expected_file_mismatch')
        if self.kind == 'file_contents' and actual.get('content_sha256') != hashlib.sha256(content_bytes(self.spec)).hexdigest():
            return self.result(reason='check_response_mismatch')
        return self.result(True, evidence=actual)

    def reuse_native(self, action: dict, result: dict) -> dict | None:
        """Reuse exact native readback, never a generic successful exit/change."""
        if self.kind not in FILE_EFFECTS: return None
        from action_contract_generated import validate_native_result
        validate_native_result(result, action)
        kind = action.get('type')
        actual = None
        if kind == 'run_command' and result.get('timed_out') is False:
            for check, checked in zip(action.get('checks', []), result.get('checks', [])):
                if check == self.spec: actual = checked; break
        elif kind in {'read_file', 'write_file'} and action.get('path') and path_key(action['path']) == path_key(self.spec['path']) \
                and result.get('path') == path_key(self.spec['path']):
            if kind == 'write_file' and result.get('verified') is True and result.get('mode') == 'overwrite' \
                    and type(result.get('bytes_written')) is int and result['bytes_written'] == len(content_bytes(action)) \
                    and result.get('content_sha256') == hashlib.sha256(content_bytes(action)).hexdigest():
                if self.kind == 'file_exists' or (self.kind == 'file_contents' and content_bytes(action) == content_bytes(self.spec)):
                    actual = {'type': self.kind, 'path': result['path'], 'verified': True, 'content_sha256': result['content_sha256']}
            elif kind == 'read_file' and result.get('truncated') is False and result.get('encoding') in {'utf-8', 'base64'} \
                    and type(result.get('bytes_returned')) is int:
                try: data = content_bytes(result)
                except (KeyError, ValueError, UnicodeEncodeError): return None
                if len(data) == result['bytes_returned'] and hashlib.sha256(data).hexdigest() == result.get('content_sha256') \
                        and self.kind == 'file_contents' and data == content_bytes(self.spec):
                    actual = {'type': self.kind, 'path': result['path'], 'verified': True, 'content_sha256': result['content_sha256']}
        if actual:
            actual.update(outcome='verified' if actual['verified'] else 'delivered_unconfirmed', verification_scope=self.kind)
            if self.kind != 'file_contents': actual.pop('content_sha256', None)
            return self.native_check({'requested_checks': [self.spec], 'checks': [actual],
                'verified': actual['verified'], 'outcome': actual['outcome'], 'verification_scope': 'requested_outcomes'})
        return None

    def wait_file(self, check: Callable[[dict], dict], timeout=2.0, now=time.monotonic, sleep=time.sleep, count=lambda: None) -> dict:
        deadline = now() + timeout
        while True:
            count()
            try: result = self.native_check(check(self.spec))
            except Exception as error:
                if getattr(error, 'code', None) in {'cancelled', 'permission_denied', 'protected_target', 'secure_input', 'protocol_error'}: raise
                return self.result(reason='check_unavailable')
            if result['outcome'] == 'verified' or now() >= deadline: return result
            sleep(max(0.0, min(0.15, deadline - now())))
