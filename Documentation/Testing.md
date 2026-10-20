# Testing and release

Use the pinned Swift snapshot:

```bash
scripts/xcode-test-harness
```

Use `--preserve-work-root` and then `--reuse-work-root <reported-path>` to
resynchronize sources and reuse dependencies attributed to the same manifest
and input pins. The harness still runs `build-for-testing`, injects the pinned
testing runtime, and executes `test-without-building`.
Focused runs require repeatable `--only-testing <identifier>` selectors and
`--expected-count <count>`. Full-graph exact counts are owned by
`scripts/xcode-test-harness`.

The harness selects `org.swift.64202608141a`, performs one
`build-for-testing`, injects the snapshot's
`libTesting.dylib` path into every generated test target, then runs
`test-without-building`. It requires the reviewed test count, zero failures,
zero skips, zero expected failures, zero runtime warnings, and no internal tool
errors. Dependency checkout bypasses Xcode's shared repository cache so a
newly published package revision cannot be resolved from stale tag metadata
without its commit tree. To diagnose unpublished cross-package changes, use
`--diagnostic-source-root <prepared-copy>` with explicit absolute local package
references in that copy. The harness preserves the original URL manifest and
pins and records the diagnostic graph. Such results are local integration
evidence; final verification uses the committed URL dependency graph.

| Graph | Trait selection | Required logical tests |
|---|---|---|
| Standard single root | none | Harness-owned exact count |
| Explicit MultiBase | `DATABASE_CLI_TEST_TRAITS=MultiBase` | Harness-owned exact count |

Both graphs require zero failures, zero skips, zero expected failures, zero
runtime warnings, and no internal tool errors.

Executable contracts use:

```bash
swift build \
  --scratch-path /tmp/database-cli-release-products \
  --disable-dependency-cache \
  --only-use-versions-from-resolved-file
DATABASE_CLI_EXECUTABLE=/path/to/database \
DATABASE_FDB_EXECUTABLE=/path/to/database-fdb \
DATABASE_SERVER_EXECUTABLE=/path/to/database-server \
scripts/process-test-harness
```

Use `database` and `database-fdb` from that exact URL-resolved package build.
Build `database-server` from its own URL-resolved package graph at the exact
matching executable version. The disabled dependency cache prevents stale tag
metadata in a shared SwiftPM repository cache from selecting a revision whose
commit tree has not been fetched.

| Binary | Owning package | Harness responsibility |
|---|---|---|
| `database` | `database-cli` | Parsing, invocation, shell, profile, credential, and output behavior |
| `database-fdb` | `database-cli` | Explicit FoundationDB lifecycle and bounded diagnostics |
| `database-server` | `database-server` | Native host, DatabaseWire dispatch, backend composition, and authoritative shutdown |

The process harness sets `DATABASE_CLI_CONFIG_HOME` to a disposable mode-`0700`
directory so profiles, server configuration, and history never touch the
developer's normal configuration. It removes the unique Keychain credential in
both the success path and its cleanup trap.

The process harness verifies stdout/stderr separation, stable exit codes,
explicit shell launch, controlling-terminal Tab completion, history
permissions, secret redaction, companion version matching, missing-companion
failure, standalone memory/file execution, child shutdown, a real
authenticated `database serve` round trip, negative readiness, disposable
profile/Keychain cleanup, and link separation. Its `query-process-test` step
checks first, continuation, zero-row and aggregate JSON pages plus zero-row
JSONL column events through the real authenticated SQL command. Duplicate
labels, all five rich value cases and typed NULL retain their exact shape;
stdout and stderr evidence is preserved in the reported result directory.
Its `entity-policy-process-test` step republishes the schema with an entity
whose launch `entityPolicies` grant the admin profile only list, get and
create, applies a 1000-record sample in one atomic change, requires update and
delete through `sql execute` (`42501`) and `entity delete` (`ACCESS_DENIED`) to
be denied, and reads every sample record and the earlier fixture back intact.

Native backend integration is owned by the adjacent Server package and uses
the exact same three binaries:

```bash
DATABASE_CLI_EXECUTABLE=/path/to/database \
DATABASE_SERVER_EXECUTABLE=/path/to/database-server \
DATABASE_FDB_EXECUTABLE=/path/to/database-fdb \
../database-server/scripts/storage-test-harness
```

It opens SQLite, an isolated PostgreSQL 16 Unix-socket instance, and an
explicit isolated FoundationDB 7.3 cluster through `database open`, then proves
the external services are unreachable after teardown.

FoundationDB integration uses an isolated cluster:

```bash
DATABASE_FDB_EXECUTABLE=/path/to/database-fdb \
scripts/fdb-test-harness
```

It records the FoundationDB version and endpoint, initializes one disposable
cluster, proves protocol readiness, exercises raw get/range against the selected
cluster, stops it, and requires negative protocol readiness.

Before tagging:

1. verify `Package.swift` contains URL dependencies only;
2. run the strict Xcode, process, and FoundationDB harnesses;
3. verify the committed command catalog, generated completions, README, and
   command reference use the same public names and trait spelling;
4. verify the CLI, FoundationDB companion, and native server versions match;
5. verify `database` does not link `libfdb_c`, while the native server and
   `database-fdb` companion do;
6. inspect the `.xcresult` summary and preserved logs;
7. confirm the worktree contains no generated build artifacts or obsolete
   compatibility path;
8. push the commit, create the release tag, and verify the tag commit equals
   `origin/main`.
