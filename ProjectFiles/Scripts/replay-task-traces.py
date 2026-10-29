#!/usr/bin/env python3
"""Run synthetic traces offline; report only fixed trace codes and seed order."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tests/ReplayLab'))
from catalog import IDS, load_catalog, ordered_events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--trace', choices=sorted(IDS))
    parser.add_argument('--seed', type=int)
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    if args.seed is not None and not 0 <= args.seed < 2**64: parser.error('seed must be an unsigned 64-bit integer')
    traces = [t for t in load_catalog() if args.trace is None or t['id'] == args.trace]
    for trace in traces:
        for seed in [args.seed] if args.seed is not None else trace['seeds']:
            print(f"{trace['id']} seed={seed}: " + ' -> '.join(e['event'] for e in ordered_events(trace, seed)), flush=True)
    if args.list: return 0
    env = dict(os.environ, TASKPILOT_REPLAY_PYTHON=sys.executable)
    if args.trace: env['TASKPILOT_REPLAY_TRACE'] = args.trace
    else: env.pop('TASKPILOT_REPLAY_TRACE', None)
    if args.seed is not None: env['TASKPILOT_REPLAY_SEED'] = str(args.seed)
    else: env.pop('TASKPILOT_REPLAY_SEED', None)
    # An isolated group lets the watchdog stop the test runner and its children.
    # Builds tests but never launches TaskPilot, OpenClaw, or a desktop app.
    process = subprocess.Popen(['swift', 'test', '--package-path', str(ROOT), '--disable-sandbox',
        '--filter', 'TaskReplayLabTests'], env=env, start_new_session=True)
    try:
        return process.wait(timeout=240)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
        print('replay_runner_deadline', file=sys.stderr)
        return 1


if __name__ == '__main__': raise SystemExit(main())
