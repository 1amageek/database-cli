# Command reference

This document defines the user-visible meaning of every `database` command.
The generated `database help <command>` output is the authority for exact
option spelling, required values, defaults, conflicts, and cardinality. This
reference explains what an invocation does, what it returns, and whether it
changes persistent state.

## Execution model

```text
local configuration commands
    -> profile / credential / completion files

remote database commands
    -> DatabaseClient -> DatabaseWire operation -> configured server endpoint

standalone commands
    -> adjacent version-matched database-server process

FoundationDB diagnostics
    -> adjacent version-matched database-fdb process
```

The CLI does not infer read versus write intent, retry a failed request, select
another endpoint, or fall back to another storage backend. A command either
executes its documented path or returns a typed failure.

## Input notation

| Notation | Meaning |
|---|---|
| `<value>` | One positional value |
| `[value]` | Optional positional value |
| `@path` | Read bounded input from a file |
| `@-` | Read bounded input from standard input |
| `typed-json` | Lossless tagged JSON from [TypedJSON.md](TypedJSON.md) |
| `typed-graph-term` | A tagged `string` or tagged `rdfTerm` |
| `base64url` | Unpadded base64url emitted by the CLI |

Statements and structured documents are passed to the canonical DatabaseKit
operation model. The CLI does not define a separate SQL, SPARQL, Schema,
ontology, or SHACL language.

## Option ownership

Options are attached only to commands that consume them. Supplying an option to
another command is an input error.

| Group | Consumer and meaning |
|---|---|
| `--profile`, `--endpoint`, `--database`, `--tenant`, `--workspace` | Resolve one authenticated remote session and routing identity |
| `--trace-id`, `--idempotency-key` | Populate `OperationRequestMetadata` |
| `--maximum-*`, `--timeout-milliseconds` | Populate one `ExecutionBudget` on operations that own a budget |
| `--parameter`, `--parameters` | Bind SQL or SPARQL statement parameters |
| `--page-size` | Set the page limit inside a paged Wire request; it does not modify the statement |
| `--continuation` | Resume a command whose request accepts the detached continuation |
| `--all` and aggregate limits | Reissue successive paged requests client-side; not valid with `--as-job` |
| `--as-job <kind>` | Start the same typed operation through `jobStart` after capability validation |
| `--base <id>` | `MultipleBases` only: select a Base-local operation, Grant, or job target |
| `--composition <id>` | `MultipleBases` only: bind a read-only query to a named Composition; conflicts with `--base` |
| `--database-target` | `MultipleBases` only: explicitly select the database/control target for Grant/job commands; conflicts with `--base` |

`--max-total-rows`, `--max-total-bytes`, and `--max-pages` require `--all`.
`--all` requires all three limits and conflicts with `--continuation` and
`--as-job`. A page is rendered and released before the next page is requested.

The standard build emits target-free DatabaseWire v2 requests against one
database root. `DatabaseOperationTarget`, Base, Composition, persisted Grant,
and the three options above are absent from that command graph.

The non-default `MultipleBases` trait switches the full dependency graph to
DatabaseWire v3. Only then does every remote invocation carry one explicit
`DatabaseOperationTarget`. Data operations require `--base`; read-only queries
require either `--base` or `--composition`; catalog and control commands select
the database/control target from their command semantics. There is no implicit
or default Base.

## General commands

| Command | Purpose, output, and effects |
|---|---|
| `database help [command]` | Prints root, family, or exact command help generated from `CommandCatalog`. Read-only and local. |
| `database version` | Prints the CLI semantic version. Read-only and local. `database --version` is equivalent. |
| `database completion bash` | Generates Bash completion from the immutable command catalog. No network access. |
| `database completion zsh` | Generates Zsh completion from the immutable command catalog. No network access. |
| `database completion fish` | Generates Fish completion from the immutable command catalog. No network access. |

## Profiles and authentication

Profiles contain endpoint and routing metadata, never a raw bearer token.
Tokens are stored in the platform credential store.

