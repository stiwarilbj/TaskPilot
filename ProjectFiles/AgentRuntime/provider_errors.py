"""Bounded decoding of provider error envelopes; no provider calls or raw-error persistence."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from email.utils import parsedate_to_datetime
import json
import math
import re
from typing import Any


def identifier(value: Any) -> str | None:
    return value if isinstance(value, str) and re.fullmatch(r"[\w./:-]{1,128}", value) else None


def number(value: Any) -> float | None:
    if isinstance(value, bool): return None
    try: result = float(value)
    except (TypeError, ValueError, OverflowError): return None
    return result if math.isfinite(result) and result >= 0 else None


def error_object(value: Any) -> dict[str, Any] | None:
    """Decode a complete error object, including JSON inside legacy error text."""
    if isinstance(value, dict): return value
    if not isinstance(value, str) or len(value) > 262144: return None
    start = value.find('{')
    if start < 0: return None
    try: result, _ = json.JSONDecoder().raw_decode(value[start:])
    except (ValueError, RecursionError): return None
    return result if isinstance(result, dict) else None


@dataclass(frozen=True)
class ErrorView:
    """One local traversal, preserving bounded node order and string fallback.

    Nodes reference the received envelope; callers must not mutate it during
    classification. Nothing is cached globally or persisted.
    """
    nodes: tuple[dict[str, Any], ...]
    fallback_text: str | None


def error_nodes(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, ErrorView): return list(payload.nodes)
    nodes: list[dict[str, Any]] = []
    seen: set[int] = set()
    def visit(value, depth=0):
        if depth > 8 or len(nodes) >= 64: return
        if isinstance(value, str): value = error_object(value)
        if isinstance(value, list):
            for item in value[:32]: visit(item, depth + 1)
        elif isinstance(value, dict) and id(value) not in seen:
            seen.add(id(value)); nodes.append(value)
            # Never traverse request bodies, arbitrary metadata, or an action.
            for key in ('error', 'message', 'data', 'detail', 'details', 'cause', 'providerError',
                        'errorDetails', 'errorMessage', 'rawError', 'authProfileFailure', 'meta', 'executionTrace'):
                if key in value: visit(value[key], depth + 1)
    visit(payload)
    return nodes


def normalize_error(payload: Any) -> ErrorView:
    if isinstance(payload, ErrorView): return payload
    return ErrorView(tuple(error_nodes(payload)), payload[:262144] if isinstance(payload, str) else None)


def facts(payload: Any, model: str | None = None) -> dict[str, Any]:
    nodes = normalize_error(payload).nodes
    result: dict[str, Any] = {}
    for node in nodes:
        code = node.get('code')
        if type(code) is int and code < 0:
            result.setdefault('rpc_code', code)
        elif type(code) is int or identifier(code):
            result['code'] = code
            if code not in result.setdefault('codes', []): result['codes'].append(code)
        for key in ('status', 'httpStatus', 'statusCode', 'http_status'):
            status = node.get(key)
            numeric = number(status)
            if numeric is not None and numeric.is_integer() and 100 <= numeric <= 599:
                result['http_status'] = int(numeric)
            elif key == 'status' and identifier(status): result['status'] = status
        numeric_code = number(code)
        if numeric_code is not None and numeric_code.is_integer() and 100 <= numeric_code <= 599:
            result['http_status'] = int(numeric_code)
        for key in ('reason', 'errorCode', 'error_code'):
            if identifier(node.get(key)):
                result['reason' if key == 'reason' else 'code'] = node[key]
                if key != 'reason' and node[key] not in result.setdefault('codes', []): result['codes'].append(node[key])
        for key in ('provider', 'model'):
            if identifier(node.get(key)): result[key] = node[key]
    if model: result.setdefault('model', model.split('/', 1)[-1])
    if model and '/' in model: result.setdefault('provider', model.split('/', 1)[0])
    explicit_scopes = {str(node.get(key, '')).casefold().replace('-', '_') for node in nodes
                       for key in ('scope', 'quotaScope', 'limitScope', 'rateLimitScope')}
    shared = bool(explicit_scopes & {'account', 'credential', 'project', 'provider', 'global', 'all_models', 'account_wide', 'credential_wide', 'project_wide'})
    scoped = bool(explicit_scopes & {'model', 'model_scoped', 'model_specific', 'per_model'})
    for node in nodes:
        for violation in node.get('violations', []) if isinstance(node.get('violations'), list) else []:
            if not isinstance(violation, dict): continue
            dimensions = violation.get('quotaDimensions', {})
            quota_id = str(violation.get('quotaId', ''))
            if re.search(r'per[_ -]?(?:day|week|month)', quota_id, re.I): result['periodic_quota'] = True
            if (isinstance(dimensions, dict) and dimensions.get('model')) or re.search(r'per[_ -]?model', quota_id, re.I):
                scoped = True
            elif re.search(r'per[_ -]?(?:project|account|credential)', quota_id, re.I): shared = True
    result['scope'] = 'credential' if shared else 'model' if scoped else 'unknown'
    attempts = next((n['attempts'] for n in nodes if isinstance(n.get('attempts'), list)), [])
    result['attempts'] = [a for a in attempts[:32] if isinstance(a, dict) and a.get('success') is not True and
                          str(a.get('status', '')).lower() not in {'success', 'succeeded', 'completed', 'ok'}]
    result['recovered_upstream'] = bool(result['attempts']) or any(
        n.get(key) is True for n in nodes for key in ('recoveryExhausted', 'recovered_upstream', 'retryBudgetExhausted'))
    retries = next((n[key] for n in nodes for key in ('providerRetries', 'providerRetryCount')
                    if type(n.get(key)) is int and 0 <= n[key] <= 10000), None)
    result['provider_retries'] = retries
    return result


def retry_time(payload: Any, message: str, now: float) -> float | None:
    deadlines = []
    def delay(value, milliseconds=False):
        if isinstance(value, dict):
            seconds, nanos = number(value.get('seconds', 0)), number(value.get('nanos', 0))
            value = None if seconds is None or nanos is None else seconds + nanos / 1e9
        if isinstance(value, str) and value.endswith('s'): value = value[:-1]
        seconds = number(value)
        if seconds is not None: deadlines.append(now + seconds / (1000 if milliseconds else 1))
        elif isinstance(value, str):
            try: deadlines.append(max(now, parsedate_to_datetime(value).timestamp()))
            except (ValueError, TypeError, OverflowError): pass
    def reset(value, milliseconds=False):
        stamp = number(value)
        if stamp is not None:
            deadlines.append(stamp / 1000 if milliseconds or stamp >= 1e11 else stamp)
        elif isinstance(value, str):
            try: deadlines.append(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp())
            except (ValueError, TypeError, OverflowError): pass
    for node in normalize_error(payload).nodes:
        for key in ('retryAfter', 'retry_after', 'retryAfterSeconds', 'retryDelay'):
            if key in node: delay(node[key])
        for key in ('retryAfterMs', 'retry_after_ms'):
            if key in node: delay(node[key], True)
        for key in ('resetAt', 'reset_at', 'retry_at', 'cooldownUntil'):
            if key in node: reset(node[key])
        for key in ('resetAtMs', 'soonestCooldownExpiry'):
            if key in node: reset(node[key], True)
        headers = node.get('headers', {})
        if isinstance(headers, dict):
            for key, value in headers.items():
                if not isinstance(key, str): continue
                if key.lower() == 'retry-after': delay(value)
                elif key.lower() == 'retry-after-ms': delay(value, True)
    for match in re.finditer(r'(?:retry[- _]?after["\']?\s*[:=]?\s*["\']?|retrydelay["\']?\s*[:=]?\s*["\']?|retry in\s+|ready in\s*~?)(\d+(?:\.\d+)?)', message, re.I):
        delay(match.group(1))
    for match in re.finditer(r'retry-after\s*:\s*([^\n]+)', message, re.I): delay(match.group(1).strip())
    for match in re.finditer(r'reset(?:s)?(?:[ _]?at)?["\']?\s*[:=]?\s*["\']?(\d{10}(?:\.\d+)?|\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:?\d{2}))', message, re.I): reset(match.group(1))
    deadlines = [d for d in deadlines if math.isfinite(d)]
    return max(now, *deadlines) if deadlines else None


def message_text(payload: Any, default: str = 'OpenClaw provider request failed') -> str:
    view = normalize_error(payload)
    messages = [n[key] for n in view.nodes for key in ('message', 'errorMessage', 'rawError')
                if isinstance(n.get(key), str)]
    text = messages[-1] if messages else view.fallback_text if view.fallback_text is not None else default
    return str(text)[:262144]


class ProviderRequestError(RuntimeError):
    """Keep the envelope in memory until it has been classified, never stringify its data."""
    def __init__(self, payload: Any, model: str | None = None, default: str = 'OpenClaw provider request failed') -> None:
        self.payload, self.model = payload, model
        self._error_view = normalize_error(payload)
        super().__init__(message_text(self._error_view, default))

    def take_error_view(self) -> ErrorView:
        """Hand classification the constructor's traversal, then release it.

        Reclassification deliberately builds a fresh view rather than keeping
        raw parsed errors alive as a cache on an already classified exception.
        """
        view, self._error_view = self._error_view, None
        return view if view is not None else normalize_error(self.payload)


def response_error(response: str | dict[str, Any]) -> dict[str, Any] | None:
    """Recognize provider envelopes, never decision fields merely mentioning errors."""
    try: value = json.loads(response) if isinstance(response, str) else response
    except (ValueError, RecursionError): return None
    if not isinstance(value, dict) or any(k in value for k in ('action', 'verified', 'check')): return None
    if isinstance(value.get('status'), str) and value['status'] in {'act', 'done', 'blocked', 'needs_user', 'needs_choice'}: return None
    if isinstance(value.get('error'), (dict, str)): return value
    if value.get('name') == 'FailoverError' or value.get('type') == 'error': return value
    return None
