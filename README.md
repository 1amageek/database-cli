# database-cli

`database-cli` is the authenticated command-line client for the DatabaseWire
protocol. The main `database` executable reaches database semantics exclusively
through `DatabaseClient`; it does not import or link a storage backend.
FoundationDB lifecycle and read-only diagnostics live in the adjacent,
version-matched `database-fdb` companion.

```text
database command / shell
        -> DatabaseClient
            -> DatabaseWire v1
                -> DatabaseServerRuntime

database fdb ...
        -> adjacent database-fdb
            -> selected cluster file
                -> FoundationDB read-only diagnostics
```

## Command catalog

```text
database
├── profile create|list|show|use|remove
├── auth login|logout
├── capabilities
├── schema list|show
├── query sql|sparql
├── mutate sql|sparql
├── entity insert|update|upsert|delete|apply
├── graph shortest-path|weighted-shortest-path|page-rank|community
│         cycles|strongly-connected-components|topological-sort
├── ontology describe|upsert|delete|reason|hierarchy|validate-schema
├── shacl describe|upsert|delete|validate
├── command run
├── migration status|run
├── index status|rebuild
├── maintenance compact
├── job status|wait|result|cancel
├── shell
└── fdb cluster|catalog|raw
```

Running `database` without arguments prints help. Interactive use is explicit:

```bash
database shell
```

## Profiles and authentication

```bash
database profile create production \
  --endpoint https://database.example.com/v1 \
  --database main \
  --tenant acme \
  --workspace research
database profile use production
database auth login
```

Bearer tokens are never accepted as process arguments. Resolution precedence is
the platform keychain, the profile-selected environment variable,
`DATABASE_ACCESS_TOKEN`, then non-echo terminal input. Profile files contain
routing configuration only and are written with mode `0600` beneath a `0700`
directory.

## Query and mutation

```bash
database query sql 'SELECT * FROM Person' --page-size 100
database query sparql @query.rq --output jsonl
database mutate sparql @update.ru --idempotency-key update-2026-08-08
database entity insert Person \
  '{"$type":"string","value":"person-1"}' \
  @person.json
```

Structured values accept inline JSON, `@path`, or `@-` for standard input.
Paging defaults to one page. Fetching every page requires all three aggregate
limits:

```bash
database query sql @query.sql --all \
  --max-total-rows 100000 \
  --max-total-bytes 67108864 \
  --max-pages 100
```

## Output

TTY output defaults to `table`; redirected output defaults to lossless tagged
`jsonl`. Use `--output table|jsonl|json|csv|nquads` to fix a format. Standard
output contains results only, while diagnostics and non-row paging metadata use
standard error. CSV accepts scalar rows only. N-Quads accepts RDF results only.

## FoundationDB diagnostics

```bash
database fdb cluster init --path /srv/database --port 4690
database fdb cluster start --path /srv/database
database fdb cluster status --path /srv/database
database fdb raw get --cluster-file /srv/database/.database/fdb.cluster \
  --key-hex 01636174616c6f67 --max-total-bytes 1048576
database fdb cluster stop --path /srv/database
```

Raw keys require exactly one of `--key-hex`, `--key-utf8`, or `--key-tuple`.
Raw range reads require both row and byte limits. No raw write, delete, or clear
command exists. An explicit missing cluster file is an error; the helper never
falls back to the default FoundationDB cluster.

## Documentation

- [Architecture](Documentation/Architecture.md)
- [Command contract](Documentation/Commands.md)
- [Lossless typed JSON](Documentation/TypedJSON.md)
- [Security](Documentation/Security.md)
- [Testing and release](Documentation/Testing.md)

## License

See the repository license file.
