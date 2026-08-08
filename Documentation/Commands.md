# Command contract

## DatabaseWire mapping

| CLI family | Canonical operation |
|---|---|
| `capabilities` | `capabilitiesDescribe` |
| `schema list/show` | `schemaDescribe` |
| `query sql/sparql` | `queryExecute` |
| `mutate sql/sparql`, `entity ...` | `mutationExecute` |
| `graph ...` | `graphAlgorithm` |
| `ontology ...` | `ontologyExecute` |
| `shacl ...` | `shaclExecute` |
| `command run` | `commandExecute` |
| `migration`, `index`, `maintenance` | `maintenanceExecute` |
| supported commands with `--as-job` | `capabilitiesDescribe`, then `jobStart` |
| `job status/wait/result/cancel` | corresponding job operation |

`--as-job <kind>` is accepted only when the server advertises the exact
operation family and kind. `job wait` performs bounded status polling; it does
not create a new wire operation.

## Common options

Connection options are `--profile`, `--endpoint`, `--database`, `--tenant`, and
`--workspace`. An explicit option overrides its selected profile value for one
invocation. HTTP/HTTPS URLs choose the HTTP transport; WS/WSS URLs choose the
WebSocket transport.

Request metadata is `--trace-id` and `--idempotency-key`. Execution budgets are:

- `--maximum-rows`
- `--maximum-work-units`
- `--maximum-intermediate-rows`
- `--maximum-intermediate-bytes`
- `--timeout-milliseconds`

Paging uses `--page-size` and an optional base64url `--continuation`. `--all`
cannot be combined with an initial continuation and requires
`--max-total-rows`, `--max-total-bytes`, and `--max-pages`.

## Shell

The shell uses exactly the same parser and executor as one-shot commands.

```text
command mode
├── every one-shot command
├── query sql|sparql -> multiline buffer
└── mutate sql|sparql -> multiline buffer
```

Multiline statements execute only with `\g`; semicolons do not trigger
execution and the CLI does not infer read versus write intent.

Meta commands are `\help`, `\profile`, `\output`, `\timing`, `\budget`,
`\page-size`, `\next`, `\history`, `\mode command`, `\clear`, `\g`, and
`\quit`. History is memory-only unless `--persist-history` is present.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | success |
| 2 | input or configuration |
| 3 | authentication |
| 4 | authorization |
| 5 | not found |
| 6 | conflict or constraint |
| 7 | resource limit |
| 8 | transport or unavailable |
| 9 | protocol or internal failure |
| 130 | cancellation |
