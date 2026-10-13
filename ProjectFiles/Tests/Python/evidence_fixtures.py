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
