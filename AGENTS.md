# AGENTS.md

## Responsibility

- This package owns command parsing, profiles, credential resolution, typed
  JSON, output rendering, shell state, and FoundationDB diagnostic composition.
- The `database` executable invokes canonical operations through
  `DatabaseClient`; it never imports or links a storage backend.
- The `database-fdb` companion exclusively owns local FoundationDB cluster
  lifecycle, catalog inspection, and bounded read-only raw inspection. Native
  database serving selects its backend in the adjacent `database-server`.
- Command mode and shell mode use the same parser and executor.

## Security and data contracts

- Access tokens never appear in process arguments, profile files, history, or
  diagnostics. Resolve them from the platform secret store, a profile-selected
  environment variable, `DATABASE_ACCESS_TOKEN`, or non-echo TTY input.
- Structured values use lossless tagged JSON. Reject duplicate keys, untagged
  numbers, unknown tags, non-finite values, and configured depth/byte limits.
- Result pages are consumed with retained iterators. Render one element at a
  time and release one page before requesting the next.
- Standard output contains results only. Diagnostics use standard error.
- Do not retry or silently select a different endpoint, transport, cluster, or
  database.

## Verification

- Use `scripts/xcode-test-harness` with the pinned Swift snapshot and an
  external timeout. The harness must report exact counts and zero skips,
  expected failures, runtime warnings, or internal tool errors. The reviewed
  contract is 48 logical tests.
- Use `scripts/process-test-harness` with adjacent, version-matched
  `database`, `database-fdb`, and `database-server` executables. It owns a
  disposable `DATABASE_CLI_CONFIG_HOME`, profile, Keychain credential, and
  SQLite file; it must prove authenticated serve reachability, SIGINT child
  shutdown, controlling-terminal Tab completion, and negative readiness before
  cleanup.
- FoundationDB integration uses `scripts/fdb-test-harness`, an isolated cluster
  file, protocol readiness, authoritative shutdown, and negative readiness
  after teardown.
- Before release, `Package.swift` must contain URL dependencies only. All three
  executable products must be built, and the main `database` binary must not
  link FoundationDB.
