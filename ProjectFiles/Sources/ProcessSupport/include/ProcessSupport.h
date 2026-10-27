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
// Read-only advisory snapshot. Returns 1 only for a complete bounded sample;
// unavailable/overflow inspection returns 0 and must not block launch.
// NSFileHandle raises an Objective-C exception after close; never let advisory
// accounting unwind through Swift locks. Does not retain or close the handle.
int tp_file_handle_descriptor(const void *handle);
int tp_descriptor_headroom(uint64_t *available, uint64_t *soft_limit);
int tp_process_identity(pid_t pid, TPProcessIdentity *identity);
// A negative result is an inspection failure, not an empty process tree.
int tp_process_snapshot(TPProcessIdentity *identities, int capacity);
int tp_process_group_snapshot(pid_t group, TPProcessIdentity *identities, int capacity);
#endif
