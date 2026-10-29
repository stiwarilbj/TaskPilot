"""Explicit fictional model metadata for existing action/settling fixtures."""
from copy import deepcopy
from contextlib import contextmanager


class VerificationSessions:
    """Offline clients use distinct session identities without provider access."""
    @contextmanager
    def verification_session(self):
        planning = getattr(self, 'session_id', 'planning')
        self.verification_sessions = getattr(self, 'verification_sessions', 0) + 1
        self.session_id = f'verification-{self.verification_sessions}'
        try:
            yield
        finally:
            self.session_id = planning


def with_requirements(value, task):
    value = deepcopy(value)
    value.setdefault('requirements', [{'source': task, 'description': task,
                                     'check': {'type': 'visual', 'expected': task}}])
    return value


def proof_response(ledger):
    return {'verified': True, 'coverage_complete': True, 'message': 'Fixture outcome visible',
            'proofs': [{'requirement_id': key, 'evidence_ids': [ledger.observation_id],
                        'rationale': 'Fresh fixture observation shows the requested outcome'}
                       for key in ledger.requirements]}


def filesystem_identity(path):
    import hashlib
    return {key: hashlib.sha256((key + path).encode()).hexdigest()
            for key in ('file_identity', 'file_version', 'parent_identity')}


def native_check(check, verified=True, **fields):
    """Explicit synthetic native checker, not a production compatibility shim."""
    import hashlib
    import os
    import base64
    result = {'type': check['type'], 'verified': verified,
              'outcome': 'verified' if verified else 'delivered_unconfirmed',
              'verification_scope': check['type']}
    if 'path' in check: result['path'] = os.path.normpath(os.path.expanduser(check['path']))
    if verified and 'path' in check:
        result.update(filesystem_identity(result['path']))
        suffix = os.path.splitext(result['path'])[1].lower()
        format_name = {'.pdf': 'pdf', '.docx': 'docx', '.xlsx': 'xlsx'}.get(suffix)
        if format_name: result['file_format'] = format_proof(format_name)
        if check['type'] == 'path_absent':
            result.pop('file_identity'); result.pop('file_version')
    if verified and check['type'] == 'file_contents' and 'content' in check:
        data = base64.b64decode(check['content']) if check.get('encoding') == 'base64' else check['content'].encode()
        result['content_sha256'] = hashlib.sha256(data).hexdigest()
        result['file_sha256'] = result['content_sha256']
        result['file_size'] = len(data)
    if verified and check['type'] == 'stdout_equals' and 'text' in check:
        result['text_sha256'] = hashlib.sha256(check['text'].encode()).hexdigest()
    return {**result, **fields}


def native_batch(requested, checks):
    checks = [native_check(c, c['verified'], **{k:v for k,v in c.items() if k not in {'type','verified'}}) for c in checks]
    verified = bool(checks) and all(check['verified'] for check in checks)
    return {'requested_checks': requested, 'checks': checks, 'verified': verified,
            'outcome': 'verified' if verified else 'delivered_unconfirmed', 'verification_scope': 'requested_outcomes'}


def native_result(action, **fields):
    """Produce a complete fictional result; explicit overrides stay invalid."""
    import hashlib
    import os
    import base64
    kind = action['type']
    result = {'action_type': kind, 'verified': False, 'outcome': 'delivered_unconfirmed',
              'verification_scope': 'delivery_only'}
    if kind == 'write_file':
        data = base64.b64decode(action['content']) if action.get('encoding') == 'base64' else action['content'].encode()
        result.update(verified=True, outcome='verified', verification_scope='file_write',
                      path=os.path.normpath(os.path.expanduser(action['path'])), mode=action.get('mode', 'overwrite'),
                      bytes_written=len(data), file_size=len(data), content_sha256=hashlib.sha256(data).hexdigest(), file_sha256=hashlib.sha256(data).hexdigest())
    elif kind == 'read_file':
        content = fields.get('content', '')
        data = base64.b64decode(content) if fields.get('encoding') == 'base64' else content.encode()
        result.update(verified=True, outcome='verified', verification_scope='file_read',
                      path=os.path.normpath(os.path.expanduser(action['path'])), content=content,
                      encoding='utf-8', bytes_returned=len(data), content_sha256=hashlib.sha256(data).hexdigest(), truncated=False)
    elif kind == 'run_command':
        checks = fields.get('checks', [native_check(check) for check in action.get('checks', [])])
        checks = native_batch(action.get('checks', []), checks)['checks']
        fields = {**fields, 'checks': checks}
        executed = not fields.get('timed_out', False) and fields.get('exit_code', 0) == 0
        verified = executed and bool(checks) and all(c.get('verified') is True for c in checks)
        result.update(working_directory=action.get('working_directory', '/fixture'), exit_code=0, timed_out=False,
                      executed=executed, checks=checks, stdout=next((c['text'] for c in action.get('checks', []) if c['type']=='stdout_equals'), ''),
                      stderr='', stdout_truncated=False, stderr_truncated=False,
                      verified=verified, outcome='verified' if verified else 'delivered_unconfirmed',
                      verification_scope='requested_outcomes' if checks else 'execution_only')
    elif kind in {'set_value', 'type_text'}:
        result.update(verification_scope='text_value', text_verification='matched', pid=action.get('pid',42),
                      delivery_method='accessibility_value', verified=True, outcome='verified')
    elif kind in {'focus', 'launch_app'}:
        result.update(verified=True, outcome='verified', verification_scope='focus' if kind=='focus' else 'window_visible')
    if kind in {'read_file','write_file'}: result.update(filesystem_identity(result['path']))
    if result.get('verified') is True and kind in {'read_file', 'write_file'}:
        suffix = os.path.splitext(result['path'])[1].lower()
        format_name = {'.pdf': 'pdf', '.docx': 'docx', '.xlsx': 'xlsx'}.get(suffix)
        if format_name: result['file_format'] = format_proof(format_name)
    return {**result, **fields}


def native_failure(code='stale_target', *, outcome='rejected', message='Fixture failure'):
    return {'error': message, 'error_code': code, 'outcome': outcome, 'verified': False,
            'verification_scope': 'none', 'terminal': outcome != 'dispatched'}


def native_delivery(action, fields):
    """Fixture event delivery is never broad proof of an app's intended effect."""
    fields = dict(fields)
    if action['type'] not in {'read_file','write_file','run_command','set_value','type_text','focus','launch_app'}:
        for key in ('outcome','verified','verification_scope'): fields.pop(key, None)
    elif action['type'] in {'set_value','type_text'} and fields.get('outcome') == 'delivered_unconfirmed':
        fields.update(verified=False, text_verification=fields.get('text_verification','unavailable'))
    return native_result(action, **fields)


def format_proof(kind):
    from action_contract_generated import CONTRACT
    return {'format': kind, 'verified': True, 'validation_version': 1,
            'scope': 'document_structure', 'structure_count': 1,
            'facts': list(CONTRACT['artifact_formats'][kind]['facts'])}
