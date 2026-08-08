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
    └── DatabaseWire

DatabaseFDBExecutable
├── DatabaseCommandLine
└── DatabaseFDBCommandLine
    ├── FDBStorage
    ├── FoundationDB
    └── DatabaseEngine catalog readers
```

The executable split is a link-time boundary. `database` must not link
`libfdb_c`; only `database-fdb` may do so. `database fdb` locates the companion
in the same installation directory, sets the expected version, forwards the
original arguments and standard streams, and preserves the companion exit code.

## Remote execution flow

```text
argv or shell line
    -> one CommandParser AST
        -> ResolvedConnection
            -> HTTP or WebSocket transport selected by URL scheme
                -> DatabaseClient request identifier and wire frame
                    -> one of 13 canonical DatabaseWire operations
                        -> incremental result renderer
```

There is no direct `StorageEngine` connection in the main executable, no
automatic retry, and no protocol fallback. `trace-id`, `idempotency-key`, the
five execution budget fields, paging, graph partitions, and preconditions retain
their canonical wire meaning.

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
