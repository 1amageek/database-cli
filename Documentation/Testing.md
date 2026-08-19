# Testing and release

Use the pinned Swift snapshot:

```bash
scripts/xcode-test-harness
```

Set `XCODE_TEST_DERIVED_DATA_PATH` to an already attributed URL-resolved
DerivedData directory to reuse compiled dependencies. The harness still runs
`build-for-testing`, injects the pinned testing runtime, and executes
`test-without-building`; it does not trust a compile-only result.

The harness selects `org.swift.64202608141a`, performs one
`build-for-testing`, injects the snapshot's
`libTesting.dylib` path into every generated test target, then runs
`test-without-building`. It requires the reviewed test count, zero failures,
zero skips, zero expected failures, zero runtime warnings, and no internal tool
errors. Dependency checkout bypasses Xcode's shared repository cache so a
newly published package revision cannot be resolved from stale tag metadata
without its commit tree. Local path dependencies are rejected unless
`DATABASE_CLI_ALLOW_LOCAL_DEPENDENCIES=1` is explicitly set for diagnosis.
The reviewed contracts are:

| Graph | Trait selection | Required logical tests |
|---|---|---:|
| Standard single root | none | 47 |
| Explicit MultiBase | `DATABASE_CLI_TEST_TRAITS=MultiBase` | 60 |

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
profile/Keychain cleanup, and link separation.

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
