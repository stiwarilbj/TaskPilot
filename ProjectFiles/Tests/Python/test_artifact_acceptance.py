"""Only synthetic native facts; no documents, providers, or desktop actions."""
from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from action_contract_generated import NativeProtocolError, validate_native_result
from artifact_acceptance import inspect_output_set, structure_matches
from evidence_fixtures import format_proof, native_check, native_result
from task_evidence import TaskEvidenceLedger


class ArtifactAcceptanceTests(unittest.TestCase):
    task = 'Create /fixture/January.pdf and /fixture/February.pdf.'

    def ledger(self):
        ledger = TaskEvidenceLedger(self.task, 'artifact-task')
        ledger.add_requirements([{
            'source': self.task, 'description': 'Requested output',
            'check': {'type': 'file_exists', 'path': '/fixture/' + name + '.pdf'},
        } for name in ['January', 'February']])
        return ledger

    def add(self, ledger, path):
        check = {'type': 'file_exists', 'path': path}
        ledger.record_effect(check, native_check(check))

    def test_missing_member_wrong_name_and_sibling_proofs_cannot_fill_set(self):
        ledger = self.ledger()
        self.add(ledger, '/fixture/January.pdf')
        self.add(ledger, '/fixture/other/February.pdf')
        self.add(ledger, '/fixture/February.txt')
        report = inspect_output_set(ledger)
        self.assertFalse(report.complete)
        self.assertEqual([member.status for member in report.members], ['structure_verified', 'pending'])
        ledger.coverage_complete = True
        self.assertFalse(ledger.can_complete())
        self.add(ledger, '/fixture/February.pdf')
        self.assertTrue(inspect_output_set(ledger).complete)
        self.assertTrue(ledger.can_complete())

    def test_invalidation_removes_set_acceptance_and_supersession_removes_member(self):
        ledger = self.ledger()
        for path in ['/fixture/January.pdf', '/fixture/February.pdf']:
            self.add(ledger, path)
        ledger.invalidate(lambda evidence: evidence['fact'].get('path') == '/fixture/January.pdf')
        self.assertFalse(inspect_output_set(ledger).complete)
        ledger.requirements['r1']['state'] = 'superseded'
        report = inspect_output_set(ledger)
        self.assertTrue(report.complete)
        self.assertEqual([m.path for m in report.members], ['/fixture/February.pdf'])

    def test_unsupported_format_remains_explicitly_structurally_unverified(self):
        ledger = TaskEvidenceLedger('Create /fixture/report.unknown', 'artifact-task')
        ledger.add_requirements([{'source': ledger.task, 'description': ledger.task,
                                 'check': {'type': 'file_exists', 'path': '/fixture/report.unknown'}}])
        self.add(ledger, '/fixture/report.unknown')
        state = ledger.prompt_state()['artifact_acceptance']
        self.assertEqual(state['members'][0]['status'], 'bytes_only_structure_unverified')
        self.assertIsNone(state['members'][0]['format'])
        self.assertIn('unsupported formats', state['limits'])
        self.assertFalse(structure_matches(format_proof('pdf'), '/fixture/report.unknown'))

    def test_proof_requires_each_typed_stage_and_cannot_be_upgraded_from_filename(self):
        proof = format_proof('xlsx')
        self.assertTrue(structure_matches(proof, '/fixture/report.xlsx'))
        for field in list(proof):
            value = deepcopy(proof); value.pop(field)
            self.assertFalse(structure_matches(value, '/fixture/report.xlsx'), field)
        for change in [{'facts': ['zip_directory', 'content_types']}, {'structure_count': 257},
                       {'scope': 'usable'}, {'validation_version': True}, {'format': 'docx'},
                       {'facts': ['zip_directory'] * 4}, {'command': 'not allowed'}]:
            self.assertFalse(structure_matches({**proof, **change}, '/fixture/report.xlsx'))

    def test_malformed_structural_result_never_enters_receipts_or_ledger(self):
        action = {'type': 'write_file', 'path': '/fixture/result.pdf', 'content': 'fixture'}
        for changes in [{'facts': ['pdf_catalog', 'word_body']}, {'validation_version': 0},
                        {'structure_count': 0}, {'scope': 'all_requirements'}]:
            result = native_result(action)
            result['file_format'].update(changes)
            ledger = TaskEvidenceLedger('Create /fixture/result.pdf', 'artifact-task')
            with self.assertRaises(NativeProtocolError): ledger.record_action(action, result)
            self.assertEqual(ledger.action_sequence, 0)
            self.assertFalse(ledger.evidence)
        read_action = {'type': 'read_file', 'path': '/fixture/result.pdf'}
        read = native_result(read_action, content='fixture')
        read['file_format']['facts'] = ['pdf_catalog', 'word_body']
        with self.assertRaises(NativeProtocolError): validate_native_result(read, read_action)

    def test_digest_cache_carries_new_proof_and_invalidation_discards_it(self):
        ledger = TaskEvidenceLedger('Create /fixture/result.pdf', 'artifact-task')
        action = {'type': 'write_file', 'path': '/fixture/result.pdf', 'content': 'fixture'}
        ledger.record_action(action, native_result(action))
        check = {'type': 'file_contents', 'path': action['path'], 'content': action['content']}
        first = ledger.file_digest_proof_for(check)
        self.assertEqual(first['file_format'], format_proof('pdf'))
        self.assertEqual(first, ledger.file_digest_proof_for(check))
        ledger.before_action({'type': 'write_file', 'path': '/fixture/other.txt', 'content': 'new'})
        self.assertIsNone(ledger.file_digest_proof_for(check))

    def test_set_uses_maintained_indexes_and_is_json_serializable_without_io(self):
        ledger = self.ledger()
        self.add(ledger, '/fixture/January.pdf')
        with mock.patch('builtins.open', side_effect=AssertionError('No new file reads')):
            state = inspect_output_set(ledger).prompt_state()
            self.assertEqual(json.loads(json.dumps(state)), state)
        ledger.requirements['r2']['scope'] = 'prerequisite'
        self.assertEqual(len(inspect_output_set(ledger).members), 1)


if __name__ == '__main__':
    unittest.main()
