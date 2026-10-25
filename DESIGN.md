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
  unknown tags, non-finite numeric values, and configured depth or byte limits are
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

Expected logical test counts are owned by
[scripts/xcode-test-harness](scripts/xcode-test-harness). [AGENTS.md](AGENTS.md)
owns verification requirements, and [Documentation/Testing.md](Documentation/Testing.md)
describes procedures. This table maps each invariant to the gate that falsifies it.

| Invariant | Required evidence |
|---|---|
| parsing, rendering, typed JSON, and credential handling hold | `scripts/xcode-test-harness` standard graph with the pinned snapshot, zero skips, expected failures, runtime warnings, or internal tool errors |
| the `MultiBase` command families and rendering hold | isolated `MultiBase` graph selected by `DATABASE_CLI_TEST_TRAITS`, built in an isolated source copy |
| adjacency, authentication, interrupt, and completion behave as programs | `scripts/process-test-harness` with adjacent version-matched `database`, `database-fdb`, and `database-server`, a disposable config home, profile, keychain credential, and SQLite file, proving authenticated reachability, SIGINT child shutdown, controlling-terminal Tab completion, and negative readiness before cleanup |
| terminal interaction works on a real controlling terminal | `scripts/pty-shell-test` |
| FoundationDB lifecycle and inspection are authoritative | `scripts/fdb-test-harness` with an isolated cluster file, protocol readiness, authoritative shutdown, and negative readiness after teardown |
| `database` links no FoundationDB | release build of both executable products with URL-only dependencies, inspecting the main binary's linkage |

The process harness owns its private executable copies, child processes and
service endpoint on both success and failure. Cleanup first interrupts the CLI
through its cancellation contract, then bounds the wait and terminates any
remaining server whose executable file is the same private copy. File identity
handles the native host's `/var` versus `/private/var` path normalization.
It proves process absence and negative protocol readiness before deleting
disposable state. Service stdout/stderr survive failed assertions in the result
directory; cleanup failure cannot become a successful harness result.
The private launch configuration grants only the fixture entity's list/get/create
operations to the bootstrap admin role; authentication alone grants no entity
access. Schema publication and two entity inserts prepare the paginated SQL
fixture through their existing public operations.

The 26.1022.1 distribution ships version-matched `database`, `database-fdb`
and `database-server` executables and pins Framework 26.1022.1 for the local
companion. DatabaseClient and DatabaseKit retain their 26.1021.0 contracts.
Patch updates preserve exact executable-version admission and the main CLI's
client-only linkage; framework execution stays behind the server/companion
boundary. Final process evidence covers SQL aggregate/window reads through
`query.execute`, the complete SQL endpoint, typed failures, rollback and
awaited service shutdown.

Native runs copy source into a harness-owned working directory and always run
`build-for-testing` before runtime injection and `test-without-building`.
Focused runs accept repeatable `--only-testing` selectors with an explicit
positive `--expected-count`; full runs retain package-owned counts.
`--preserve-work-root` and `--reuse-work-root` retain attributed DerivedData
while resynchronizing source. A changed normalized manifest, input pins, or
verification mode invalidates those products. Reuse does not bypass building.

`--diagnostic-source-root` consumes a separate prepared copy with absolute local
dependency overrides. Its results are diagnostic evidence, not final URL-graph
verification. Resolution may remove only explicitly overridden local identities
from the lock comparison; every remaining URL identity, location, version, and
revision must remain unchanged. The original and prepared manifests and locks
remain unchanged, verified by SHA-256, and the resolved graph and input digests
are retained beside the result bundles. Final verification uses the original
URL manifest and committed pins.

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

## Planned SQL Statement and Block Surface