| Command | Input and behavior | Output / effects |
|---|---|---|
| `database profile create <name>` | Requires `--endpoint`; records database, tenant, workspace, and optional token-environment metadata. | Writes an owner-only profile file; conflicts if the name exists. |
| `database profile list` | Reads all configured profiles. | JSON profile summaries; no database request. |
| `database profile show <name>` | Reads one named profile. | JSON profile metadata or not-found. |
| `database profile use <name>` | Selects the active profile. | Updates the owner-only profile file. |
| `database profile remove <name>` | Removes the profile. | Removes profile metadata and its stored credential. |
| `database auth login` | Selects `--profile` or the active profile; reads the token from the selected environment source or a non-echo TTY prompt. | Stores a credential; the token is never printed or accepted in argv. |
| `database auth logout` | Selects `--profile` or the active profile. | Removes that profile's stored credential. |

## Standalone lifecycle

### `database open [path]`

Starts the adjacent, version-matched `database-server` over a private framed
stdio transport and then enters the interactive shell. The CLI owns the child
and waits for authoritative shutdown on shell exit, EOF, cancellation, or pipe
failure.

| Storage | Required selection | Persistent effect |
|---|---|---|
| SQLite file | one `[path]` | Creates or opens that file |
| SQLite memory | `--memory` | Process-local only |
| PostgreSQL | `--storage postgresql`, exactly one host/socket, user, and database | Uses the configured table and schema-management policy |
| FoundationDB | `--storage foundationdb --fdb-cluster-file <path> --fdb-directory <component> [...]` | Uses only the explicit cluster and ordered Directory path |

`--schema` plans and applies a strict manifest before the shell opens.
`--mode` selects the initial shell mode. Failure to start or negotiate with the
child is a transport/protocol failure; there is no in-process fallback.

### `database serve [path]`

Runs the adjacent native server in the foreground. `--profile` is required.
For a new configuration the command resolves the same storage choices as
`open`, bootstraps one administrator credential, saves profile and credential
state atomically from the user's perspective, and then starts the listener.
For an existing configuration, that file is authoritative.

`--config` selects an explicit server configuration and cannot be combined
with storage selection. `--listen` overrides the configured listener. A
non-loopback listener is rejected by the server unless TLS, authentication,
and complete routing identity are configured.

### `database shell`

Starts the explicit interactive client. It accepts an initial `--profile`,
`--output`, `--page-size`, and mode. Command mode uses the same catalog, parser,
validator, and executor as one-shot invocations. Statement modes buffer SQL or
SPARQL until `\g`; a semicolon never triggers execution.

```text
\help                         show shell meta commands
\profile <name>               switch a remote profile
\database                     MultipleBases only: select database/control
\base <id>                    MultipleBases only: select one Base
\composition <id>             MultipleBases only: select read-only Composition
\output <format>              set a default for commands supporting output
\timing on|off                show client elapsed time
\budget                       show execution-budget defaults
\page-size <count>            set a default for paged commands
\next                         replay the last request with its continuation
\history                      show in-memory session history
\mode <mode>                  select explicit command or statement mode
\g / \clear / \quit           execute, clear, or exit
```

The shell injects a default only when the selected command declares that
option. It does not add paging to mutations or connection options to local
profile commands. The standard prompt has no target state. With
`MultipleBases`, the selected target is visible in the prompt; `\database` and
profile changes select the database/control target, while Composition selection
is rejected by mutation commands. There is no long-lived server transaction.

## Capability and schema commands

| Command | Wire operation | Behavior and output | Effects / principal failures |
|---|---|---|---|
| `database capabilities` | `capabilitiesDescribe` | Returns runtime version, feature/version pairs, and advertised job family/kind pairs as JSON. | Read-only; authentication, routing, or protocol failure remains explicit. |
| `database schema list` | `schemaDescribe` | Returns schema version and every entity declaration. | Read-only. |
| `database schema show <entity>` | `schemaDescribe` | Fetches the schema and selects exactly one named entity client-side. | Read-only; missing entity is not-found, not an empty list. |
| `database schema plan <manifest>` | `schemaExecute.plan` | Strictly decodes the Schema JSON and returns current/target fingerprints, compatibility, and issues. Optional expected fingerprint detects drift. | Read-only; malformed manifests and fingerprint conflict fail. May use `--as-job`. |
| `database schema apply <manifest>` | `schemaExecute.apply` | Requires expected fingerprint and idempotency key. The server either returns an accepted persistent job or the applied fingerprint/version/generation. | Mutating; conflict, incompatible change, unsupported index, or resource limit is never downgraded. May use `--as-job`. |

