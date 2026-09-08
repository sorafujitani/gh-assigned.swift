#include "include/AssignedTerminalC.h"

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static int signal_pipe[2] = {-1, -1};
static struct sigaction previous_int;
static struct sigaction previous_term;
static int installed = 0;

static void assigned_signal_handler(int signal_number) {
    unsigned char value = (unsigned char)signal_number;
    if (signal_pipe[1] >= 0) {
        (void)write(signal_pipe[1], &value, sizeof(value));
    }
}

static int assigned_signal_configure_fd(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return -1;
    flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0) return -1;
    return 0;
}

int assigned_signal_open(void) {
    if (signal_pipe[0] >= 0 && signal_pipe[1] >= 0) {
        return 0;
    }
    if (pipe(signal_pipe) != 0) {
        signal_pipe[0] = -1;
        signal_pipe[1] = -1;
        return -1;
    }
    if (assigned_signal_configure_fd(signal_pipe[0]) != 0
        || assigned_signal_configure_fd(signal_pipe[1]) != 0) {
        (void)close(signal_pipe[0]);
        (void)close(signal_pipe[1]);
        signal_pipe[0] = -1;
        signal_pipe[1] = -1;
        return -1;
    }
    return 0;
}

int assigned_signal_read_fd(void) {
    return signal_pipe[0];
}

int assigned_signal_wake(void) {
    if (signal_pipe[1] < 0) return -1;
    unsigned char value = 0;
    return write(signal_pipe[1], &value, sizeof(value)) == (ssize_t)sizeof(value) ? 0 : -1;
}

int assigned_signal_install(void) {
    if (assigned_signal_open() != 0) return -1;
    if (installed) return 0;

    struct sigaction action = {0};
    action.sa_handler = assigned_signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    if (sigaction(SIGINT, &action, &previous_int) != 0) {
        assigned_signal_close();
        return -1;
    }
    if (sigaction(SIGTERM, &action, &previous_term) != 0) {
        (void)sigaction(SIGINT, &previous_int, NULL);
        assigned_signal_close();
        return -1;
    }
    installed = 1;
    return 0;
}

void assigned_signal_restore(void) {
    if (!installed) return;
    (void)sigaction(SIGINT, &previous_int, NULL);
    (void)sigaction(SIGTERM, &previous_term, NULL);
    installed = 0;
}

void assigned_signal_close(void) {
    assigned_signal_restore();
    if (signal_pipe[0] >= 0) (void)close(signal_pipe[0]);
    if (signal_pipe[1] >= 0) (void)close(signal_pipe[1]);
    signal_pipe[0] = -1;
    signal_pipe[1] = -1;
}
