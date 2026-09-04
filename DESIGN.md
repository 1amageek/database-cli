# DatabaseCommandLine

## Purpose and Scope

This document is the package design authority for `database-cli`. The package
is the operator-facing invocation boundary of the workspace: it parses
commands, resolves profiles and credentials, issues canonical operations
through `DatabaseClient`, renders typed responses incrementally, runs an
interactive shell, and controls adjacent helper processes.

It is a consumer, never a semantic owner. It executes no database work, serves
no request, and constructs no storage engine in the `database` binary.

- Parent: [Database workspace](../DESIGN.md).
- Children: none. This package declares no module-level design authority.

The package carries existing sub-authorities that this document indexes rather
than restates:

| Document | Owns |
|---|---|
| [Documentation/Architecture.md](Documentation/Architecture.md) | internal architecture detail: the semantic-owner table, package and executable graphs, standard versus `MultiBase` graphs, the remote execution sequence, the adjacent server process adapter table, streaming and ownership, and the lifecycle/failure contract |
| [Documentation/Commands.md](Documentation/Commands.md) | the user-visible meaning of every command, with `CommandCatalog` as the executable source of truth |
| [Documentation/Security.md](Documentation/Security.md) | the credential boundary and resolver order |
| [Documentation/TypedJSON.md](Documentation/TypedJSON.md) | the lossless tagged JSON representation |
| [Documentation/Testing.md](Documentation/Testing.md) | harness procedure and reviewed test contracts |
| [AGENTS.md](AGENTS.md) | responsibility statement, security and data contracts, and expected verification counts |

This document owns what none of them owns: the package's product and target
composition, its cross-package design relationships, the invariants that hold
at the package boundary, and the mapping from each of those invariants to the
gate that falsifies it.

## Responsibilities and Boundaries

The package produces two executables and no library. Both are user-facing
programs, and the split between them is a link-time boundary.

| Product | Target chain | Owns |
|---|---|---|
| `database` | `DatabaseCLIExecutable` -> `DatabaseCommandLine` | command parsing, profiles, credentials, typed JSON, rendering, shell state, and adjacent-process control |
| `database-fdb` | `DatabaseFDBExecutable` -> `DatabaseFDBCommandLine` -> `DatabaseCommandLine` | local FoundationDB cluster lifecycle, control-domain database root Directory resolution, catalog inspection, and bounded read-only raw inspection |
| `CDatabaseCLIReadline` | C target linked into `DatabaseCommandLine` | the line-editing host binding used by the interactive shell |
| `CDatabaseCLISignals` | C target linked into `DatabaseCommandLine` | the signal-handling host binding used for interrupt and shutdown |

It owns:

- Every user-visible surface: argument grammar, help, completions, prompts,
  rendering, and exit behavior.
- Profile storage and credential resolution, including keeping access tokens
  out of arguments, files, history, and diagnostics.
- Adjacent process control for a version-matched `database-server` and for
  `database-fdb`, as client-side adapters only.
- Incremental output: one element at a time, one page released before the next
  is requested, results on standard output and diagnostics on standard error.

It does not own:

- Database execution, dispatch, hosting, authentication policy, or backend
  construction. Those belong to `database-framework`, `database-server`, and
  `storage-kit`.
- Operation meaning, wire framing, or schema semantics. Those belong to
  `database-kit`.
- Request correlation and transport behavior. Those belong to
  `database-client`.
- Any in-process substitute for an adjacent executable. A missing, mismatched,
  or failed helper process is a typed failure.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Database workspace](../DESIGN.md) | parent | system index and semantic plane assignment | Places this package as the operator plane. | It is downstream of every other package and upstream of none. |
