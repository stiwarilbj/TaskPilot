#ifndef TASKPILOT_PROCESS_SUPPORT_H
#define TASKPILOT_PROCESS_SUPPORT_H
#include <stdint.h>
#include <sys/types.h>
typedef struct {
    pid_t pid, parent, group;
    uint64_t seconds, microseconds;
    int zombie;
} TPProcessIdentity;
// Acknowledges SETPGROUP and starts suspended; the owner installs observers
// before releasing the requested program with SIGCONT.
int tp_spawn(pid_t *pid, const char *path, char *const argv[], char *const env[],
             const char *directory, int input, int output, int error);
int tp_process_identity(pid_t pid, TPProcessIdentity *identity);
// A negative result is an inspection failure, not an empty process tree.
int tp_process_snapshot(TPProcessIdentity *identities, int capacity);
int tp_process_group_snapshot(pid_t group, TPProcessIdentity *identities, int capacity);
#endif
