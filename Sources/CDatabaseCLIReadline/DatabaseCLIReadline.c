#include "DatabaseCLIReadline.h"

#include <ctype.h>
#include <errno.h>
#include <histedit.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct database_cli_completion_entry {
    char *context;
    char *value;
};

struct database_cli_readline_session {
    int input_descriptor;
    int output_descriptor;
    int interrupt_descriptor;
    char *prompt;
    struct database_cli_completion_entry *entries;
    size_t entry_count;
    size_t entry_capacity;
    char *line;
    int32_t status;
};

static pthread_mutex_t database_cli_readline_lock = PTHREAD_MUTEX_INITIALIZER;

static struct database_cli_readline_session *database_cli_session(
    EditLine *editor
) {
    void *data = NULL;
    if (el_get(editor, EL_CLIENTDATA, &data) != 0) {
        return NULL;
    }
    return data;
}

static char *database_cli_prompt(EditLine *editor) {
    struct database_cli_readline_session *session =
        database_cli_session(editor);
    return session == NULL ? "" : session->prompt;
}

static int database_cli_read_character(EditLine *editor, char *character) {
    struct database_cli_readline_session *session =
        database_cli_session(editor);
    if (session == NULL || character == NULL) {
        errno = EINVAL;
        return -1;
    }

    for (;;) {
        struct pollfd descriptors[2] = {
            {
                .fd = session->input_descriptor,
                .events = POLLIN | POLLHUP,
                .revents = 0,
            },
            {
                .fd = session->interrupt_descriptor,
                .events = POLLIN | POLLHUP,
                .revents = 0,
            },
        };
        int poll_status = poll(descriptors, 2, -1);
        if (poll_status < 0) {
            if (errno == EINTR) { continue; }
            return -1;
        }
        if ((descriptors[1].revents & (POLLIN | POLLHUP)) != 0) {
            char bytes[64];
            while (read(
                session->interrupt_descriptor,
                bytes,
                sizeof(bytes)
            ) > 0) {}
            session->status = DATABASE_CLI_READLINE_INTERRUPTED;
            return 0;
        }
        if ((descriptors[0].revents & (POLLERR | POLLNVAL)) != 0) {
            errno = EIO;
            return -1;
        }
        if ((descriptors[0].revents & (POLLIN | POLLHUP)) != 0) {
            ssize_t count = read(
                session->input_descriptor,
                character,
                1
            );
            if (count == 1) { return 1; }
            if (count == 0) { return 0; }
            if (errno == EINTR || errno == EAGAIN) { continue; }
            return -1;
        }
    }
}

static unsigned char database_cli_complete(EditLine *editor, int character) {
    (void)character;
    struct database_cli_readline_session *session =
        database_cli_session(editor);
    const LineInfo *line = el_line(editor);
    if (session == NULL || line == NULL || line->buffer == NULL
        || line->cursor == NULL || line->cursor < line->buffer) {
        return CC_ERROR;
    }

    const char *word_start = line->cursor;
    while (word_start > line->buffer
        && !isspace((unsigned char)word_start[-1])) {
        word_start -= 1;
    }
    size_t context_length = (size_t)(word_start - line->buffer);
    size_t prefix_length = (size_t)(line->cursor - word_start);
    const char *first_match = NULL;
    size_t common_length = 0;
    size_t match_count = 0;

    for (size_t index = 0; index < session->entry_count; index += 1) {
        struct database_cli_completion_entry *entry =
            &session->entries[index];
        if (strlen(entry->context) != context_length
            || memcmp(entry->context, line->buffer, context_length) != 0
            || strncmp(entry->value, word_start, prefix_length) != 0) {
            continue;
        }
        size_t value_length = strlen(entry->value);
        if (match_count == 0) {
            first_match = entry->value;
            common_length = value_length;
        } else {
            size_t candidate_length = value_length < common_length
                ? value_length
                : common_length;
            size_t offset = 0;
            while (offset < candidate_length
                && first_match[offset] == entry->value[offset]) {
                offset += 1;
            }
            common_length = offset;
        }
        match_count += 1;
    }

    if (match_count == 0 || first_match == NULL
        || common_length <= prefix_length) {
        el_beep(editor);
        return CC_NORM;
    }
    const char *suffix = first_match + prefix_length;
    size_t suffix_length = common_length - prefix_length;
    char *owned_suffix = malloc(suffix_length + 1);
    if (owned_suffix == NULL) { return CC_ERROR; }
    memcpy(owned_suffix, suffix, suffix_length);
    owned_suffix[suffix_length] = '\0';
    int insert_status = el_insertstr(editor, owned_suffix);
    free(owned_suffix);
    return insert_status == 0 ? CC_REFRESH : CC_ERROR;
}

