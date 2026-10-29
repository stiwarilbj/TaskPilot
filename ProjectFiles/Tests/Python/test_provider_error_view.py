import gc
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
import weakref

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import provider_errors as errors
import request_policy as policy


class ProviderErrorViewTests(unittest.TestCase):
    def nested_payload(self):
        return {'code': -32000, 'message': 'ACP failure', 'data': json.dumps({
            'message': 'Provider wrapper', 'error': json.dumps({
                'code': 'quota_exceeded', 'scope': 'credential',
                'message': 'Provider limit', 'retryAfter': 12})})}

    def test_message_and_classification_share_one_traversal_and_decode(self):
        decode = json.JSONDecoder.raw_decode
        with mock.patch.object(errors, 'error_nodes', wraps=errors.error_nodes) as walk, \
                mock.patch.object(json.JSONDecoder, 'raw_decode', autospec=True, side_effect=decode) as parse:
            error = errors.ProviderRequestError(self.nested_payload(), policy.PRIMARY_MODELS[0])
            self.assertEqual(str(error), 'Provider limit')
            failure = policy.classify_failure(error, 1000)
            self.assertEqual((failure.kind, failure.scope, failure.retry_at), ('quota', 'credential', 1012))
            self.assertEqual(walk.call_count, 1)
            self.assertEqual(parse.call_count, 2)  # One decode per embedded occurrence.

    def test_all_helpers_consume_the_same_view_without_decoding_again(self):
        view = errors.normalize_error(self.nested_payload())
        with mock.patch.object(errors, 'error_object', side_effect=AssertionError('decoded twice')):
            self.assertIs(errors.normalize_error(view), view)
            self.assertEqual(errors.message_text(view), 'Provider limit')
            first = errors.facts(view, 'google/first')
            second = errors.facts(view, 'other/second')
            self.assertEqual((first['provider'], first['model']), ('google', 'first'))
            self.assertEqual((second['provider'], second['model']), ('other', 'second'))
            self.assertEqual(errors.retry_time(view, errors.message_text(view), 1000), 1012)
            nodes = errors.error_nodes(view)
            nodes.clear()
            self.assertEqual(len(view.nodes), 3)
            first['codes'].clear()
            self.assertEqual(errors.facts(view)['codes'], ['quota_exceeded'])

    def test_legacy_exception_text_is_normalized_once(self):
        with mock.patch.object(errors, 'error_nodes', wraps=errors.error_nodes) as walk:
            failure = policy.classify_failure(RuntimeError(json.dumps(self.nested_payload())), 1000)
            self.assertEqual((failure.kind, failure.scope, failure.retry_at), ('quota', 'credential', 1012))
            walk.assert_called_once()

    def test_conflicting_fields_keep_existing_precedence_and_latest_cooldown(self):
        payload = {
            'code': -32000, 'status': 503, 'scope': 'model', 'providerRetries': 2,
            'retryAfter': 5, 'resetAt': 1100, 'message': 'ACP wrapper',
            'error': {'code': 'OVERLOADED', 'status': 429, 'scope': 'credential',
                      'message': 'Nested capacity', 'retryDelay': '12s'},
            'data': json.dumps({'error': {
                'code': 'quota_exceeded', 'status': 429, 'scope': 'project',
                'provider': 'google', 'model': 'inner', 'message': 'Retry in 120',
                'providerRetries': 0, 'retryAfterMs': 125000,
                'headers': {'Retry-After': 'Thu, 01 Jan 1970 00:20:00 GMT'}}}),
            'meta': {'code': 503, 'status': 'UNAVAILABLE', 'model': 'later',
                     'reason': 'quota_exhausted', 'message': 'Last message',
                     'errorMessage': 'ready in ~130', 'providerRetries': 0,
                     'retryBudgetExhausted': True, 'scope': 'model'},
        }
        failure = policy.classify_failure(errors.ProviderRequestError(payload), 1000)
        self.assertEqual((failure.kind, failure.scope), ('quota', 'credential'))
        self.assertEqual((failure.code, failure.http_status, failure.rpc_code), (503, 503, -32000))
        self.assertEqual(failure.codes, ('OVERLOADED', 'quota_exceeded', 503))
        self.assertEqual((failure.provider_status, failure.reason), ('UNAVAILABLE', 'quota_exhausted'))
        self.assertEqual((failure.provider, failure.model), ('google', 'later'))
        self.assertEqual(failure.detail, 'ready in ~130')
        self.assertEqual(failure.retry_at, 1200)
        self.assertEqual(failure.provider_retries, 2)
        self.assertTrue(failure.recovered_upstream)

    def test_nested_credential_error_cannot_be_hidden_by_later_model_error(self):
        payload = {'error': {'code': 'API_KEY_INVALID', 'scope': 'credential'},
                   'meta': {'code': 'OVERLOADED', 'status': 503, 'scope': 'model',
                            'message': 'Temporary capacity'}}
        failure = policy.classify_failure(errors.ProviderRequestError(payload), 1000)
        self.assertEqual((failure.kind, failure.scope), ('credentials', 'credential'))
        self.assertEqual(failure.code, 'OVERLOADED')

    def test_upstream_retry_hints_never_reopen_the_local_retry_budget(self):
        payload = {'code': 'quota_exceeded', 'scope': 'credential', 'retryAfter': 12,
                   'providerRetries': 2, 'recoveryExhausted': True,
                   'data': json.dumps({'scope': 'model', 'retryAfter': 1,
                                       'providerRetries': 0, 'recoveryExhausted': False})}
        def fail(_):
            raise errors.ProviderRequestError(payload)
        operation = mock.Mock(side_effect=fail)
        sleep = mock.Mock()
        router = policy.AdaptiveModelRouter(lambda *a, **k: None, clock=lambda: 1000, sleep=sleep)
        with self.assertRaises(policy.RecoveryExhaustedError) as caught:
            router.execute(operation)
        operation.assert_called_once_with(policy.PRIMARY_MODELS[0])
        sleep.assert_not_called()
        self.assertEqual((router.metrics['retries'], router.metrics['provider_retries']), (0, 2))
        self.assertEqual((caught.exception.failure.scope, caught.exception.failure.retry_at), ('credential', 1012))

    def test_upstream_attempts_each_normalize_once_and_preserve_wrapper_deadline(self):
        payload = {'message': 'All models failed', 'attempts': [
            {'model': 'first', 'error': json.dumps({'code': 'quota_exceeded', 'retryAfter': 30})},
            {'model': 'second', 'error': json.dumps({'code': 'quota_exceeded', 'retryAfter': 60})},
            {'status': 'success', 'error': {'code': 'API_KEY_INVALID'}},
        ]}
        with mock.patch.object(errors, 'error_nodes', wraps=errors.error_nodes) as walk:
            failure = policy.classify_failure(errors.ProviderRequestError(payload), 1000)
            self.assertEqual(walk.call_count, 3)  # Parent and two failed attempts.
        self.assertEqual(failure.kind, 'quota')
        self.assertEqual(failure.retry_at, 1030)  # Existing wrapper rule uses the earliest attempt deadline.
        self.assertEqual([a['retry_at'] for a in failure.attempts], [1030, 1060])
        self.assertTrue(failure.recovered_upstream)

    def test_view_is_released_and_reclassification_uses_a_fresh_clock(self):
        error = errors.ProviderRequestError(self.nested_payload())
        view = weakref.ref(error._error_view)
        failure = policy.classify_failure(error, 1000)
        gc.collect()
        self.assertIsNone(view())
        self.assertIsNone(error._error_view)
        self.assertEqual(failure.retry_at, 1012)
        with mock.patch.object(errors, 'error_nodes', wraps=errors.error_nodes) as walk:
            self.assertEqual(policy.classify_failure(error, 2000).retry_at, 2012)
            walk.assert_called_once()
        self.assertIsNone(error._error_view)

    def test_traversal_bounds_order_and_allowlist_are_preserved(self):
        chain = {'code': 9, 'scope': 'credential'}
        for depth in reversed(range(9)):
            chain = {'code': depth, 'error': chain}
        view = errors.normalize_error(chain)
        self.assertEqual([n['code'] for n in view.nodes], list(range(9)))
        self.assertEqual(errors.facts(view)['scope'], 'unknown')

        view = errors.normalize_error({'details': [{'code': i} for i in range(40)]})
        self.assertEqual([n['code'] for n in view.nodes[1:]], list(range(32)))
        payload = {'details': [{'code': i, 'error': {'code': f'nested{i}'}} for i in range(32)]}
        view = errors.normalize_error(payload)
        self.assertEqual(len(view.nodes), 64)
        self.assertEqual(view.nodes[-1]['code'], 31)
        self.assertEqual(errors.facts(view)['code'], 31)

        payload = {'code': 503, 'request': {'code': 'API_KEY_INVALID'},
                   'arbitrary': {'scope': 'credential'}}
        payload['error'] = payload
        self.assertEqual(len(errors.normalize_error(payload).nodes), 1)
        failure = policy.classify_failure(errors.ProviderRequestError(payload), 1000)
        self.assertEqual((failure.kind, failure.scope), ('temporary', 'unknown'))

    def test_equal_embedded_strings_are_distinct_occurrences_but_native_aliases_are_not(self):
        text = json.dumps({'code': 503, 'message': 'Capacity'})
        native = {'code': 429}
        payload = {'error': text, 'data': text, 'detail': native, 'cause': native}
        decode = json.JSONDecoder.raw_decode
        with mock.patch.object(json.JSONDecoder, 'raw_decode', autospec=True, side_effect=decode) as parse:
            view = errors.normalize_error(payload)
        self.assertEqual(parse.call_count, 2)
        self.assertEqual([n.get('code') for n in view.nodes], [None, 503, 503, 429])
        self.assertIsNot(view.nodes[1], view.nodes[2])

    def test_text_fallback_and_embedded_json_size_limit_are_unchanged(self):
        for payload, expected in [({}, 'fallback'), ('plain error', 'plain error'),
                                  ('prefix {"message":"embedded"} suffix', 'embedded')]:
            with self.subTest(payload=payload):
                self.assertEqual(errors.message_text(errors.normalize_error(payload), 'fallback'), expected)
        oversized = '{"code":"API_KEY_INVALID","message":"' + 'x' * 262144 + '"}'
        view = errors.normalize_error(oversized)
        self.assertEqual(view.nodes, ())
        self.assertEqual(errors.message_text(view), oversized[:262144])
        self.assertLessEqual(len(view.fallback_text), 262144)


if __name__ == '__main__':
    unittest.main()
