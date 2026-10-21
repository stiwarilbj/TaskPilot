"""Native payloads fail closed before receipt recovery or task proof changes."""
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'AgentRuntime'))
import action_contract_generated as contract
import openclaw_runtime as runtime
from action_receipts import reconcile_receipt
from evidence_fixtures import native_result, native_failure, native_check, native_batch
from task_evidence import TaskEvidenceLedger


class NativeResultTests(unittest.TestCase):
    def test_shared_native_protocol_corpus(self):
        corpus = json.loads((ROOT / 'Tests/Fixtures/native-result-cases.json').read_text())
        for case in corpus['cases']:
            with self.subTest(case=case['name']):
                schema, value = case['schema'], case['value']
                def validate():
                    if schema == 'action_result': return contract.validate_native_result(value, case.get('action'))
                    if schema == 'readback': return contract.validate_native_readback(value, case['action'])
                    if schema == 'receipt': return contract.validate_native_receipt(value, case.get('action_id'), case.get('action'))
                    if schema == 'check_batch': return contract.validate_check_batch(value)
                    if schema == 'evidence': return contract.validate_native_evidence(value)
                    return contract.validate_native_payload(schema, value)
                if 'error' in case:
                    with self.assertRaises(contract.NativeProtocolError) as raised: validate()
                    self.assertEqual(str(raised.exception), case['error'])
                else: self.assertEqual(validate(), value)

    def test_invalid_results_cannot_update_evidence_or_action_sequence(self):
        task = 'Write /fixture/a with A.'
        action = {'type':'write_file','path':'/fixture/a','content':'A'}
        for delta in [{'verified':None},{'verified':1},{'outcome':'delivered_unconfirmed'},
                      {'verification_scope':'execution_only'},{'action_type':'read_file'}, {'bytes_written':True}]:
            ledger = TaskEvidenceLedger(task)
            ledger.add_requirements([{'source':task,'description':'Exact contents','check':{'type':'file_contents','path':'/fixture/a','content':'A'}}])
            result = {**native_result(action), **delta}
            with self.assertRaises(contract.NativeProtocolError): ledger.record_action(action,result)
            self.assertEqual(ledger.evidence,{})
            self.assertEqual(ledger.action_sequence,0)
            self.assertEqual(ledger.requirements['r1']['state'],'pending')
            self.assertFalse(ledger.can_complete())

    def test_bad_receipt_stops_without_replay_or_extra_model_calls(self):
        action = {'type':'write_file','path':'/fixture/a','content':'A'}
        action_id = str(uuid.uuid4())
        bad = native_result(action); bad.pop('verified')
        reply = {'ok':True,'result':bad,'action_receipt':{'action_id':action_id,'state':'confirmed','terminal':True}}
        with mock.patch.object(runtime,'bridge_exchange',return_value=reply) as exchange, mock.patch.object(runtime,'routed_json_prompt') as model:
            with self.assertRaises(contract.NativeProtocolError): runtime.bridge_call('act',1,action=action,action_id=action_id)
            exchange.assert_called_once(); model.assert_not_called()

    def test_recovered_protocol_error_preserves_unknown_effect_and_never_confirms(self):
        action_id=str(uuid.uuid4())
        receipt={'action_id':action_id,'state':'unconfirmed',**native_failure('protocol_error',outcome='delivered_unconfirmed')}
        metrics=dict(receipt_queries=0,receipt_recoveries=0,receipt_unresolved=0)
        response=reconcile_receipt(action_id,lambda *args:receipt,metrics)
        self.assertFalse(response['ok']);self.assertEqual(response['error_code'],'protocol_error')
        self.assertEqual(response['outcome'],'delivered_unconfirmed')
        self.assertEqual(metrics['receipt_queries'],1)
        with mock.patch.object(runtime,'bridge_exchange',return_value={'ok':False,**native_failure('protocol_error',outcome='delivered_unconfirmed')}):
            with self.assertRaises(contract.NativeProtocolError):runtime.bridge_call('act',1,action={'type':'press','element_id':'fixture:send'})

    def test_error_flags_and_missing_result_are_never_given_defaults(self):
        for response in [{'ok':'false'},{'ok':1,'result':{}},{'ok':True},{'ok':False,'error':'failed'},
                         {'ok':False,**native_failure(), 'verified':True},
                         {'ok':False,**native_failure(), 'result':{}}]:
            with self.subTest(response=response), mock.patch.object(runtime,'bridge_exchange',return_value=response):
                with self.assertRaises(contract.NativeProtocolError):runtime.bridge_call('check_effect',1,check={'type':'file_exists','path':'/fixture/a'})

    def test_healthy_native_result_adds_no_calls_and_scope_remains_narrow(self):
        action={'type':'write_file','path':'/fixture/a','content':'A'};action_id=str(uuid.uuid4())
        reply={'ok':True,'result':native_result(action),'action_receipt':{'action_id':action_id,'state':'confirmed','terminal':True}}
        with mock.patch.object(runtime,'bridge_exchange',return_value=reply) as exchange:
            result=runtime.bridge_call('act',1,action=action,action_id=action_id)
        exchange.assert_called_once();self.assertEqual(result['verification_scope'],'file_write')

    def test_pending_reply_cannot_contradict_its_receipt(self):
        action = {'type': 'press', 'element_id': 'fixture:send'}
        action_id = str(uuid.uuid4())
        reply = {'ok': False, **native_failure(),
                 'action_receipt': {'action_id': action_id, 'state': 'dispatched', 'terminal': False}}
        with mock.patch.object(runtime, 'bridge_exchange', return_value=reply) as exchange:
            with self.assertRaises(contract.NativeProtocolError):
                runtime.bridge_call('act', 1, action=action, action_id=action_id)
        exchange.assert_called_once()

    def test_foreign_readback_never_changes_receipts_or_proof(self):
        action = {'type': 'write_file', 'path': '/fixture/a', 'content': 'A'}
        foreign = {'type': 'file_contents', 'path': '/fixture/b', 'content': 'B'}
        result = native_batch([foreign], [native_check(foreign)])
        ledger = TaskEvidenceLedger('Write A to /fixture/a and B to /fixture/b.')
        with self.assertRaises(contract.NativeProtocolError): ledger.record_action(action, result, recheck=True)
        self.assertEqual(ledger.evidence, {})
        self.assertEqual(ledger.action_sequence, 0)
        with mock.patch.object(runtime, 'bridge_exchange', return_value={'ok': True, 'result': result}) as exchange:
            with self.assertRaises(contract.NativeProtocolError):
                runtime.bridge_call('check_effect', 1, check={'type': 'file_contents', 'path': '/fixture/a', 'content': 'A'})
        exchange.assert_called_once()

    def test_nonfinite_result_numbers_and_missing_evidence_fields_fail_closed(self):
        action = {'type': 'write_file', 'path': '/fixture/a', 'content': 'A'}
        for invalid in [True, '1', 1.5, float('nan'), float('inf'), -float('inf')]:
            with self.subTest(invalid=invalid), self.assertRaises(contract.NativeProtocolError):
                contract.validate_native_result({**native_result(action), 'file_size': invalid}, action)
        ledger = TaskEvidenceLedger('Read the file.')
        with self.assertRaises(contract.NativeProtocolError): ledger.add_evidence({'type': 'file_read', 'path': '/fixture/a'})
        self.assertEqual(ledger.evidence, {})
