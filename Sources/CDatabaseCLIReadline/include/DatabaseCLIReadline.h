#ifndef DATABASE_CLI_READLINE_H
#define DATABASE_CLI_READLINE_H

#include <stdint.h>

typedef struct database_cli_readline_session database_cli_readline_session;

enum database_cli_readline_status {
    DATABASE_CLI_READLINE_ERROR = -1,
    DATABASE_CLI_READLINE_END_OF_FILE = 0,
    DATABASE_CLI_READLINE_LINE = 1,
    DATABASE_CLI_READLINE_INTERRUPTED = 2,
};

database_cli_readline_session *database_cli_readline_session_create(
    int input_descriptor,
    int output_descriptor,
    int interrupt_descriptor,
    const char *prompt
);

int32_t database_cli_readline_session_add_completion(
    database_cli_readline_session *session,
    const char *context,
    const char *value
);

int32_t database_cli_readline_session_read(
    database_cli_readline_session *session,
    char **line
);

void database_cli_readline_session_destroy(
    database_cli_readline_session *session
);

void database_cli_readline_free_line(char *line);

#endif