## Base lifecycle

This family is available only when the server advertises `base.execute`, which
is supplied by the non-default `MultipleBases` trait. A Base is then the native
boundary for data, Grants, provenance, placement, and a data transaction.
Identifiers are canonical ASCII slugs. Placement names select configured
destinations without exposing backend credentials.

| Command | Target and input | Result / effects |
|---|---|---|
| `database base placements` | Database target. | Lists configured placement IDs and the default placement; read-only. |
| `database base list` | Database target. | Lists visible Base descriptions; unauthorized Bases are not exposed. |
| `database base describe <base>` | The positional ID is also the Base target. | Returns placement, lifecycle, revision, and generation. |
| `database base create <base>` | Database target; requires placement, one or more initial Grants, expected revision, and idempotency key. | Starts a persistent provisioning job. At least one initial Grant must include `administer`. |
| `database base retire <base>` | Base target; expected revision and idempotency key. | Starts drain/retire lifecycle work; new data operations stop after retirement begins. |
| `database base activate <base>` | Base target; expected revision and idempotency key. | Starts explicit activation. Placement movement never activates implicitly. |
| `database base delete <base>` | Base target; expected revision and idempotency key. | Starts deletion and leaves a non-reusable tombstone. |
| `database base placement plan <base>` | Base target; destination and expected revision. | Validates an offline move without changing data. |
| `database base placement apply <base>` | Base target; destination, expected revision, and idempotency key. | Starts resumable copy, digest verification, cutover, and cleanup. |

Initial Grants use repeatable
`--initial-grant 'principal:<id>=read,write,administer'` or
`--initial-grant 'role:<id>=read,write,administer'`. Access bits are independent;
listing all three spells full access.

## Composition catalog

This family is available only when the server advertises
`composition.execute`, also supplied by `MultipleBases`. A Composition is a
named, immutable-generation definition of a non-empty, canonical set of member
Bases. It is read-only: it does not expose a mutation context.

| Command | Target and input | Result / effects |
|---|---|---|
| `database composition list` | Database target. | Lists visible Composition definitions. |
| `database composition describe <composition>` | The positional ID is the Composition target. | Returns members, revision, and generation. |
| `database composition create <composition>` | Database target; repeat `--base`, then supply expected revision and idempotency key. | Creates the canonical membership set. Empty or duplicate membership fails. |
| `database composition replace <composition>` | Composition target; complete replacement membership, expected revision, and idempotency key. | Publishes a new generation atomically. |
| `database composition delete <composition>` | Composition target; expected revision and idempotency key. | Deletes the catalog definition; conflicts remain explicit. |

Composition query output carries row/quad origin and generation. JSON and
JSONL use `$provenance`; page metadata reports `$consistency`. N-Quads is
rejected for Composition results because it cannot preserve origin. A plan
whose cross-Base semantics are not advertised fails as unsupported instead of
falling back to concatenated per-Base execution.

## Persisted Grants

| Command | Target and input | Result / effects |
|---|---|---|
| `database grant direct` | Database by default or `--base`; optional principal or role filter. | Lists direct persisted Grants and revision. |
| `database grant effective` | Database by default or `--base`; always evaluates the authenticated principal. | Returns the unioned independent access bits and contributing Grants. |
| `database grant add` | Database by default or `--base`, plus a subject; requires access list, expected revision, and idempotency key. | Persists one Grant in the target transaction domain. |
| `database grant revoke` | Same target and subject contract as add. | Revokes the selected bits under revision control without permitting removal of the final administrator. |

Database Grants do not implicitly grant access to a Base. Direct principal and
principal-role Grants are unioned, then server policy and schema field policy
are evaluated. The CLI never implements an administrator bypass.

## Query and mutation statements

