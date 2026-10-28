"""macOS spawn-time signal normalization for bounded configuration helpers.

Popen cannot set a signal mask/default set with cwd and inherited leases on
Python 3.11. Use Darwin's checked spawn attributes instead of preexec_fn or
temporarily changing the multithreaded controller's signal dispositions.
"""
import ctypes
import errno
import fcntl
from functools import lru_cache
import os
import signal
import subprocess
import sys
import threading
import time


DEFAULT_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM,
                   signal.SIGCONT, signal.SIGPIPE, signal.SIGXFSZ)
# Darwin <sys/spawn.h>; supported on TaskPilot's macOS 14+ target.
_SETSIGDEF, _SETSIGMASK, _SETSID, _CLOEXEC_DEFAULT = 0x0004, 0x0008, 0x0400, 0x4000


@lru_cache(maxsize=1)
def _api():
    if sys.platform != 'darwin': raise OSError(errno.ENOTSUP, 'Managed helpers require macOS spawn support')
    library = ctypes.CDLL(None, use_errno=True)
    pointer = ctypes.POINTER(ctypes.c_void_p)
    strings = ctypes.POINTER(ctypes.c_char_p)
    signatures = {
        'posix_spawnattr_init': [pointer], 'posix_spawnattr_destroy': [pointer],
        'posix_spawnattr_setflags': [pointer, ctypes.c_short],
        'posix_spawnattr_setsigmask': [pointer, ctypes.POINTER(ctypes.c_uint32)],
        'posix_spawnattr_setsigdefault': [pointer, ctypes.POINTER(ctypes.c_uint32)],
        'posix_spawn_file_actions_init': [pointer], 'posix_spawn_file_actions_destroy': [pointer],
        'posix_spawn_file_actions_adddup2': [pointer, ctypes.c_int, ctypes.c_int],
        'posix_spawn_file_actions_addclose': [pointer, ctypes.c_int],
        'posix_spawn_file_actions_addinherit_np': [pointer, ctypes.c_int],
        'posix_spawn_file_actions_addchdir_np': [pointer, ctypes.c_char_p],
        'posix_spawn': [ctypes.POINTER(ctypes.c_int), ctypes.c_char_p, pointer, pointer, strings, strings],
    }
    for name, arguments in signatures.items():
        function = getattr(library, name)
        function.argtypes, function.restype = arguments, ctypes.c_int
    return library


def _check(code):
    if code: raise OSError(code, os.strerror(code))


def _bytes(value):
    value = os.fsencode(value)
    if b'\0' in value: raise ValueError('embedded null byte')
    return value


class SpawnedProcess:
    """Only the pid/wait contract bounded_run needs; no pipe or tree ownership."""
    def __init__(self, pid, argv):
        self.pid, self.args, self.returncode = pid, argv, None
        self._wait_lock = threading.Lock()

    def wait(self, timeout=None):
        deadline = None if timeout is None else time.monotonic() + timeout
        delay = 0.0005
        with self._wait_lock:
            while self.returncode is None:
                try: pid, status = os.waitpid(self.pid, 0 if deadline is None else os.WNOHANG)
                except InterruptedError: continue
                except ChildProcessError:
                    # Match Popen when an external reaper already consumed it.
                    self.returncode = 0
                    break
                if pid:
                    self.returncode = os.waitstatus_to_exitcode(status)
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise subprocess.TimeoutExpired(self.args, timeout)
                # Same bounded exponential wait used by Popen.wait(timeout).
                delay = min(delay * 2, remaining, 0.05)
                time.sleep(delay)
        return self.returncode


def spawn(argv, *, stdin, stdout, stderr, env=None, cwd=None, pass_fds=()):
    """Create the same new session as Popen(start_new_session=True).

    Only standard streams and explicit provisioning leases survive exec. No
    parent mask, handlers, cwd, environment, or descriptor flags are modified.
    """
    argv = list(argv)
    if not argv: raise ValueError('empty helper argument list')
    args = [_bytes(item) for item in argv]
    environment = dict(os.environ if env is None else env)
    entries = []
    for name, value in environment.items():
        key = _bytes(name)
        if b'=' in key: raise ValueError('illegal environment variable name')
        entries.append(key + b'=' + _bytes(value))
    c_args = (ctypes.c_char_p * (len(args) + 1))(*args)
    c_env = (ctypes.c_char_p * (len(entries) + 1))(*entries)
    executable = args[0]
    paths = ([executable] if os.path.dirname(executable) else
             [os.path.join(_bytes(directory), executable) for directory in os.get_exec_path(environment)])
    library, attributes, actions = _api(), ctypes.c_void_p(), ctypes.c_void_p()
    _check(library.posix_spawnattr_init(ctypes.byref(attributes)))
    actions_ready, copies = False, []
    try:
        _check(library.posix_spawn_file_actions_init(ctypes.byref(actions))); actions_ready = True
        # Darwin sigset_t is uint32_t; SIGKILL/SIGSTOP are never resettable.
        mask = ctypes.c_uint32(0)
        defaults = ctypes.c_uint32(sum(1 << (value - 1) for value in DEFAULT_SIGNALS))
        _check(library.posix_spawnattr_setsigmask(ctypes.byref(attributes), ctypes.byref(mask)))
        _check(library.posix_spawnattr_setsigdefault(ctypes.byref(attributes), ctypes.byref(defaults)))
        _check(library.posix_spawnattr_setflags(ctypes.byref(attributes), _SETSID | _SETSIGMASK | _SETSIGDEF | _CLOEXEC_DEFAULT))
        if cwd is not None: _check(library.posix_spawn_file_actions_addchdir_np(ctypes.byref(actions), _bytes(cwd)))
        keep = set(pass_fds)
        for descriptor in keep:
            if not isinstance(descriptor, int) or descriptor < 0: raise ValueError('invalid inherited descriptor')
            os.fstat(descriptor)
        sources = []
        for source in (stdin, stdout, stderr):
            # Stable source copies also handle a controller with closed 0/1/2.
            if source <= 2:
                source = fcntl.fcntl(source, fcntl.F_DUPFD_CLOEXEC, 3); copies.append(source)
            sources.append(source)
        for target, source in enumerate(sources):
            _check(library.posix_spawn_file_actions_adddup2(ctypes.byref(actions), source, target))
        for descriptor in keep:
            if descriptor > 2: _check(library.posix_spawn_file_actions_addinherit_np(ctypes.byref(actions), descriptor))
        for source in set(sources) - keep:
            _check(library.posix_spawn_file_actions_addclose(ctypes.byref(actions), source))
        failure = None
        for path in paths:
            pid = ctypes.c_int()
            code = library.posix_spawn(ctypes.byref(pid), path, ctypes.byref(actions), ctypes.byref(attributes), c_args, c_env)
            if not code: return SpawnedProcess(pid.value, argv)
            if failure is None and code not in (errno.ENOENT, errno.ENOTDIR): failure = code
        code = failure or errno.ENOENT
        raise OSError(code, os.strerror(code), argv[0])
    finally:
        for descriptor in copies: os.close(descriptor)
        if actions_ready: library.posix_spawn_file_actions_destroy(ctypes.byref(actions))
        library.posix_spawnattr_destroy(ctypes.byref(attributes))
