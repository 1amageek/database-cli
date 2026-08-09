# Security

## Credential boundary

Access tokens never enter argv, profile JSON, shell history, result output, or
diagnostic text. The resolver order is:

1. the selected profile's platform keychain item;
2. the profile-selected environment variable;
3. `DATABASE_ACCESS_TOKEN`;
4. non-echo terminal input.

Non-interactive execution without any credential fails with authentication exit
code `3`. It never reads an echoed token from redirected standard input.

## Routing boundary

Database, tenant, and workspace are sent by both HTTP and WebSocket transports
using the same canonical routing headers. URL scheme is the only transport
selector. An unavailable selected transport or endpoint is a typed failure; no
fallback endpoint is attempted.

## Native server bootstrap

`database serve` creates or reads a server configuration through a private
child-process pipe. On first launch the server emits a new administrator token;
the CLI writes the profile and Keychain state before returning a one-byte
acceptance acknowledgement. Rejection removes the new registry entry.

The raw token is not placed in argv, environment variables, profiles, server
configuration, history, or diagnostic output. The server registry persists only
the token identifier, SHA-256 digest, principal, roles, and lifecycle times.
Digest comparison is constant-time.

Server configuration and registry directories require owner-only mode `0700`;
files require `0600`. Symbolic-link files and foreign ownership are rejected.
Non-loopback binding requires TLS, authentication, and complete routing before
the socket is created. There is no unauthenticated flag or default-database
fallback.

## Storage credentials and identity

The PostgreSQL password value is never accepted through argv, environment
variables, profiles, or server configuration. `--postgres-password-file`
passes only a path; the Server opens the target without following the final
symbolic link and requires an owner-owned mode-`0600` regular file. The
FoundationDB production backend requires an explicit cluster file and never
opens the system default cluster as a fallback.

## Files

Profile and persistent-history parent directories use mode `0700`; files use
mode `0600`. Persistent history is opt-in. Authentication commands are never
recorded. Atomic profile writes prevent partial configuration from replacing a
valid file.

## FoundationDB

The FoundationDB diagnostic companion accepts an explicit cluster file or discovers only
`.database/fdb.cluster` while walking parents. An explicit missing file never
falls back to the system default cluster. Raw diagnostics are read-only and
bounded by row and byte limits. The FoundationDB client opens the selected
cluster file before constructing `FDBStorageEngine`.

The helper reports readiness only after a real `fdbcli` protocol probe. Stop is
complete only after both the process and protocol endpoint are unreachable.
