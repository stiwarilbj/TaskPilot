// A raw exec observer: unlike Python or a shell, it installs no signal handlers.
// Built only by offline tests, never bundled or launched against the desktop.
#include "ProcessSupport.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static const int teardown[] = { SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGCONT, SIGPIPE, SIGXFSZ };

static int inspect(void) {
    sigset_t mask;
    if (sigprocmask(SIG_SETMASK, NULL, &mask)) return 20;
    int empty = 1, defaults = 1;
    struct sigaction disposition;
    for (int number = 1; number < NSIG; ++number) if (sigismember(&mask, number) == 1) empty = 0;
    for (size_t i = 0; i < sizeof(teardown) / sizeof(teardown[0]); ++i) {
        if (sigaction(teardown[i], NULL, &disposition)) return 21;
        if (disposition.sa_handler != SIG_DFL) defaults = 0;
    }
    if (sigaction(SIGUSR1, NULL, &disposition)) return 22;
    int unrelated = disposition.sa_handler == SIG_IGN;
    printf("{\"mask_empty\":%s,\"defaults\":%s,\"unrelated_ignored\":%s,\"own_group\":%s,\"own_session\":%s}\n",
           empty ? "true" : "false", defaults ? "true" : "false", unrelated ? "true" : "false",
           getpgrp() == getpid() ? "true" : "false", getsid(0) == getpid() ? "true" : "false");
    fflush(stdout);
    return empty && defaults && getpgrp() == getpid() ? 0 : 23;
}

int main(int argc, char **argv) {
    if (argc != 2) return 24;
    if (!strcmp(argv[1], "--report")) return inspect();
    if (!strcmp(argv[1], "--term")) {
        puts("ready"); fflush(stdout);
        raise(SIGTERM); // Must terminate by TERM even if the embedding host ignored it.
        return 25;
    }
    if (strcmp(argv[1], "--native-host")) return 26;
    // Poison only this disposable host, never the XCTest/controller process.
    sigset_t blocked;
    sigemptyset(&blocked);
    for (size_t i = 0; i < sizeof(teardown) / sizeof(teardown[0]); ++i) {
        if (signal(teardown[i], SIG_IGN) == SIG_ERR) return 27;
        sigaddset(&blocked, teardown[i]);
    }
    signal(SIGUSR1, SIG_IGN); sigaddset(&blocked, SIGUSR1);
    if (sigprocmask(SIG_SETMASK, &blocked, NULL)) return 28;
    pid_t pid = 0;
    char *arguments[] = { argv[0], "--report", NULL };
    int error = tp_spawn(&pid, argv[0], arguments, environ, ".", 0, 1, 2);
    if (error) return 29;
    if (kill(pid, SIGCONT)) return 30;
    int status;
    while (waitpid(pid, &status, 0) < 0) if (errno != EINTR) return 31;
    // Native caller's mask and ignored dispositions were never rewritten.
    sigset_t after;
    if (sigprocmask(SIG_SETMASK, NULL, &after)) return 32;
    for (int number = 1; number < NSIG; ++number) {
        if (sigismember(&blocked, number) != sigismember(&after, number)) return 33;
    }
    for (size_t i = 0; i < sizeof(teardown) / sizeof(teardown[0]); ++i) {
        struct sigaction action;
        if (sigaction(teardown[i], NULL, &action) || action.sa_handler != SIG_IGN) return 34;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 35;
}
