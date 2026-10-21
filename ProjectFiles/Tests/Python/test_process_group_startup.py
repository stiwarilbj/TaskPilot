import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime


class ProcessGroupStartupTests(unittest.TestCase):
    def test_native_owned_group_is_not_replaced(self):
        with mock.patch.object(runtime.os, 'getpid', return_value=101), \
                mock.patch.object(runtime.os, 'getpgrp', return_value=101), \
                mock.patch.object(runtime.os, 'setpgrp') as create, \
                mock.patch.object(runtime, 'parse_args', side_effect=RuntimeError('fixture stop')) as parse, \
                mock.patch.object(runtime.signal, 'signal'), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'fixture stop'):
                runtime.main()
            create.assert_not_called()
            parse.assert_called_once()

    def test_group_creation_failure_stops_before_configuration_or_requests(self):
        with mock.patch.object(runtime.os, 'getpid', return_value=101), \
                mock.patch.object(runtime.os, 'getpgrp', return_value=50), \
                mock.patch.object(runtime.os, 'setpgrp', side_effect=OSError(1, 'fixture denial')), \
                mock.patch.object(runtime, 'parse_args') as parse, \
                mock.patch.object(runtime, 'read_runtime_configuration') as configuration, \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(runtime.main(), 1)
            self.assertIn('process-group setup failed (1)', error.getvalue())
            parse.assert_not_called(); configuration.assert_not_called()

    def test_unacknowledged_group_is_also_rejected(self):
        with mock.patch.object(runtime.os, 'getpid', return_value=101), \
                mock.patch.object(runtime.os, 'getpgrp', return_value=50), \
                mock.patch.object(runtime.os, 'setpgrp') as create, \
                mock.patch.object(runtime, 'parse_args') as parse, \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(runtime.main(), 1)
            create.assert_called_once(); parse.assert_not_called()
            self.assertIn('process-group setup failed', error.getvalue())
