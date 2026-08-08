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
