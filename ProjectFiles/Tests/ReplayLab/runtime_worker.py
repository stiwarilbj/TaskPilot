"""Test-only subprocess: real task loop, validators, inbox and stdio protocol.

Only provider/readiness/image acquisition and desktop effects are synthetic.
This file is never bundled. No network, native input, or user data is used.
"""
import contextlib
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'AgentRuntime'), str(ROOT / 'Tests/Python')]
from catalog import load_catalog
import openclaw_runtime as runtime
from task_execution import ExecutionMachine, Phase, current_task
from action_receipts import BridgeReplyLost
from coordinate_fixtures import fixture_coordinates
from evidence_fixtures import VerificationSessions, proof_response, with_requirements

TASK = 'Press the synthetic counter once'


class FragmentedOutput:
    """Exercise Swift framing with real partial stdout writes, not saved bytes."""
    def write(self, text):
        data = text.encode('utf-8')
        while data:
            count = os.write(1, data[:11])
            data = data[count:]
        return len(text)
    def flush(self): pass


def run(trace_id, scratch):
    trace = next(t for t in load_catalog() if t['id'] == trace_id)
    # Test adapters must never inherit an active installation or touch it.
    os.environ.pop('TASKPILOT_MANAGED_DESCRIPTOR', None)
    runtime.read_runtime_configuration(require_generation=True)
    signal.signal(signal.SIGTERM, runtime._stop_handler)
    signal.signal(signal.SIGINT, runtime._stop_handler)
    sys.stdout = FragmentedOutput()
    exchange = runtime.bridge_exchange
    transition = ExecutionMachine.transition
    lost = False
    phases = []

    def observe_exchange(method, display, params, timeout, working_document_revision=None):
        nonlocal lost
        if method == 'action_receipt':
            assert current_task.get().machine.phase == Phase.RECONCILING
            runtime.emit('status', message='replay:receipt_reconciliation')
        reply = exchange(method, display, params, timeout, working_document_revision=working_document_revision)
        if method == 'observe' and reply.get('ok'):
            result = reply['result']
            result.update(fixture_coordinates(result['observation_revision'], controls=1))
            # Synthetic acquisition marker, never an image or screenshot.
            path = Path(directory) / 'acquisition.bin'
            path.write_bytes(b'synthetic-acquisition')
            result['screenshot_path'] = str(path)
        if method == 'act' and reply.get('ok'):
            if trace['fault'] == 'process_exit': os._exit(17)
            if trace['fault'] == 'disconnected':
                raise BridgeReplyLost('Synthetic disconnected response', connected=False)
            if trace['fault'] == 'lost_reply' and not lost:
                lost = True
                raise BridgeReplyLost('Synthetic reply loss')
        return reply

    def transitioned(machine, destination, **facts):
        transition(machine, destination, **facts)
        phases.append(destination.value)
        runtime.emit('status', message='replay:phase:' + destination.value)
        if destination == Phase.DRAINING and machine.pending_action is not None:
            runtime.emit('status', message='replay:unresolved_mutation')

    class Client(VerificationSessions):
        prompt_calls = model_switches = 0
        selected_model = None
        def select_model(self, model): self.selected_model = model
        def prompt(self, instruction, image):
            self.prompt_calls += 1
            c = current_task.get()
            assert c.machine.pending_action is None
            if c.machine.phase == Phase.VERIFYING:
                assert c.observation['elements'][0]['value'] == 1
                # Genuine independent verification path with fresh ledger IDs.
                exchange('lab_checkpoint', 1, {'stage': 'verification'}, 10)
                return json.dumps(proof_response(c.ledger))
            exchange('lab_checkpoint', 1, {'stage': 'model_response'}, 10)
            element = c.observation['elements'][0]
            if element['value'] == 1:
                return json.dumps(with_requirements({'status': 'done'}, TASK))
            return json.dumps(with_requirements({'status': 'act',
                'intended_target': 'Synthetic counter', 'expected_result': 'Counter shows one',
                'action': {'type': 'press', 'element_id': element['id'], 'pid': 4242}}, TASK))
        def close(self): pass

    # Settling acquisition is synchronous and deterministic here; the real
    # reconciliation/verification code still decides what constitutes proof.
    def effect(display, before, action, result, *args, **kwargs):
        return runtime.bridge_call('observe', display), result

    client = Client()
    router = runtime.AdaptiveModelRouter(lambda *args, **kwargs: None)
    # The controller owns the parent and removes it after drainage, even when
    # this fixture deliberately exits without running Python finally blocks.
    with tempfile.TemporaryDirectory(prefix='acquisition-', dir=scratch) as directory, contextlib.ExitStack() as stack:
        replacements = {
            'find_openclaw': lambda path: 'synthetic',
            'prepare_runtime': lambda *args: mock.Mock(),
            'ACPClient': lambda path: client,
            'TaskModelRouter': lambda **kwargs: router,
            'bridge_exchange': observe_exchange,
            'verify_expected_effect': effect,
            'secure_input_target': lambda *args: None,
            'record_action_diagnostic': lambda *args: None,
        }
        for name, value in replacements.items(): stack.enter_context(mock.patch.object(runtime, name, value))
        stack.enter_context(mock.patch.object(ExecutionMachine, 'transition', transitioned))
        runtime.run_task(TASK, 1, 'synthetic', '')
        assert phases[-2:] == ['draining', 'finished']


if __name__ == '__main__':
    try: run(sys.argv[1], sys.argv[2])
    except SystemExit: raise
    except BaseException as error:
        # Never print a raw prompt, payload or exception. Failure is explicit.
        runtime.emit('error', message='replay_worker_failure:' + type(error).__name__)
        raise SystemExit(1)