| Command | Wire operation | Behavior | Output / effects |
|---|---|---|---|
| `database query sql <statement>` | `queryExecute` with SQL text | Standard: single database root. `MultipleBases`: required `--base` or `--composition`. Statement `LIMIT` changes query semantics; `--page-size` only bounds one response page. | Rows, RDF graph, or boolean according to the canonical response; paged and job-capable. |
| `database query sparql <statement>` | `queryExecute` with SPARQL text | Uses the same trait-dependent root selection, parameter, graph-partition, budget, paging, and job contracts. | Rows, RDF graph, or boolean; paged and job-capable. |
| `database mutate sql <statement>` | `mutationExecute` statement input | Standard: single database root. `MultipleBases`: required `--base`. Executes one mutating SQL operation with parameters, graph partitions, budget, metadata, and optional job start. | JSON commit version and entity/RDF effects; no result paging options. |
| `database mutate sparql <statement>` | `mutationExecute` statement input | Uses the same trait-dependent data-root selection and executes one SPARQL update under the mutation transaction contract. | JSON commit version and RDF effects; no result paging options. |

`--parameter '<selector>=<typed-literal>'` is repeatable and supports positional
selectors such as `$1` or named selectors. `--parameters` accepts the canonical
typed parameter array and conflicts with `--parameter`. The CLI sends the
statement as text without attempting read/write classification.

## Entity mutations

All entity commands map to one `mutationExecute` request. Changes,
preconditions, relationship enforcement, persistence, and index updates commit
atomically or fail together.

| Command | Input and semantics |
|---|---|
| `database entity insert <entity> <id> <fields>` | Inserts one entity. ID is an explicit scalar literal or tagged value; fields and partitions are tagged objects. |
| `database entity update <entity> <id> <fields>` | Updates one entity under the canonical update semantics. |
| `database entity upsert <entity> <id> <fields>` | Inserts or updates one entity according to server schema. |
| `database entity delete <entity> <id>` | Deletes one entity; no fields document is accepted. |
| `database entity apply <manifest>` | Applies a non-empty array of insert/update/upsert/delete changes and optional preconditions as one atomic request. |

Single-entity commands accept at most one of `--expected-version`,
`--must-exist`, or `--must-not-exist`. `entity apply` requires strict object
keys `changes` and optional `preconditions`; identities are tagged references.
Success returns commit version and per-entity effects. All commands accept
execution budgets, graph partitions, and an advertised `--as-job` kind; they
do not accept query parameters or paging controls.

## Graph algorithms

Every graph command maps to `graphAlgorithm` and requires a declared `--index`.
It uses the standard single root or a required `--base` with `MultipleBases`, and accepts source selection
(`--partitions`, `--graph`, `--edge-label`), an execution budget, result paging,
streaming output, and an advertised job kind.

| Command | Required / algorithm-specific input | Result |
|---|---|---|
| `database graph shortest-path` | `--source`, `--target`; optional maximum depth/nodes and bidirectional search | Path summary, ordered nodes, edge labels, and weights |
| `database graph weighted-shortest-path` | `--source`, `--target`, `--weight-property`; optional maximum weight/nodes | Minimum-weight path or not-found summary |
| `database graph page-rank` | Optional damping factor, iteration limit, convergence threshold, personalized source | Vertex ranking with iteration/convergence metadata |
| `database graph community` | Optional iteration limit, minimum size, seed, modularity calculation | Vertex-to-community assignments and optional modularity |
| `database graph cycles` | Optional maximum cycles/nodes | Cycles and detected back edges |
| `database graph strongly-connected-components` | Optional maximum components/nodes | Strongly connected components |
| `database graph topological-sort` | Optional maximum nodes | Ordered vertices and any cyclic vertices |

Graph terms must be tagged strings or RDF terms. Finite-number, integer, and
resource limits are validated before transport where possible; server-side
capability, index, and resource failures remain typed failures.

## Ontology operations

| Command | Invocation and input | Output / effects |
|---|---|---|
| `database ontology describe <ontology>` | Reads a stored ontology. | Imports and RDF axioms; read-only and paged. |
| `database ontology upsert <document>` | Strict document containing ontology ID, imports, and an N-Quads source; optional expected revision. | Commit version and new revision; mutating. |
| `database ontology delete <ontology>` | Deletes with optional expected revision. | Commit version and new revision; mutating. |
| `database ontology reason <ontology>` | Runs `rdfs` or `owl-rl` reasoning. | Inferred axioms; read-only and paged. |
| `database ontology hierarchy <ontology> <resource>` | Selects class/object-property/data-property, ancestors/descendants, and maximum depth. | Resource/depth entries; read-only and paged. |
| `database ontology validate-schema <ontology>` | Checks ontology/schema alignment. | Validation report; read-only and paged. |

