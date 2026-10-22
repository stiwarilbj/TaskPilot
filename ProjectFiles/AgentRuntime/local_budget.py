"""Monotonic local deadlines; never used for provider terminal-response waits."""
from contextlib import contextmanager
from contextvars import ContextVar
from functools import wraps
import time


class LocalBudgetExpired(RuntimeError):
    code = 'local_budget_exhausted'
    def __init__(self, phase):
        self.phase = phase
        super().__init__(f'The local operation budget was consumed during {phase}; delivered effects remain unconfirmed')


class LocalBudget:
    def __init__(self, seconds, phase, *, clock=None, cancelled=lambda: False):
        self.clock = clock or time.monotonic
        self.deadline = self.clock() + max(0, seconds)
        self.phase = phase
        self.cancelled = cancelled

    @property
    def remaining(self):
        return max(0.0, self.deadline - self.clock())

    def check(self, phase=None):
        if self.cancelled():
            raise RuntimeError('The local operation was cancelled; no further work may start')
        if self.remaining <= 0:
            raise LocalBudgetExpired(self.phase)
        if phase is not None:
            self.phase = phase
        return self.remaining

    def allowance(self, seconds):
        return min(max(0, seconds), self.remaining)


current_budget = ContextVar('local_operation_budget', default=None)


@contextmanager
def local_scope(seconds, phase, *, budget=None, clock=None, cancelled=lambda: False):
    parent = current_budget.get()
    selected = parent or budget or LocalBudget(seconds, phase, clock=clock, cancelled=cancelled)
    # A supplied task-owned budget is reused across execution/reconciliation.
    token = current_budget.set(selected)
    try:
        yield selected
    finally:
        current_budget.reset(token)


def local_operation(seconds, phase):
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            with local_scope(seconds(*args, **kwargs) if callable(seconds) else seconds, phase):
                return function(*args, **kwargs)
        return wrapped
    return decorate
