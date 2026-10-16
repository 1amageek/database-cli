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
