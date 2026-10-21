#include "ProcessSupport.h"
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int tp_spawn(pid_t *pid, const char *path, char *const argv[], char *const env[],
             const char *directory, int input, int output, int error) {
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int result = posix_spawnattr_init(&attributes);
    if (result) return result;
    result = posix_spawn_file_actions_init(&actions);
    if (result) { posix_spawnattr_destroy(&attributes); return result; }
    sigset_t empty, defaults;
    sigemptyset(&empty); sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP);
    // Never repair failed group creation after launching an unowned child.
#define CHECK(call) do { result = (call); if (result) goto done; } while (0)
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    CHECK(posix_spawnattr_setsigmask(&attributes, &empty));
    CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP |
        POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT |
        POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    CHECK(posix_spawn_file_actions_addchdir_np(&actions, directory));
    CHECK(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO));
    result = posix_spawn(pid, path, &actions, &attributes, argv, env);
done:
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    return result;
#undef CHECK
}

int tp_process_identity(pid_t pid, TPProcessIdentity *identity) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    *identity = (TPProcessIdentity){ info.pbi_pid, info.pbi_ppid, info.pbi_pgid,
        info.pbi_start_tvsec, info.pbi_start_tvusec, info.pbi_status == 5 /* SZOMB */ };
    return 1;
}

int tp_process_snapshot(TPProcessIdentity *identities, int capacity) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return -(errno ? errno : EIO);
    // Include headroom for concurrent forks; reject overflow explicitly.
    int slots = count + 1024;
    pid_t *pids = calloc((size_t)slots, sizeof(pid_t));
    if (!pids) return -ENOMEM;
    count = proc_listallpids(pids, slots * (int)sizeof(pid_t));
    if (count <= 0 || count >= slots) { free(pids); return -EOVERFLOW; }
    int written = 0;
    for (int i = 0; i < count; ++i) {
        TPProcessIdentity identity;
        if (!tp_process_identity(pids[i], &identity)) continue; // Exited during enumeration.
        if (written >= capacity) { free(pids); return -EOVERFLOW; }
        identities[written++] = identity;
    }
    free(pids);
    return written;
}

int tp_process_group_snapshot(pid_t group, TPProcessIdentity *identities, int capacity) {
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return -ENOMEM;
    errno = 0;
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, pids, capacity * (int)sizeof(pid_t));
    if (bytes < 0 || (bytes == 0 && errno)) { int code = errno ? errno : EIO; free(pids); return -code; }
    if (bytes >= capacity * (int)sizeof(pid_t)) { free(pids); return -EOVERFLOW; }
    int written = 0;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); ++i) {
        if (pids[i] <= 0) continue;
        TPProcessIdentity identity;
        if (tp_process_identity(pids[i], &identity)) { identities[written++] = identity; continue; }
        // An inaccessible live member is not evidence of an empty group.
        if (kill(pids[i], 0) == 0 || errno != ESRCH) { free(pids); return -EACCES; }
    }
    free(pids);
    return written;
}
