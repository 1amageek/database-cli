# Testing and release

Use the pinned Swift snapshot:

```bash
export TOOLCHAINS=org.swift.64202607231a
scripts/xcode-test-harness
```

The harness performs one `build-for-testing`, injects the snapshot's
`libTesting.dylib` path into every generated test target, then runs
`test-without-building`. It requires the reviewed test count, zero failures,
zero skips, zero expected failures, zero runtime warnings, and no internal tool
errors. Local path dependencies are rejected unless
`DATABASE_CLI_ALLOW_LOCAL_DEPENDENCIES=1` is explicitly set for diagnosis.

Executable contracts use:

```bash
DATABASE_CLI_EXECUTABLE=/path/to/database \
DATABASE_FDB_EXECUTABLE=/path/to/database-fdb \
scripts/process-test-harness
```

The process harness verifies stdout/stderr separation, stable exit codes,
explicit shell launch, history permissions, secret redaction, companion version
matching, missing-helper failure, and link separation.

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
3. verify `database` does not link `libfdb_c` and `database-fdb` does;
4. inspect the `.xcresult` summary and preserved logs;
5. push the commit, create the release tag, and verify the tag commit equals
   `origin/main`.
