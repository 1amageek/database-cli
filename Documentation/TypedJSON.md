# Lossless typed JSON

Structured CLI values use a canonical tagged representation. No untagged JSON
number is accepted, so a value never changes identity through JSON inference.

```json
{"$type":"int64","value":"-9223372036854775808"}
```

```json
{"$type":"float64","bits":"3ff0000000000000"}
```

```json
{"$type":"bytes","value":"AAEC_w"}
```

Integers and decimals use canonical decimal strings. Floating-point values use
fixed-width lowercase IEEE bit patterns. Bytes and continuations use unpadded
base64url. Arrays, objects, references, RDF terms, and vectors recursively
contain typed values.

The decoder rejects duplicate object keys, unknown tags, unknown fields,
non-canonical integers, out-of-range values, non-finite floating-point values,
invalid base64url, storage/type mismatch, and configured byte or nesting limits.
Encoding followed by decoding preserves the exact `FieldValue` identity.

Input specifications are:

- inline JSON;
- `@path` for a bounded file read;
- `@-` for a bounded standard-input read.

An initial `@` is therefore reserved for input indirection.

Query result values also admit the closed `composite` tag. Its exact members
are `$type`, `type`, and `fields`. `type` contains the complete SQL composite
query-column descriptor, including ordered field numbers, names, types, and
nullability; `fields` contains one tagged query value per descriptor field.
Duplicate field names retain their positions. A SQL NULL remains the existing
`null` tagged value and differs from a present composite whose fields are all
NULL. Arrays can contain composite values. Arity, type, nullability, unknown
members, and byte/depth limits are checked before returning a value. Table and
CSV cells render composites as the same bounded tagged JSON.

Value-contained type descriptors use the value adapter's configured byte and
semantic depth budgets. The internal descriptor JSON depth is bounded by three
times semantic depth and the Wire-supported maximum; standalone result-column
metadata retains its own default descriptor limits.

## Complete SQL results

`sql execute` emits ordered outcome objects. JSON output is one array of those
objects; JSONL is one complete object per line. Every object has a one-based
canonical decimal-string `index` and a `kind` discriminator. Numeric counts
are canonical decimal strings and an absent affected-row count is JSON null.

| Kind | Additional members |
|---|---|
| `rows` | `columns`: ordered query-column descriptors; `rowCount`: complete row count; `affectedRows`: optional count; `rows`: positional tagged row objects using the existing `row`/`values` grammar. |
| `copy` | `affectedRows`: count; `bytes`: the existing tagged `bytes` value containing unpadded base64url. |
| `command` | `command`: the canonical SQL command name; `affectedRows`: optional count. |

Duplicate column labels remain separate numbered columns. Empty row results
retain `columns`, `rowCount` zero and an empty `rows` array. COPY bytes are never
implicitly decoded as text, concatenated into other outcomes or written to a
host file. Result objects contain no continuation or invented read point.

Typed SQL failures use stderr's existing `error: ` prefix followed by a JSON
object with `sqlState` and `message`, optional canonical decimal-string
`position`, and optional exact `schema`, `table`, `column` and `constraint`
strings. These members come from the canonical remote diagnostic. Malformed
reserved diagnostic metadata is an internal protocol failure rather than an
absent diagnostic or successful result.
