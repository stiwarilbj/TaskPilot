#!/usr/bin/env python3
"""Generate checked-in contract artifacts; --check never writes files."""
import argparse
import base64
import hashlib
import json
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def artifacts():
    contract = json.loads((ROOT / 'Contracts/action-contract.json').read_text())
    def resolve(value):
        if isinstance(value, dict):
            if set(value) == {'field'}: return resolve(contract['fields'][value['field']])
            if set(value) == {'limit'}: return contract['limits'][value['limit']]
            if set(value) == {'default'}:
                kind, field = value['default']
                return resolve(contract['actions'][kind]['defaults'][field])
            resolved = {k: resolve(v) for k, v in value.items() if k != 'choices_source'}
            if 'choices_source' in value: resolved['choices'] = list(contract[value['choices_source']])
            if 'variants_source' in value:
                resolved['variants'] = {name: resolve({key: item[key] for key in ('fields', 'required', 'rules', 'reject_unknown')})
                                        for name, item in contract[value['variants_source']].items()}
            return resolved
        if isinstance(value, list): return [resolve(v) for v in value]
        return value
    contract = resolve(contract)
    contract['field_order'] = list(contract['fields'])
    def order_variants(spec):
        if spec['type'] == 'array': order_variants(spec['items'])
        if spec['type'] == 'object':
            spec['field_order'] = list(spec['fields'])
            for field in spec['fields'].values(): order_variants(field)
        if spec['type'] == 'variant':
            for variant in spec['variants'].values():
                variant['field_order'] = list(variant['fields'])
                for field in variant['fields'].values(): order_variants(field)
    for spec in contract['fields'].values(): order_variants(spec)
    for spec in contract['native_schemas'].values(): order_variants(spec)
    for name, text in contract['prompt_bounds'].items():
        def substitute(match):
            parts = match.group(1).split('.')
            if parts[0] == 'defaults':
                value = contract['actions'][parts[1]]['defaults'][parts[2]]
                return json.dumps(value) if isinstance(value, bool) else str(value)
            field, bound = parts
            return f"{contract['fields'][field][bound]:g}"
        contract['prompt_bounds'][name] = re.sub(r'\{([a-z_]+\.(?:min|max)|defaults\.[a-z_]+\.[a-z_]+)\}', substitute, text)
    actions = contract['actions']
    assert type(contract['version']) is int and contract['version'] > 0 and actions
    assert type(contract['task_protocol_version']) is int and contract['task_protocol_version'] > 0
    def check_condition(test):
        assert len(test) == 1
        op, value = next(iter(test.items()))
        assert op in {'has', 'truthy', 'not', 'all', 'any', 'same_presence', 'equals', 'all_verified', 'same_value'}
        if op == 'not': check_condition(value)
        if op in {'all', 'any'}:
            for item in value: check_condition(item)
    def check_rules(rules):
        for rule in rules:
            if 'when' in rule: check_condition(rule['when'])
            if 'payload' not in rule: check_condition(rule['assert'])
    def check_field(spec):
        assert spec['type'] in {'string', 'number', 'integer', 'boolean', 'array', 'variant', 'object', 'reference'}
        if spec['type'] == 'reference': assert spec['schema'] in contract['native_schemas']
        if spec['type'] == 'object':
            for item in spec['fields'].values(): check_field(item)
            check_rules(spec['rules'])
        if spec['type'] == 'array': check_field(spec['items'])
        if spec['type'] == 'variant':
            for variant in spec['variants'].values():
                for item in variant['fields'].values(): check_field(item)
                check_rules(variant['rules'])
    for spec in contract['fields'].values(): check_field(spec)
    for spec in contract['native_schemas'].values(): check_field(spec)
    check_rules(contract['common_rules'])
    assert set(contract['modifier_aliases'].values()) <= set(contract['modifier_flags'])
    for name, action in actions.items():
        check_rules(action['rules'])
        assert action['owner'] in {'runtime', 'desktop', 'task_tool'}
        assert action['example']['type'] == name
        assert set(action['parameters']) <= set(contract['fields'])
        assert set(action['required']) <= set(action['parameters'])
        assert action['reference'].startswith(name + '(')
        described = set(re.findall(r'[a-z_]+', action['reference'].split('(', 1)[1])) - {'or', 'focused'}
        assert described <= set(action['parameters'])
        assert set(action['required']) <= described
    canonical = json.dumps(contract, sort_keys=True, ensure_ascii=True, separators=(',', ':'), allow_nan=False)
    python_template = (ROOT / 'Scripts/ContractTemplates/action_contract.py.in').read_text()
    swift_template = (ROOT / 'Scripts/ContractTemplates/ActionContract.swift.in').read_text()
    fingerprint = hashlib.sha256(json.dumps([canonical, python_template, swift_template,
                                            Path(__file__).read_text()], ensure_ascii=True).encode()).hexdigest()
    # Both languages consume the same ordered definitions; canonical ordering is
    # used only for the fingerprint so field errors remain deterministic.
    serialized = json.dumps(contract, ensure_ascii=True, separators=(',', ':'), allow_nan=False)
    header = '# Generated by Scripts/generate-action-contract.py; do not edit.\n'
    python = header + f'CONTRACT_HASH = {fingerprint!r}\nCONTRACT_VERSION = {contract["version"]}\nimport json\nCONTRACT = json.loads({serialized!r})\n'
    python += python_template
    namespace = {}
    exec(compile(python, 'action_contract_generated.py', 'exec'), namespace)
    for name in actions:
        namespace['validate_action'](namespace['action_example'](name))
        for field, value in actions[name]['defaults'].items():
            namespace['_field'](value, contract['fields'][field], 'action.' + field)
    for name, operation in contract.get('command_operations', {}).items():
        assert operation['example']['type'] == name
        assert isinstance(operation['argv'][0], str) and operation['argv'][0].startswith('/')
        assert set(re.compile(operation['request_pattern'].replace('@path@', '.+').replace('@quoted_text@', '.+')).groupindex) == set(operation['required'])
        re.compile(operation['intent_pattern'])
        for key in ('absent', 'regular_file', 'regular_file_if_present', 'directory', 'parent_directory'):
            if key in operation: assert operation['fields'][operation[key]]['format'] == 'path'
        if 'snapshot' in operation:
            snapshot = operation['snapshot']
            assert type(snapshot['max_bytes']) is int and snapshot['max_bytes'] > 0
            for key in ('source', 'destination'): assert operation['fields'][snapshot[key]]['format'] == 'path'
        if 'prerequisite' in operation:
            prerequisite = operation['prerequisite']
            assert prerequisite['operand'] in contract['command_operations'][prerequisite['type']]['fields']
            assert operation['fields'][prerequisite['parent_of']]['format'] == 'path'
        compiled = namespace['validate_action']({'type': 'run_command', 'operation': operation['example']})
        assert compiled['argv'][0].startswith('/') and compiled['checks']
    cases = '\n'.join('    case ' + name for name in actions)
    owners = '\n'.join('        case .' + name + ': return .' + definition['owner'] for name, definition in actions.items())
    checks = '\n'.join('    case ' + name for name in contract['fields']['checks']['items']['variants'])
    swift = '// Generated by Scripts/generate-action-contract.py; do not edit.\nimport Foundation\nimport CoreFoundation\nimport CryptoKit\n'
    swift += 'enum ActionOwner: String { case runtime, desktop, task_tool }\nenum ActionKind: String, CaseIterable {\n' + cases + '\n    var owner: ActionOwner {\n        switch self {\n' + owners + '\n        }\n    }\n}\nenum OutcomeCheckKind: String, CaseIterable {\n' + checks + '\n}\n'
    swift += 'enum ActionContract {\n    static let fingerprint = "' + fingerprint + '"\n    static let version = ' + str(contract['version']) + '\n'
    encoded = base64.b64encode(serialized.encode()).decode()
    swift += '    static let definition = try! JSONSerialization.jsonObject(with: Data(base64Encoded: "' + encoded + '")!) as! [String: Any]\n'
    swift += swift_template + '\n}\n'
    shell = '# Generated by Scripts/generate-action-contract.py; do not edit.\n' + f'TASKPILOT_ACTION_CONTRACT_HASH={fingerprint}\nTASKPILOT_ACTION_CONTRACT_VERSION={contract["version"]}\n'
    return {ROOT / 'Resources/OpenClaw/action-contract.sh': shell,
            ROOT / 'AgentRuntime/action_contract_generated.py': python,
            ROOT / 'Sources/OrbitAgent/Agent/Automation/ActionContract.generated.swift': swift}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    stale = []
    for path, content in artifacts().items():
        if args.check:
            if not path.exists() or path.read_text() != content: stale.append(str(path.relative_to(ROOT)))
        else: path.write_text(content)
    if stale:
        print('Outdated action contract artifacts: ' + ', '.join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__': raise SystemExit(main())