S01 migrates the existing query rendering path before S17 adds statement/block
commands. It consumes [Kit typed query values](../database-kit/Sources/DatabaseKit/Query/DESIGN.md#s01-public-query-boundary)
and [Wire positional pages](../database-kit/Sources/DatabaseWire/DESIGN.md#s01-frozen-query-codec-contract).
ResultRenderer.swift must stop building JSON objects from column labels.
FieldValueJSONEncoder/Decoder remain primitive-only; a QueryValueJSONEncoder
and query-column/type presentation consume the semantic wrappers explicitly.
WireRequestBuilder.swift and query parameter/fixture construction preserve
QueryParameter's value and explicit declaration; transport/request code does
not parse or evaluate SQL.

| Output | S01 representation |
|---|---|
| JSON | Stream an array of page objects with ordered columns and rows. Each row has a positional values array plus its existing annotations/version/provenance metadata. A zero-row page still emits columns and an empty rows array. |
| JSONL | Emit a columns event before each page's row events, including zero-row pages. Each row event contains positional values and row metadata; continuation/snapshot/consistency metadata remains explicit. |
| Table / CSV | Retain duplicate headers and positional cells in declaration order. Typed rich-cell formatting uses bounded numeric display scale, original JSON lexical content, canonical JSONB, explicit array dimensions/lower bounds and separate interval components. These display formats do not claim lossless type round trip. |

The structured QueryValue JSON shape has a closed `$type` discriminator.
Primitive values use the existing primitive tagged JSON encoder. Rich numeric
emits coefficient as a decimal string, canonical scale and displayScale;
JSON emits original validated lexical text as a JSON string; JSONB emits the
canonical typed node tree with ordered member pairs and numeric metadata;
array emits elementType, ordered dimensions and positional elements; interval
emits months, days and microseconds without component normalization. Query
column declarations emit number/name/type/isNullable, using the strict native
[query descriptor JSON grammar](../database-kit/Sources/DatabaseSchemaJSON/DESIGN.md#s01-query-descriptor-json).
SQL NULL stays a primitive null cell whose type comes from its column. Numeric
formatting never passes through Double; JSONB output is not a persisted envelope.

The CLI owns the following exact rich-value grammar. Integer components are
canonical decimal strings. `sqlArray` is distinct from the existing primitive
`array` tag. JSONB nodes use `kind` with null/bool/string/number/array/object;
non-null nodes carry `value`, and object values are ordered `{key,value}` pairs.

| `$type` | Required additional members |
|---|---|
| numeric | coefficient, scale, displayScale |
| json | value (original lexical text) |
| jsonb | value (canonical typed node) |
| sqlArray | elementType (SQL descriptor), dimensions (`lowerBound`, `length`), elements |
| interval | months, days, microseconds |
| composite | type (the complete SQL composite QueryColumnType descriptor), fields (ordered tagged QueryValue cells) |

S08's composite object has exactly `$type`, `type` and `fields`. The descriptor
uses [Kit's strict result descriptor JSON](../database-kit/Sources/DatabaseSchemaJSON/DESIGN.md#s01-query-descriptor-json),
including ordinals, exact names, types and nullability. Kit's intrinsic
composite constructor validates that descriptor against the positional fields.
The existing primitive NULL tag represents whole-value NULL with the external
declared type; a present all-NULL composite retains its composite tag. Nested
arrays/composites preserve the same grammar. Table/CSV uses bounded tagged
JSON for composite display. Malformed descriptors, field arity/type/nullability,
unknown/duplicate/missing members and cumulative semantic/JSON byte/depth
limits fail through the existing CLI input/resource categories. Value-contained
type descriptors receive that value adapter's configured byte budget and a
checked JSON-depth ceiling of three times its semantic-depth limit, capped by
Wire's supported depth. Standalone column metadata keeps its default descriptor
policy. Descriptor physical construction retains Kit's finite checked ceiling;
no unbounded fallback is admitted. Result-only carriage grants no persisted
schema or model capability. QueryValueJSONTests
owns exact round trips, retained nested values, NULL distinctions and negative
boundaries; public parameter/result tests prove the actual consumer path.

`QueryValueJSONEncoder` and `QueryValueJSONDecoder` own this grammar and use
Kit's intrinsic constructors. `QueryColumnJSONCodec` consumes the native
QueryColumnTypeJSONCodec text boundary. Structured parameter entries permit
position/name/value/type; an absent or null type means no explicit declaration.
Unknown members/tags, noncanonical integer components, incompatible declared
types, and configured byte/depth limits fail before request execution.
Query-value depth limits count semantic value nodes on both encode and decode.
The native JSON scanner has a separate derived envelope limit of three times
the semantic limit: a JSONB object parent introduces its node object, member
array and member object before the child; a numeric leaf adds its component
object and component strings. Other productions introduce no greater depth.
This finite grammar bound admits an encoded value without weakening semantic
depth admission; decoding still checks the resulting value against the same
semantic limit. Multiplication overflow and nonpositive limits fail explicitly.
JSONB construction consumes Kit's checked composite factories and immutable
flat-owner collection views. The CLI retains its configured semantic depth
bound and never reconstructs recursively owned JSONB storage.
JSON page framing tracks prior pages separately from prior rows, so an empty
first page cannot remove the separator before a following page.

ResultRenderer.renderRows/rowJSON/tableValue/csvValue and streaming JSON page
framing migrate together. S01 preserves row quotas, checked output bytes,
stderr diagnostics, continuation identity and credential redaction. S01-C10
must execute the real authenticated query command and capture stdout/stderr
for first/continuation/zero-row pages with duplicate labels and rich cells;
renderer unit fixtures alone are insufficient. Existing process/xcode harness
owners and the backend-free main executable remain unchanged. The workspace
progress record owns the real process evidence for these implemented S01 paths.

The [S17 complete invocation contract](#s17-complete-sql-invocation) owns
statement/block invocation, SQL-file input and diagnostic presentation. The
existing query/mutation and retained-value contracts above remain its consumed
assumptions.

## S06 Temporal Boundary

This section defines the CLI-owned temporal adapter contract frozen by
[the S06 workspace decision](../.codex-tools/sql-s06-evidence/s06-contract-freeze.json).
The source and behavioral test batch implements this contract; runtime
verification remains pending. The user's inclusion of DATE, TIMESTAMP,
TIMESTAMPTZ and INTERVAL infinity is authoritative; the numeric nonfinite
restriction does not exclude these explicitly tagged temporal values.
The [SQL profile](../database-kit/Sources/DatabaseKit/Query/SQL/DESIGN.md) owns
semantic carriers and declared-type admission; [SQLTemporal](../database-framework/Sources/DatabaseEngine/QueryExecution/SQLTemporal/DESIGN.md)
owns lexical conversion, calendar behavior and SQL formatting. CLI rendering
does not evaluate those semantics or obtain a host timezone.

```text
typed parameter JSON -> QueryValueJSONDecoder -> Kit intrinsic constructors
    -> explicit QueryColumnType admission -> DatabaseClient

Wire QueryValue + column declaration -> QueryValueJSONEncoder -> JSON / JSONL
                                    -> QueryValueTextFormatter -> table / CSV

interval descriptor <-> QueryColumnJSONCodec <-> Kit QueryColumnTypeJSONCodec
```

The CLI retains every existing finite primitive tag, including `date`, `time`,
`dateTime` and `timestamp`, and the existing finite `interval` component shape.
It adds the following closed QueryValue productions. Listed members are all
required; additional or duplicate members fail. Integer components are
canonical decimal strings, not inferred JSON numbers.

| `$type` | Required additional members | Kit value |
|---|---|---|
| `sqlTime` | `microseconds` | `QueryValue.time`, `QueryTimeValue.microsecondsSinceMidnight` |
| `sqlTimeWithTimeZone` | `microseconds`, `utcOffsetSeconds` | `QueryValue.timeWithTimeZone`; local time plus seconds east of UTC |
| `dateInfinity` | `sign` | `QueryValue.dateInfinity` |
| `timestampInfinity` | `sign`, `withTimeZone` | `QueryValue.timestampInfinity`, retaining its Boolean zone flag |
| `intervalInfinity` | `sign` | `QueryValue.intervalInfinity` |

`microseconds` is in the inclusive range 0...86400000000. `utcOffsetSeconds`
preserves the entire Int32 range; a CLI adapter cannot impose a narrower SQL
lexical offset limit. `sign` is exactly `negative` or `positive`, corresponding
to `QueryTemporalInfinity`; `withTimeZone` is a JSON Boolean. Infinity is not
encoded as a numeric sentinel, primitive string or finite interval components.
The value's declared column or parameter type remains separate: Kit's
declared-type validator must reject an incompatible timestamp zone flag or
temporal family.
SQL arrays recursively use the same tagged values and preserve their element
declaration, dimensions and NULL cells.

Text rendering emits TIME as `HH:MM:SS.ffffff`, retaining the 24:00 endpoint.
TIMETZ appends an east-positive signed offset as `+HH:MM:SS` or `-HH:MM:SS`;
offset hours have at least two digits and expand for the full carrier range.
The offset magnitude is computed after widening to Int64 so Int32.min cannot
overflow. All six fractional digits are displayed without floating-point
conversion. Temporal negative and positive infinity display as `-infinity`
and `infinity`. Structured output carries the SQL family and zone meaning in
its column declarations; table/CSV retain their existing non-round-trip guarantee.
Finite primitive presentation and finite interval component presentation stay
unchanged. Byte limits and typed failure mapping apply to every new branch.

Interval modifiers are carried through the existing native
[query descriptor JSON grammar](../database-kit/Sources/DatabaseSchemaJSON/DESIGN.md#s01-query-descriptor-json).
`QueryColumnJSONCodec` continues delegating to Kit's `QueryColumnTypeJSONCodec`;
the CLI introduces no descriptor parser or modifier policy. Kit owns the
`interval` descriptor's `fields` and `precision` members, including allowed
field ranges, precision validation, and their canonical JSON representation.

| Implementation path | S06 owner and required evidence |
|---|---|
| `QueryValueJSONEncoder.valueNode`, `QueryValueJSONDecoder.decode` | CLI extends both closed dispatches and `QueryValueJSONTests`; exact tagged bytes round-trip every new case, both signs/zone flags, TIME endpoints, one-microsecond boundaries and full Int32 offsets. Existing primitive tags remain byte-for-byte identical. |
| `QueryValueTextFormatter.format` | CLI extends its exhaustive QueryValue switch; tests assert endpoint/fraction/offset/infinity text and byte-limit failures, without SQL lexical parsing or timezone conversion. |
| `WireRequestBuilder.parameters` | Existing decoded-value and declared-type validator path is preserved; tests reject family/zone mismatch and preserve typed NULL and interval-qualified empty SQL arrays. |
| `QueryColumnJSONCodec`, JSON/JSONL column rendering | Kit owns descriptor codec changes; CLI tests verify modifier identity through parameters, columns and empty pages, including fields/precision. |
| `ResultRenderer.rowJSON`, `tableValue`, `csvValue` | Existing delegation remains authoritative; `QueryRowRenderingTests` exercise positional temporal cells and duplicate labels in JSON/JSONL/table/CSV, checking exact cell values and output byte accounting. The CSV switch's existing default delegates new scalar cases to the formatter. |

Malformed input coverage includes missing/duplicate/unknown members, invalid
sign or Boolean, noncanonical and out-of-range integers, invalid TIME endpoints,
and configured byte/depth limits. Typed temporal values cannot fall through to
primitive-string conversion. Focused verification uses the package-owned
`scripts/xcode-test-harness` before the standard and MultiBase consolidated
lanes, with exact reviewed counts updated only alongside intentional tests.
No S06 runtime success is claimed by this design document.

## S17 Complete SQL Invocation

`database sql execute <statement|@path|@->` invokes
`DatabaseOperationCatalog.queryExecute` through the existing authenticated
session. There is no existing `sql` command family to supersede. The command
consumes one bounded UTF-8 SQL input, canonical typed parameters, one execution
budget and existing request metadata. It constructs
`QueryExecuteOperation.Request(input: .sql(...), parameters: ..., budget: ...)`.
Kit owns that declaration and the bounded codec; Framework owns parsing,
authority and single-request SQL execution.

```text
one inline / file / stdin read + one parameter decode
    -> immutable SQL request -> generic DatabaseSessionClient.execute
        -> one complete correlated post-closure response
            -> ordered statement events -> stdout
        -> canonical typed SQL diagnostic -> stderr and existing exit class
```

The command has no continuation, page size, `--all` or `--as-job` surface and
never splits SQL or automatically replays the request. Standard calls remain
target-free. The non-default `MultiBase` graph requires one `--base` and rejects
a Composition target, since a complete block may write. SQL settings,
transactions and prepared names end at request close. Shell command mode uses
the same catalog, parser and executor; no implicit statement-mode guessing or
cross-request SQL state is introduced.

The complete response renders as JSONL by default, with optional JSON output.
Statement indices preserve input order and distinguish multiple result sets.
Rows use existing ordered column descriptors and positional tagged QueryValue
cells, including zero-row metadata and duplicate labels. Command outcomes retain
SQL command kind and an optional canonical decimal affected-row count. COPY
outcomes retain affected rows and exact bytes using the existing tagged bytes
and unpadded base64url representation. The renderer emits one result at a time
from the response's retained owners. It neither interprets COPY content nor
opens host files named by SQL; SQL file notation only selects the request input.

Typed remote SQL diagnostics retain SQLSTATE, one-based source character
position and schema/table/column/constraint identifiers in stderr. They use
Kit's upcoming `RemoteOperationError` typed diagnostic accessor rather than
message matching or independently interpreting generic details. Existing
category-to-exit-code mapping remains authoritative. Failed blocks emit no
successful outcome events. Authentication, cancellation, resource limits and
malformed responses preserve their existing failure and shutdown paths.

Existing `query sql` and `mutate sql` commands and their pagination contracts
remain supported. `RemoteCommandExecutor.executeQuery` must read SQL and
structured parameter files/stdin once into the first owned request; successive
pages replace only the page limit and detached continuation. It must not
consume stdin into an unused preliminary request or reread mutable files while
paging. Existing page quotas, repeated-continuation rejection, positional row
rendering and retained owner release remain in force.

| Invariant | S17 falsifiable evidence owner |
|---|---|
| Command/catalog mapping and options are exact in both graphs | Parser, catalog and operation-mapping tests accept inline/file/stdin SQL and typed parameters; reject page/job/Composition options for complete SQL. |
| Complete ordered outcomes preserve identity | Renderer tests cover multiple/empty row sets, duplicate labels, typed NULL/rich values, command counts and COPY bytes with exact JSON/JSONL event order. |
| Failure diagnostics remain separate from results | Application tests assert all typed diagnostic members on stderr, stable exit codes and no outcome stdout on operation failure. |
| SQL and parameter input are read only once | Focused execution tests cover stdin and file input, then mutate/remove the source before a continuation and verify the original SQL/parameter identity. |
| Real public execution reaches a backend | Process harness sends SQL files and blocks through adjacent authenticated server transport, checks backend readback and late failure rollback, and verifies authoritative shutdown. |
| Main executable keeps its link boundary | Existing process/link checks prove that `database` does not link a storage backend or FoundationDB. |

`SQLExecutionTests` gives each executor invocation its own output handles through
`withSQLOutput`. The helper owns unique temporary output files, retains their
handles until the invocation finishes, and closes them before removing the
directory. Parallel tests do not share a global null-device output sink.

Client/runtime platform evidence retains its owning package; CLI does not
duplicate the Framework semantic corpus. Exact test counts change only in the
executable harness configuration alongside intentional behavioral coverage.


## Canonical Query Execution

SQL text, SQL blocks and semantic statements use the single query.execute
contract and canonical QueryResult. The complete SQL command preserves ordered
statement outcomes, affected counts and COPY bytes; explicit query pagination
retains its existing fixed invocation, metadata, bounds and detached continuation.
QueryLanguage and QueryInput belong to Kit rather than a transport descriptor.
No SQL-only operation, alias, fallback or automatic mutation replay remains.
Renderers preserve boolean/RDF/row/command/COPY/block distinctions and reject
invalid nested outcomes. Existing JSON/JSONL event order remains stable.

```text
command -> canonical QueryInput -> DatabaseClient -> query.execute
        -> typed QueryResult -> bounded output rendering
```

Existing output, parameter identity, diagnostic and process tests verify this
migration. The actual authenticated server process remains the integration gate.

## Coordinated Release Contract

The 26.1026.0 CLI and companion consume the published 26.1026.0 framework,
Kit, Client and Storage releases through URL dependency resolution. The
canonical executable version remains the source for companion and server
compatibility checks. Distribution acceptance requires matching database,
database-fdb and database-server candidates, real authenticated operations,
all-backend round trips, link separation, authoritative shutdown and negative
readiness. This update adds no authority, retry, resource-budget or
transaction policy.