Ontology commands use the standard single root or a required `--base` with
`MultipleBases`, enforce
the execution budget, and support advertised job kinds. Only commands whose
responses can continue expose paging controls.

## SHACL operations

| Command | Invocation and input | Output / effects |
|---|---|---|
| `database shacl describe <graph>` | Reads one shapes graph. | RDF shapes; read-only and paged. |
| `database shacl upsert <graph> <nquads>` | Strictly decodes N-Quads and optionally checks expected revision. | Commit version and new revision; mutating. |
| `database shacl delete <graph>` | Deletes with optional expected revision. | Commit version and new revision; mutating. |
| `database shacl validate <shapes-graph>` | Requires source entity/index; optionally selects partitions, data graph, focus, and entailment. | Conformance/violation report; read-only and paged. Non-conformance is data, while execution failure is a typed error. |

SHACL commands use the standard single root or a required `--base` with
`MultipleBases`, enforce
budgets, and support advertised job kinds. Named data graphs are tagged RDF
terms. Explicit focus is a tagged array containing only RDF terms or only
entity references.

## Application commands

`database command run <identifier> <input>` maps to `commandExecute`. It uses
the standard single root or a required `--base` with `MultipleBases`, and accepts input that
must be a tagged object. `--access read-only|read-write` declares the canonical
command access contract and defaults to read-only; it is not inferred from the
identifier or payload. The registered server command remains authoritative and
may reject an incorrect declaration. Output contains the tagged command value,
access mode, and commit version for writes. The command supports budget,
stream output, and advertised jobs, but not query paging controls.

## Migration, index, and maintenance

These commands use the standard single root or a required `--base` with
`MultipleBases` and map to
`maintenanceExecute`. They can hold locks, consume significant work budget,
and change persistent state as described below.

| Command | Behavior | Result / effects |
|---|---|---|
| `database migration status` | Reads current, target, and pending registered migrations. | Read-only status; no continuation. |
| `database migration run` | Runs migrations through optional target version. | Persistent schema/data changes; resumable continuation and job support. |
| `database index status` | Reads lifecycle state, optionally filtered by entity/index/partitions. | Paged runtime states; read-only. |
| `database index rebuild <entity> <index>` | Rebuilds a declared index for selected partitions in bounded batches. | Persistent index-state changes; resumable and job-capable. |
| `database maintenance compact` | Requests backend compaction. | Backend-specific persistent maintenance; resumable and job-capable. |

Resumable maintenance exposes `--continuation` and bounded `--all`, but not
`--page-size` because `MaintenanceExecuteOperation.Request` has no page-limit
field. Cancellation or timeout is never reported as successful completion.

## Persistent jobs

A job is identified by canonical UUID, operation family, advertised kind, and
the exact target used when it was created.
The family spelling is the DatabaseWire identifier such as `queryExecute` or
`maintenanceExecute`.

| Command | Behavior | Output / effects |
|---|---|---|
| `database job status <job-id> <family> <kind>` | Performs one `jobStatus`. | State, progress, attempts, scheduling, cancellation request, and last unsuccessful commit error. |
| `database job wait <job-id> <family> <kind>` | Polls `jobStatus` until succeeded, failed, cancelled, or client timeout. | Final status only; polling does not create or mutate a job. |
| `database job result <job-id> <family> <kind>` | Dispatches `jobResult` through the typed source operation. | Decoded source-operation result; requires a completed compatible job. |
| `database job cancel <job-id> <family> <kind>` | Sends `jobCancel`. | Whether cancellation was accepted and current state; acceptance is not the same as terminal cancellation. |

Standard job commands are target-free. With `MultipleBases`, every job command
selects the database/control target or one `--base`, and the selected target
must match the persisted job identity. `job wait` alone
accepts polling interval and client wait timeout. Job commands
do not accept `--as-job`, query parameters, execution budgets, or source-result
paging controls.

