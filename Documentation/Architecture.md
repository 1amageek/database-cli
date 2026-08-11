# Architecture

## Ownership

`database-cli` owns presentation and invocation concerns: command parsing,
profiles, credential resolution, lossless typed JSON, streaming rendering,
shell state, and FoundationDB diagnostic composition. Database semantics remain
owned by `database-kit` and `database-framework`; transports remain owned by
`database-client`; storage semantics remain owned by `storage-kit`.

```text
DatabaseCLIExecutable
└── DatabaseCommandLine
    ├── DatabaseClient
    ├── DatabaseClientHTTP
    ├── DatabaseClientWebSocket
    ├── DatabaseClientFramedStream
    └── DatabaseWire

DatabaseServerExecutable
└── DatabaseServerHost
    ├── DatabaseApplication
    ├── DatabaseOperationRuntime
    ├── SQLiteStorage
    ├── PostgreSQLStorage
    └── FDBStorage

DatabaseFDBExecutable
├── DatabaseCommandLine
└── DatabaseFDBCommandLine
    ├── FDBStorage
    ├── FoundationDB
    └── DatabaseEngine catalog readers
```

The executable split is a link-time boundary. `database` links neither a
storage backend nor `libfdb_c`. `database-server` owns native hosting and
selects SQLite, PostgreSQL, or FoundationDB through injected `StorageEngine`
implementations. `database-fdb` separately owns FoundationDB cluster lifecycle
and bounded read-only diagnostics. Both companions must be in the same
installation directory and exactly match the CLI version.

## Remote execution flow

```text
argv or shell line
    -> one CommandParser AST
        -> ResolvedConnection
            -> HTTP or WebSocket transport selected by URL scheme
                -> DatabaseClient request identifier and wire frame
                    -> one of 14 canonical DatabaseWire operations
                        -> incremental result renderer
```

There is no direct `StorageEngine` connection in the main executable, no
automatic retry, and no protocol fallback. `trace-id`, `idempotency-key`, the
five execution budget fields, paging, graph partitions, and preconditions retain
their canonical wire meaning.

## Standalone execution flow

```text
database open <SQLite path>|--memory|--storage <backend> <backend options>
    -> adjacent version check
        -> database-server stdio
            -> private framed-stream transport
                -> empty or persisted schema generation
                    -> shared shell parser and executor

database serve [storage options] --profile <name>
    -> private bootstrap pipe
        -> profile and Keychain commit
            -> credential acknowledgement
                -> database-server serve
                    -> HTTP and WebSocket DatabaseWire endpoint
```

The CLI owns profile, Keychain, shell, and child-process UX. The server owns
listener, TLS, authentication, routing, signals, native backend construction,
runtime composition, and authoritative storage shutdown. The backend is
selected before runtime creation and never changes through silent fallback.
Database semantics do not move into either process adapter.

## Streaming and ownership

Query rows, RDF quads, graph results, ontology results, SHACL reports, and
maintenance pages are consumed from owner-retaining iterators. One element is
encoded at a time. `--all` completes and releases one response page before
requesting the next. JSON arrays are framed incrementally rather than assembled
as an in-memory result array.

Continuation bytes are detached before a response page is released. The shell
retains only the previous complete request and detached continuation. It never
retains a server transaction.

## Lifecycle

Every HTTP, WebSocket, helper process, and storage engine owner has one
authoritative shutdown path. Successful execution, typed failure, cancellation,
SIGINT, and shell exit all await that path. Ctrl-C cancels a one-shot command;
inside the shell it cancels the active request or clears the input buffer.