database_cli_readline_session *database_cli_readline_session_create(
    int input_descriptor,
    int output_descriptor,
    int interrupt_descriptor,
    const char *prompt
) {
    if (input_descriptor < 0 || output_descriptor < 0
        || interrupt_descriptor < 0 || prompt == NULL) {
        errno = EINVAL;
        return NULL;
    }
    struct database_cli_readline_session *session = calloc(1, sizeof(*session));
    if (session == NULL) { return NULL; }
    session->prompt = strdup(prompt);
    if (session->prompt == NULL) {
        free(session);
        return NULL;
    }
    session->input_descriptor = input_descriptor;
    session->output_descriptor = output_descriptor;
    session->interrupt_descriptor = interrupt_descriptor;
    session->status = DATABASE_CLI_READLINE_ERROR;
    return session;
}

int32_t database_cli_readline_session_add_completion(
    database_cli_readline_session *session,
    const char *context,
    const char *value
) {
    if (session == NULL || context == NULL || value == NULL || value[0] == '\0') {
        return -EINVAL;
    }
    if (session->entry_count == session->entry_capacity) {
        size_t next_capacity = session->entry_capacity == 0
            ? 64
            : session->entry_capacity * 2;
        if (next_capacity < session->entry_capacity
            || next_capacity > SIZE_MAX / sizeof(*session->entries)) {
            return -EOVERFLOW;
        }
        void *next = realloc(
            session->entries,
            next_capacity * sizeof(*session->entries)
        );
        if (next == NULL) { return -ENOMEM; }
        session->entries = next;
        session->entry_capacity = next_capacity;
    }
    char *owned_context = strdup(context);
    char *owned_value = strdup(value);
    if (owned_context == NULL || owned_value == NULL) {
        free(owned_context);
        free(owned_value);
        return -ENOMEM;
    }
    session->entries[session->entry_count].context = owned_context;
    session->entries[session->entry_count].value = owned_value;
    session->entry_count += 1;
    return 0;
}

int32_t database_cli_readline_session_read(
    database_cli_readline_session *session,
    char **line
) {
    if (session == NULL || line == NULL) { return -EINVAL; }
    *line = NULL;
    int lock_status = pthread_mutex_lock(&database_cli_readline_lock);
    if (lock_status != 0) { return -lock_status; }

    int32_t result = DATABASE_CLI_READLINE_ERROR;
    FILE *input = fdopen(dup(session->input_descriptor), "r");
    FILE *output = fdopen(dup(session->output_descriptor), "w");
    if (input == NULL || output == NULL) {
        int saved_error = errno;
        if (input != NULL) { fclose(input); }
        if (output != NULL) { fclose(output); }
        pthread_mutex_unlock(&database_cli_readline_lock);
        return -saved_error;
    }
    setvbuf(output, NULL, _IONBF, 0);

    EditLine *editor = el_init("database", input, output, output);
    if (editor == NULL) {
        fclose(input);
        fclose(output);
        pthread_mutex_unlock(&database_cli_readline_lock);
        return -ENOMEM;
    }
    int configuration_status = 0;
    configuration_status |= el_set(editor, EL_CLIENTDATA, session);
    configuration_status |= el_set(editor, EL_PROMPT, database_cli_prompt);
    configuration_status |= el_set(editor, EL_GETCFN, database_cli_read_character);
    configuration_status |= el_set(editor, EL_SIGNAL, 0);
    configuration_status |= el_set(editor, EL_EDITOR, "emacs");
    configuration_status |= el_set(
        editor,
        EL_ADDFN,
        "database-complete",
        "complete database command",
        database_cli_complete
    );
    configuration_status |= el_set(
        editor,
        EL_BIND,
        "^I",
        "database-complete",
        NULL
    );

    session->status = DATABASE_CLI_READLINE_ERROR;
    if (configuration_status != 0) {
        result = -EINVAL;
    } else {
        int count = 0;
        errno = 0;
        const char *read_line = el_gets(editor, &count);
        if (session->status == DATABASE_CLI_READLINE_INTERRUPTED) {
            fputc('\n', output);
            result = DATABASE_CLI_READLINE_INTERRUPTED;
        } else if (read_line == NULL) {
            result = count < 0 ? -(errno == 0 ? EIO : errno)
                : DATABASE_CLI_READLINE_END_OF_FILE;
        } else if (count < 0) {
            result = -EIO;
        } else {
            size_t length = (size_t)count;
            while (length > 0
                && (read_line[length - 1] == '\n'
                    || read_line[length - 1] == '\r')) {
                length -= 1;
            }
            session->line = malloc(length + 1);
            if (session->line == NULL) {
                result = -ENOMEM;
            } else {
                memcpy(session->line, read_line, length);
                session->line[length] = '\0';
                *line = session->line;
                session->line = NULL;
                result = DATABASE_CLI_READLINE_LINE;
            }
        }
    }

    el_end(editor);
    fclose(input);
    fclose(output);
    pthread_mutex_unlock(&database_cli_readline_lock);
    return result;
}

void database_cli_readline_session_destroy(
    database_cli_readline_session *session
) {
    if (session == NULL) { return; }
    free(session->line);
    free(session->prompt);
    for (size_t index = 0; index < session->entry_count; index += 1) {
        free(session->entries[index].context);
        free(session->entries[index].value);
    }
    free(session->entries);
    free(session);
}

void database_cli_readline_free_line(char *line) {
    free(line);
}
