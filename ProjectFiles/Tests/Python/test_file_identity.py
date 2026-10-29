"""Filesystem identity must survive native validation, reuse and proof recording."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest
import uuid
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from action_contract_generated import (validate_action, validate_native_result, validate_native_payload,
                                      ActionContractError, NativeProtocolError)
from task_evidence import TaskEvidenceLedger
from expected_effects import ExpectedEffect
from evidence_fixtures import native_result, native_check, native_batch
import openclaw_runtime as runtime
from prompt_compiler import recovery_condition, decision_rules


class FileIdentityTests(unittest.TestCase):
    action = {'type':'write_file', 'path':'/fixture/a', 'content':'A'}
    def test_absence_precondition_is_explicit_and_strict(self):
        for mode in ['bound', 'absent']:
            self.assertEqual(validate_action({**self.action, 'precondition':mode})['precondition'], mode)
        for value in [False, None, 1, 'exists', 'ABSENT']:
            with self.assertRaises(ActionContractError): validate_action({**self.action, 'precondition':value})
        with self.assertRaises(ActionContractError):
            validate_action({'type':'read_file','path':'/fixture/a','precondition':'absent'})

    def test_missing_or_malformed_identity_never_proves_file_action(self):
        for kind in ['read_file','write_file']:
            action = {**self.action,'type':kind}
            for key in ['file_identity','file_version','parent_identity']:
                for value in [None,'', 'inode', 123, False]:
                    result = native_result(action); result[key] = value
                    ledger = TaskEvidenceLedger('Write A to /fixture/a')
                    with self.assertRaises(NativeProtocolError): ledger.record_action(action,result)
                    self.assertEqual(ledger.action_sequence,0); self.assertEqual(ledger.evidence,{})
                result = native_result(action); result.pop(key)
                with self.assertRaises(NativeProtocolError): validate_native_result(result,action)

    def test_overwrite_hash_cannot_disagree_with_committed_contents(self):
        result = native_result(self.action)
        result['file_sha256'] = '0' * 64
        with self.assertRaises(NativeProtocolError): validate_native_result(result,self.action)
        result = native_result(self.action); result.pop('file_sha256')
        with self.assertRaises(NativeProtocolError): validate_native_result(result,self.action)

    def test_verified_checks_require_identity_but_failed_checks_need_no_proof(self):
        for kind in ['file_exists','directory_exists','path_absent','file_contents']:
            check = {'type':kind,'path':'/fixture/a'}
            if kind=='file_contents':check['content']='A'
            actual = native_check(check)
            validate_native_payload('check_result',actual)
            for key in ['parent_identity'] + ([] if kind=='path_absent' else ['file_identity','file_version']):
                missing = deepcopy(actual);missing.pop(key)
                with self.assertRaises(NativeProtocolError):validate_native_payload('check_result',missing)
            validate_native_payload('check_result',native_check(check,False))

    def test_write_proof_and_reused_expectation_retain_committed_identity(self):
        ledger = TaskEvidenceLedger('Write A to /fixture/a')
        result = native_result(self.action)
        ledger.record_action(self.action,result)
        self.assertEqual(len(ledger.evidence),3)
        for evidence in ledger.evidence.values():
            for key in ['file_identity','file_version','parent_identity']:
                self.assertEqual(evidence['fact'][key],result[key])
        expected = {'type':'file_contents','path':self.action['path'],'content':'A'}
        reused = ExpectedEffect(expected,{}).reuse_native(self.action,result)
        self.assertEqual(reused['outcome'],'verified')
        self.assertEqual(reused['evidence']['file_identity'],result['file_identity'])

    def test_verified_write_digest_is_cached_for_exact_same_task_contents_only(self):
        generation = '00000000-0000-4000-8000-000000000123'
        ledger = TaskEvidenceLedger('Write A to /fixture/a', generation)
        result = native_result(self.action)
        ledger.record_action(self.action, result)
        check = {'type': 'file_contents', 'path': self.action['path'], 'content': 'A'}
        proof = ledger.file_digest_proof_for(check)
        self.assertEqual(proof, {
            'task_generation_id': generation, 'path': self.action['path'],
            'file_identity': result['file_identity'], 'file_version': result['file_version'],
            'parent_identity': result['parent_identity'], 'file_size': 1,
            'file_sha256': result['file_sha256'],
        })
        self.assertIsNone(ledger.file_digest_proof_for({**check, 'content': 'B'}))
        other_task = TaskEvidenceLedger('Write A to /fixture/a', str(uuid.uuid4()))
        self.assertIsNone(other_task.file_digest_proof_for(check))

    def test_digest_proof_reconciliation_discards_replaced_or_modified_objects(self):
        generation = str(uuid.uuid4())
        ledger = TaskEvidenceLedger('Write A to /fixture/a', generation)
        ledger.record_action(self.action, native_result(self.action))
        check = {'type': 'file_contents', 'path': self.action['path'], 'content': 'A'}
        old = ledger.file_digest_proof_for(check)
        self.assertIsNotNone(old)

        replacement = native_check(check, file_identity='a' * 64, file_version='b' * 64)
        ledger.reconcile_file_digest_check(check, old,
            native_batch([check], [replacement]))
        refreshed = ledger.file_digest_proof_for(check)
        self.assertNotEqual(refreshed['file_identity'], old['file_identity'])
        self.assertEqual(refreshed['file_identity'], 'a' * 64)

        current = ledger.file_digest_proof_for(check)
        changed_contents = native_check(check, verified=False,
            file_identity='c' * 64, file_version='d' * 64)
        ledger.reconcile_file_digest_check(check, current,
            native_batch([check], [changed_contents]))
        self.assertIsNone(ledger.file_digest_proof_for(check))

    def test_bridge_forwards_and_reconciles_private_digest_proof(self):
        generation = str(uuid.uuid4())
        ledger = TaskEvidenceLedger('Write A to /fixture/a', generation)
        ledger.record_action(self.action, native_result(self.action))
        context = runtime.TaskContext(ledger.task, 1, generation, ledger=ledger)
        context.machine.phase = runtime.Phase.VERIFYING
        check = {'type': 'file_contents', 'path': self.action['path'], 'content': 'A'}
        token = runtime.current_task.set(context)
        try:
            batch = native_batch([check], [native_check(check)])
            response = {'kind': 'bridge_response', 'request_id': 'fixture', 'ok': True, 'result': batch}
            with mock.patch.object(runtime, 'bridge_exchange', return_value=response) as exchange:
                runtime.bridge_call('check_effect', 1, check=check)
            self.assertEqual(exchange.call_args.args[2]['file_digest_proof'], ledger.file_digest_proof_for(check))
            proof = exchange.call_args.args[2]['file_digest_proof']

            changed = native_check(check, verified=False, file_identity='e' * 64, file_version='f' * 64)
            response['result'] = native_batch([check], [changed])
            with mock.patch.object(runtime, 'bridge_exchange', return_value=response) as exchange:
                runtime.bridge_call('check_effect', 1, check=check)
            # The stale candidate is sent so native code can compare the
            # current descriptor metadata and fall back to a full inspection.
            self.assertEqual(exchange.call_args.args[2]['file_digest_proof'], proof)
            self.assertIsNone(ledger.file_digest_proof_for(check))

            # Once the native response established that the old object no
            # longer matched, later checks cannot reuse that candidate.
            with mock.patch.object(runtime, 'bridge_exchange', return_value=response) as exchange:
                runtime.bridge_call('check_effect', 1, check=check)
            self.assertNotIn('file_digest_proof', exchange.call_args.args[2])
        finally:
            runtime.current_task.reset(token)

    def test_outcome_checks_preserve_each_checked_object(self):
        check = {'type':'file_contents','path':'/fixture/a','content':'A'}
        actual = native_check(check)
        ledger = TaskEvidenceLedger('Inspect /fixture/a')
        ledger.record_check(check,actual,self.action)
        fact = next(iter(ledger.evidence.values()))['fact']
        self.assertEqual(fact['file_identity'],actual['file_identity'])
        self.assertEqual(fact['file_version'],actual['file_version'])

    def test_conflict_selects_read_only_reinspection_and_keeps_recovery_bounded(self):
        self.assertEqual(runtime.action_failure_recovery('file_conflict'),'inspect_filesystem_again')
        condition = recovery_condition([{'action':self.action,'result':{'error_code':'file_conflict','outcome':'delivered_unconfirmed'}}])
        self.assertEqual(condition['code'],'file_conflict')
        rules = decision_rules(False,condition,False)
        self.assertIn('read-only',rules)

if __name__ == '__main__':unittest.main()
