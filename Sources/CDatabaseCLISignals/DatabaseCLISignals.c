#include "DatabaseCLISignals.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>

static volatile sig_atomic_t database_cli_interrupt_descriptor = -1;
static int database_cli_interrupt_read_descriptor = -1;
static struct sigaction database_cli_previous_interrupt_action;

static void database_cli_handle_interrupt(int signal_number) {
    (void)signal_number;
    int descriptor = (int)database_cli_interrupt_descriptor;
    if (descriptor >= 0) {
        uint8_t byte = 1;
        ssize_t ignored = write(descriptor, &byte, sizeof(byte));
        (void)ignored;
    }
}

int32_t database_cli_begin_interrupt_monitoring(void) {
    if (database_cli_interrupt_descriptor >= 0
        || database_cli_interrupt_read_descriptor >= 0) {
        return -EBUSY;
    }

    int descriptors[2];
    if (pipe(descriptors) != 0) {
        return -errno;
    }
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != 0
        || fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) != 0
        || fcntl(descriptors[1], F_SETFL, O_NONBLOCK) != 0) {
        int error = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        return -error;
    }

    struct sigaction action;
    action.sa_handler = database_cli_handle_interrupt;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    if (sigaction(SIGINT, &action, &database_cli_previous_interrupt_action) != 0) {
        int error = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        return -error;
    }

    database_cli_interrupt_read_descriptor = descriptors[0];
    database_cli_interrupt_descriptor = descriptors[1];
    return descriptors[0];
}

int32_t database_cli_end_interrupt_monitoring(void) {
    int restore_result = sigaction(
        SIGINT,
        &database_cli_previous_interrupt_action,
        NULL
    );
    int restore_error = restore_result == 0 ? 0 : errno;

    int write_descriptor = (int)database_cli_interrupt_descriptor;
    database_cli_interrupt_descriptor = -1;
    database_cli_interrupt_read_descriptor = -1;
    int close_result = write_descriptor >= 0 ? close(write_descriptor) : 0;
    int close_error = close_result == 0 ? 0 : errno;

    if (restore_error != 0) {
        return -restore_error;
    }
    if (close_error != 0) {
        return -close_error;
    }
    return 0;
}
