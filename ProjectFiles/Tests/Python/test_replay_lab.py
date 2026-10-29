"""Sanitization and scheduling parity for the cross-process replay lab."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ReplayLab'))
from catalog import load_catalog, ordered_events


class ReplayCatalogTests(unittest.TestCase):
    def load_value(self, value):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'catalog.json'
            path.write_text(json.dumps(value), encoding='utf-8')
            return load_catalog(path)

    def test_every_fixture_has_only_closed_synthetic_codes(self):
        traces = load_catalog()
        self.assertEqual(len(traces), 7)
        self.assertEqual({t['fault'] for t in traces}, {'none', 'lost_reply', 'stale_target', 'process_exit', 'disconnected', 'malformed_result'})
        for trace in traces:
            for seed in trace['seeds']:
                self.assertEqual(ordered_events(trace, seed), ordered_events(trace, seed))
                self.assertEqual(ordered_events(trace, seed)[0]['event'], 'model_response')

    def test_seeded_races_exercise_both_orders(self):
        trace = next(t for t in load_catalog() if t['id'] == 'stop_at_delivery')
        self.assertEqual([[e['event'] for e in ordered_events(trace, seed)] for seed in [1, 3]], [
            ['model_response', 'stop', 'native_delivery'],
            ['model_response', 'native_delivery', 'stop']])

    def test_unknown_payloads_cannot_be_smuggled_into_a_fixture(self):
        value = {'version': 1, 'traces': load_catalog()}
        for field in ['prompt', 'screenshot', 'command', 'credentials', 'path', 'response', 'task_generation_id']:
            for level in [value, value['traces'][0], value['traces'][0]['events'][0]]:
                changed = copy.deepcopy(value)
                target = changed if level is value else (changed['traces'][0] if level is value['traces'][0] else changed['traces'][0]['events'][0])
                target[field] = 'synthetic-forbidden-payload'
                with self.subTest(field=field), self.assertRaises(ValueError): self.load_value(changed)

    def test_malformed_and_unbounded_schedules_are_rejected(self):
        value = {'version': 1, 'traces': load_catalog()}
        for field, invalid in [('tick', True), ('tick', -1), ('tick', 1001), ('tick', '1'), ('event', 'arbitrary content')]:
            changed = copy.deepcopy(value)
            changed['traces'][0]['events'][0][field] = invalid
            with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError): self.load_value(changed)
        for seeds in [[True], [-1], [2**64], list(range(17))]:
            changed = copy.deepcopy(value); changed['traces'][0]['seeds'] = seeds
            with self.assertRaises(ValueError): self.load_value(changed)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'invalid.json'
            for data in ['{"version":1,"version":1,"traces":[]}', ' ' * 16_385]:
                path.write_text(data)
                with self.assertRaises(ValueError): load_catalog(path)
        changed = copy.deepcopy(value)
        changed['traces'][0]['events'] *= 17
        with self.assertRaises(ValueError): self.load_value(changed)


if __name__ == '__main__': unittest.main()