| [database-client](../database-client/DESIGN.md) | depends on | `DatabaseClient`, `DatabaseSessionClient`, and the HTTP, WebSocket, and framed-stream transports | Supplies typed remote calls and correlation. | The URL scheme selects the transport; the CLI never retries or silently switches transport or endpoint. |
| [database-kit](../database-kit/DESIGN.md) | depends on | operations, schema JSON, and DatabaseWire declarations | Supplies the canonical vocabulary every command is expressed in. | A command must not invent an operation or reinterpret a wire field. |
| [database-types](../database-types/AGENTS.md) | depends on | primitive values and bounded byte ownership | Supplies the value identity that typed JSON must preserve losslessly. | Rendering must not change a value's identity through JSON inference. |
| [database-server](../database-server/DESIGN.md) | adjacent process, version matched; no package dependency | the `database-server` executable interface, its bootstrap exchange, and its stdio serve mode | Executes everything the remote and standalone commands request. | It is not a dependency or product of this package. Version mismatch is a typed failure, never a downgrade or a fallback. |
| [database-framework](../database-framework/DESIGN.md) | depends on, `database-fdb` only | `DatabaseEngine` catalog readers and the database root Directory layout | Supplies the catalog reading used by FoundationDB diagnostics. | This dependency must never reach the `database` executable. The Default Partition, `system`, and `database-framework` Directory names are `package`-visible in `DatabaseEngine`, so `FDBControlDomainLocator` duplicates them and the end-to-end catalog test fails if they drift. |
| [storage-kit](../storage-kit/DESIGN.md) | depends on, `database-fdb` only | `FDBStorage` and the storage clock | Supplies the FoundationDB storage adapter used for diagnostics. | Diagnostics are read-only; the companion provides no raw mutation command. |
| [fdb-swift-bindings](../fdb-swift-bindings/DESIGN.md) | depends on, `database-fdb` only | the FoundationDB client | Supplies cluster access for lifecycle and inspection. | An explicit cluster selection never falls back to the system default cluster. |

## Architecture

```text
argv or shell input
   -> CommandParser / CommandCatalog          (same parser in both modes)
   -> profile and credential resolution
   -> WireRequestBuilder -> DatabaseClient -> configured endpoint
   -> retained response owner -> incremental renderer -> stdout

database          -> DatabaseCommandLine  (no storage backend linked)
database-fdb      -> DatabaseFDBCommandLine -> FDBStorage / FoundationDB
database-server   -> adjacent process, launched and version checked
```

The detailed graphs, the remote execution sequence, the standard versus
`MultiBase` command graphs, and the adjacent server adapter responsibilities
are in [Documentation/Architecture.md](Documentation/Architecture.md).

Trait composition: the package declares one trait, `MultiBase`, disabled by
default, and forwards it to `database-kit` and `database-client`. It enables
`AllRuntimeFeatures` on `database-framework` unconditionally, because that
dependency exists only for the FoundationDB diagnostic companion and must be
able to read any catalog it encounters. That asymmetry is deliberate: feature
breadth here is a diagnostic requirement, not a serving capability.

## Contracts and Invariants

- The `database` executable links no storage backend and no FoundationDB
  client library. This is a link-time assertion, not a runtime convention.
- `database` and `database-fdb` and the adjacent `database-server` are version
  matched. A missing executable, version mismatch, invalid response, process
  failure, or shutdown failure is a typed failure, and no in-process
  implementation is substituted.
- Command mode and shell mode use the same parser and executor, so a command
  cannot behave differently depending on how it was entered.
- Access tokens never appear in process arguments, profile files, shell
  history, result output, or diagnostics.
- Structured values use lossless tagged JSON. Duplicate keys, untagged numbers,
  unknown tags, non-finite values, and configured depth or byte limits are
  rejected rather than coerced.
- Result pages are consumed through owner-retaining iterators: one element is
  rendered at a time and one page is released before the next is requested.
  Continuation bytes are detached before their response owner is released.
- Standard output carries results only; diagnostics go to standard error.
- The CLI never retries and never silently selects a different endpoint,
  transport, cluster, or database.
- Malformed, unsupported, cancelled, conflicting, unauthorized, unavailable, or
  resource-limited work is never converted into empty or synthetic success.
