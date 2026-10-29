"""Closed synthetic trace vocabulary. Never accepts recorded task payloads."""
import json
from pathlib import Path

CATALOG = Path(__file__).resolve().parents[1] / 'Fixtures/task-replay-traces.json'
IDS = {'healthy', 'lost_reply', 'stale_observation', 'stop_at_delivery', 'exit_after_dispatch', 'disconnected_reply', 'malformed_result'}
FAULTS = {'none', 'lost_reply', 'stale_target', 'process_exit', 'disconnected', 'malformed_result'}
EVENTS = {'model_response', 'native_delivery', 'stop'}


def load_catalog(path=CATALOG):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise ValueError('replay_duplicate_field')
            result[key] = value
        return result
    with open(path, 'rb') as stream:
        data = stream.read(16_385)
    if len(data) > 16_384: raise ValueError('replay_catalog_limit')
    value = json.loads(data, object_pairs_hook=unique)
    def require(condition):
        if not condition: raise ValueError('replay_invalid_catalog')
    require(type(value) is dict and set(value) == {'version', 'traces'} and type(value['version']) is int and value['version'] == 1)
    require(type(value['traces']) is list and 1 <= len(value['traces']) <= len(IDS))
    seen = set()
    for trace in value['traces']:
        require(type(trace) is dict and set(trace) == {'id', 'fault', 'seeds', 'events'})
        require(type(trace['id']) is str and trace['id'] in IDS and trace['id'] not in seen)
        seen.add(trace['id'])
        require(type(trace['fault']) is str and trace['fault'] in FAULTS)
        require(type(trace['seeds']) is list and 1 <= len(trace['seeds']) <= 16)
        require(all(type(seed) is int and 0 <= seed < 2**64 for seed in trace['seeds']))
        require(type(trace['events']) is list and 1 <= len(trace['events']) <= 16)
        for event in trace['events']:
            require(type(event) is dict and set(event) == {'tick', 'event'})
            require(type(event['tick']) is int and 0 <= event['tick'] <= 1000)
            require(type(event['event']) is str and event['event'] in EVENTS)
        require(trace['events'][0] == {'tick': 0, 'event': 'model_response'})
        require(sum(e['event'] == 'model_response' for e in trace['events']) == 1)
        require(sum(e['event'] == 'native_delivery' for e in trace['events']) == 1)
        require(sum(e['event'] == 'stop' for e in trace['events']) == (trace['id'] == 'stop_at_delivery'))
    return value['traces']


def ordered_events(trace, seed):
    """Same xorshift64/tie selection as SeededLifecycleScheduler.swift."""
    pending = list(trace['events'])
    state = seed or 0x9E3779B97F4A7C15
    result = []
    while pending:
        earliest = min(e['tick'] for e in pending)
        candidates = [i for i, e in enumerate(pending) if e['tick'] == earliest]
        state ^= (state << 13) & (2**64 - 1)
        state ^= state >> 7
        state ^= (state << 17) & (2**64 - 1)
        result.append(pending.pop(candidates[state % len(candidates)]))
    return result