## Inspection

Inspection is client-side composition of existing read-only operations. Missing
capabilities are reported as unsupported/unadvertised, never as an empty
successful collection.

| Command | Composed source and output |
|---|---|
| `database inspect overview` | `capabilitiesDescribe` plus `schemaDescribe` |
| `database inspect entities [entity]` | All schema entities or one selected entity |
| `database inspect indexes` | Schema index declarations plus standard-root or `MultipleBases` Base-targeted `maintenanceExecute.indexStatus`; accepts entity filter and returned continuation |
| `database inspect graph` | Graph-relevant relationship/index declarations from schema; optional entity filter |
| `database inspect ontology <ontology-id>` | Standard-root or `MultipleBases` Base-targeted canonical ontology describe path |
| `database inspect shapes <shape-graph-id>` | Standard-root or `MultipleBases` Base-targeted canonical SHACL describe path |
| `database inspect jobs` | Advertised family/kind pairs from capabilities; not a list of all job instances |

## Diagnostics

`database doctor` performs only bounded read-only checks in dependency order:

```text
installation -> local config / credential -> DNS -> TCP -> TLS
    -> authenticated protocol / routing -> capabilities -> schema
```

`--server-config` adds local server configuration checks. Each check reports
`pass`, `warn`, `fail`, or `skipped`, summary, remediation, and duration.
Warnings alone return success; a failure uses the most specific existing exit
code. Secrets are never emitted.

## FoundationDB companion

`database fdb ...` delegates to the adjacent `database-fdb` executable after a
version match. These commands never use an unrelated default cluster when an
explicit cluster cannot be opened.

| Command | Behavior and required bounds |
|---|---|
| `database fdb cluster init` | Initializes isolated local cluster files at `--path` and optional port. |
| `database fdb cluster start` | Starts the selected local cluster and waits for a real protocol readiness probe. |
| `database fdb cluster stop` | Stops the selected process and proves negative readiness. |
| `database fdb cluster status` | Reports process and protocol readiness without changing the cluster. |
| `database fdb catalog list --control-namespace <component> ...` | Opens the explicit cluster, resolves the exact existing control-domain namespace, and lists database catalog entities read-only. |
| `database fdb catalog show <entity> --control-namespace <component> ...` | Reads one catalog entity from the exact control-domain namespace or returns not-found. |
| `database fdb raw get` | Reads exactly one key selected by hex, UTF-8, or tuple encoding under a total-byte bound. |
| `database fdb raw range` | Reads one bounded prefix range; requires row limit and total-byte limit. |

Raw key selectors are mutually exclusive. Raw write, delete, clear, implicit
tuple conversion, and fallback cluster selection are intentionally absent.
Catalog commands require one repeatable `--control-namespace` value per ordered
namespace path component. They neither assume a default control domain nor
fall back to the global namespace.

## Output formats

Commands returning streamable query/domain results declare `--output` in their
exact help. Query rows support table, JSONL, JSON, and scalar CSV; RDF query
results support JSONL, JSON, and N-Quads. Graph, ontology, SHACL, application
command, and maintenance event streams support table, JSONL, and JSON. Fixed
metadata/mutation objects use canonical JSON and do not advertise an ignored
format option.

Composition query rows and RDF quads add `$provenance` in JSON/JSONL. Table and
CSV row output append a `$provenance` column where those formats are valid.
N-Quads is accepted only for exact-Base RDF results because it cannot encode
Composition origin. JSONL emits a page metadata record containing
`$consistency`; other formats write the same page metadata to diagnostics.

Standard output is result data only. Standard error is diagnostics, prompts,
timing, and paging metadata. A format incompatible with the actual result type
is an input failure, not a fallback.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | success |
| `2` | input or configuration |
| `3` | authentication |
| `4` | authorization |
| `5` | not found |
| `6` | conflict or constraint |
| `7` | resource limit |
| `8` | transport or unavailable |
| `9` | protocol or internal failure |
| `130` | cancellation |

Malformed input, unsupported capability, missing data, conflict, cancellation,
and resource exhaustion are never converted into empty or synthetic success.