- With `MultiBase` disabled, the Base, Composition, persisted Grant, and target
  command families are not compiled in. The standard graph is not an implicit
  Base.

## State, Ownership, and Lifecycle

| State | Owner | Allowed transition |
|---|---|---|
| profile and completion files | `Profile`, `DatabaseCLIPaths`, `SecureLocalFile` | written through a secured local file path; never holds a token |
| credential | `CredentialStore` | resolved per invocation from keychain, profile-selected environment variable, `DATABASE_ACCESS_TOKEN`, or non-echo TTY input |
| remote session | `RemoteSession` over a `DatabaseClient` transport | one authoritative shutdown path shared by success, failure, cancellation, and EOF |
| adjacent server process | `DatabaseServerInstallation`, `DatabaseServerForegroundProcess`, `LocalDatabaseServerProcessConnection` | locate, version check, launch, interrupt, await, reap |
| FoundationDB cluster and engine | `LocalFDBCluster`, `FDBDatabaseConnection` in `database-fdb` | explicit selection, protocol readiness, authoritative stop |
| shell state | `DatabaseShell` | retains only a complete previous request and its detached continuation; never a server transaction |

Every transport, helper process, local server process, and FoundationDB engine
owner has exactly one authoritative shutdown path. Ctrl-C cancels the active
request or clears buffered input; Ctrl-D exits and awaits session shutdown.

## Failure, Concurrency, and Constraints

- Failures stay typed and separable: `CLIError` for the user-facing boundary
  and `FDBCLIError` for the companion, over the client's transport, wire, and
  remote failures. A remote failure is not rewritten as a usage error.
- Interruption is cooperative and explicit. `InterruptibleCommand` and the
  signal C target route SIGINT into cancellation rather than process death
  during an in-flight request.
- The framed-stream adapter performs one documented copy at the operating-system
  pipe boundary, because NIO owns the outbound buffer until the asynchronous
  write completes. Pointers and borrowed views do not escape their owner.
- The package targets macOS only, because the shell, keychain, terminal, and
  process control paths are host-specific.

## Verification and Change Impact

Expected counts and the harness procedure are owned by [AGENTS.md](AGENTS.md)
and [Documentation/Testing.md](Documentation/Testing.md). This table maps each
invariant to the gate that falsifies it.

| Invariant | Required evidence |
|---|---|
| parsing, rendering, typed JSON, and credential handling hold | `scripts/xcode-test-harness` standard graph with the pinned snapshot, zero skips, expected failures, runtime warnings, or internal tool errors |
| the `MultiBase` command families and rendering hold | isolated `MultiBase` graph selected by `DATABASE_CLI_TEST_TRAITS`, built in an isolated source copy |
| adjacency, authentication, interrupt, and completion behave as programs | `scripts/process-test-harness` with adjacent version-matched `database`, `database-fdb`, and `database-server`, a disposable config home, profile, keychain credential, and SQLite file, proving authenticated reachability, SIGINT child shutdown, controlling-terminal Tab completion, and negative readiness before cleanup |
| terminal interaction works on a real controlling terminal | `scripts/pty-shell-test` |
| FoundationDB lifecycle and inspection are authoritative | `scripts/fdb-test-harness` with an isolated cluster file, protocol readiness, authoritative shutdown, and negative readiness after teardown |
| `database` links no FoundationDB | release build of both executable products with URL-only dependencies, inspecting the main binary's linkage |

Change impact:

- A `database-kit` operation or wire change invalidates the request builders and
  renderers and requires re-running both native graphs.
- A `database-client` transport or error change invalidates the remote and
  standalone process paths, including the framed-stream adapter.
- A `database-server` executable interface change — arguments, bootstrap
  exchange, stdio serve mode, or version reporting — invalidates the process
  harness, which is the only gate that observes the real adjacency.
- Adding any storage or FoundationDB dependency to `DatabaseCommandLine` breaks
  the link-time boundary and is rejected regardless of test results.
