"""Recognize complete, literal requests for operand validation, never execution."""
import os
import re

from action_contract_generated import CONTRACT, ActionContractError, validate_action

PATH = r'''(?:"(?:/|~/)[^"\r\n]+"|'(?:/|~/)[^'\r\n]+'|`(?:/|~/)[^`\r\n]+`|(?:/|~/)[^\s"'`]+)'''
QUOTED_TEXT = r'''(?:"[^"\r\n]*"|'[^'\r\n]*'|`[^`\r\n]*`)'''


def explicit_operation(task: str) -> dict | None:
    for kind, recipe in CONTRACT['command_operations'].items():
        pattern = recipe['request_pattern'].replace('@path@', PATH).replace('@quoted_text@', QUOTED_TEXT)
        match = re.fullmatch(r'\s*' + pattern + r'\s*', task, re.I)
        if not match: continue
        operation = {'type': kind}
        for key, text in match.groupdict().items():
            # Quoted paths are literal, not shell source. Ambiguous sentence
            # punctuation and compound requests stay on the general path.
            if text[0] in '"\'`': text = text[1:-1]
            elif text.endswith(('.', '?', '!', ',', ';')): return None
            operation[key] = text
        try: validate_action({'type': 'run_command', 'operation': operation})
        except ActionContractError: return None
        return operation
    return None


def same_operation(first: dict, second: dict) -> bool:
    if first.get('type') != second.get('type') or set(first) != set(second): return False
    fields = CONTRACT['command_operations'][first['type']]['fields']
    return all(first[key] == second[key] if key == 'type' or fields[key].get('format') != 'path' else
               os.path.normpath(os.path.expanduser(first[key])) == os.path.normpath(os.path.expanduser(second[key]))
               for key in first)


def matches_explicit_request(operation: dict, expected: dict) -> bool:
    if same_operation(operation, expected): return True
    # Creating the expressly named destination's parent is a valid prerequisite.
    prerequisite = CONTRACT['command_operations'][expected['type']].get('prerequisite')
    return bool(prerequisite) and operation.get('type') == prerequisite['type'] \
        and os.path.normpath(os.path.expanduser(operation[prerequisite['operand']])) == os.path.dirname(os.path.normpath(os.path.expanduser(expected[prerequisite['parent_of']])))
