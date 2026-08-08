import DatabaseTypes
import Testing
@testable import DatabaseCommandLine

private struct FieldValueFixture: Sendable {
    let name: String
    let json: String
}

private let fieldValueFixtures: [FieldValueFixture] = [
    .init(name: "null", json: #"{"$type":"null"}"#),
    .init(name: "bool", json: #"{"$type":"bool","value":true}"#),
    .init(name: "int8", json: #"{"$type":"int8","value":"-128"}"#),
    .init(name: "int16", json: #"{"$type":"int16","value":"-32768"}"#),
    .init(name: "int32", json: #"{"$type":"int32","value":"-2147483648"}"#),
    .init(name: "int64", json: #"{"$type":"int64","value":"-9223372036854775808"}"#),
    .init(name: "uint8", json: #"{"$type":"uint8","value":"255"}"#),
    .init(name: "uint16", json: #"{"$type":"uint16","value":"65535"}"#),
    .init(name: "uint32", json: #"{"$type":"uint32","value":"4294967295"}"#),
    .init(name: "uint64", json: #"{"$type":"uint64","value":"18446744073709551615"}"#),
    .init(name: "float32", json: #"{"$type":"float32","bits":"3fc00000"}"#),
    .init(name: "float64", json: #"{"$type":"float64","bits":"4004000000000000"}"#),
    .init(name: "decimal", json: #"{"$type":"decimal","value":"123.45"}"#),
    .init(name: "string", json: #"{"$type":"string","value":"hello"}"#),
    .init(name: "bytes", json: #"{"$type":"bytes","value":"AAEC_w"}"#),
    .init(name: "date", json: #"{"$type":"date","year":"2026","month":"8","day":"8"}"#),
    .init(name: "time", json: #"{"$type":"time","hour":"12","minute":"34","second":"56","nanoseconds":"789"}"#),
    .init(name: "dateTime", json: #"{"$type":"dateTime","date":{"$type":"date","year":"2026","month":"8","day":"8"},"time":{"$type":"time","hour":"12","minute":"34","second":"56","nanoseconds":"789"}}"#),
    .init(name: "timestamp", json: #"{"$type":"timestamp","seconds":"1","nanoseconds":"2"}"#),
    .init(name: "timeSpan", json: #"{"$type":"timeSpan","seconds":"-1","nanoseconds":"2"}"#),
    .init(name: "calendarPeriod", json: #"{"$type":"calendarPeriod","months":"2","days":"3"}"#),
    .init(name: "geographicPoint", json: #"{"$type":"geographicPoint","latitudeBits":"3ff0000000000000","longitudeBits":"4000000000000000"}"#),
    .init(name: "geographicPosition", json: #"{"$type":"geographicPosition","latitudeBits":"3ff0000000000000","longitudeBits":"4000000000000000","heightBits":"4008000000000000"}"#),
    .init(name: "vector", json: #"{"$type":"vector","elementType":"float32","values":["3f800000","40000000"]}"#),
    .init(name: "uuid", json: #"{"$type":"uuid","value":"00000000-0000-0000-0000-000000000001"}"#),
    .init(name: "array", json: #"{"$type":"array","value":[{"$type":"string","value":"x"},{"$type":"uint8","value":"1"}]}"#),
    .init(name: "object", json: #"{"$type":"object","value":{"name":{"$type":"string","value":"Ada"}}}"#),
    .init(name: "reference", json: #"{"$type":"reference","entity":"Person","id":{"kind":"composite","value":[{"kind":"string","value":"tenant"},{"kind":"uint64","value":"7"}]},"partitions":{"$type":"object","value":{"region":{"$type":"string","value":"jp"}}}}"#),
    .init(name: "rdfTerm", json: #"{"$type":"rdfTerm","value":{"kind":"tripleTerm","subject":{"kind":"iri","value":"urn:subject"},"predicate":"urn:predicate","object":{"kind":"literal","lexicalForm":"hello","language":"en","direction":"ltr"}}}"#),
]

@Test("Every FieldValue case round-trips without identity loss", arguments: fieldValueFixtures)
private func fieldValueIdentityRoundTrip(_ fixture: FieldValueFixture) throws {
    let decoder = FieldValueJSONDecoder()
    let encoder = FieldValueJSONEncoder()
    let first = try decoder.decode(fixture.json)
    let encoded = try encoder.encode(first)
    let second = try decoder.decode(encoded)
    #expect(first == second, "Failed case: \(fixture.name)")
    #expect(encoded == fixture.json, "Non-canonical case: \(fixture.name)")
}

@Test("Every vector storage type round-trips", arguments: [
    "int8", "int16", "int32", "int64",
    "uint8", "uint16", "uint32", "uint64",
    "float32", "float64",
])
func vectorStorageRoundTrip(_ elementType: String) throws {
    let value = elementType.hasPrefix("float")
        ? (elementType == "float32" ? "3f800000" : "3ff0000000000000")
        : "1"
    let json = #"{"$type":"vector","elementType":"\#(elementType)","values":["\#(value)"]}"#
    let decoded = try FieldValueJSONDecoder().decode(json)
    #expect(try FieldValueJSONEncoder().encode(decoded) == json)
}

@Test("Malformed lossless JSON is rejected", arguments: [
    "1",
    #"{"$type":"int8","value":"01"}"#,
    #"{"$type":"int8","value":"128"}"#,
    #"{"$type":"float32","bits":"7f800000"}"#,
    #"{"$type":"float64","bits":"7ff0000000000000"}"#,
    #"{"$type":"unknown"}"#,
    #"{"$type":"bytes","value":"AA=="}"#,
    #"{"$type":"bool","value":true,"value":false}"#,
    #"{"$type":"null","extra":true}"#,
])
func rejectsMalformedLosslessJSON(_ json: String) {
    #expect(throws: DatabaseCLIError.self) {
        try FieldValueJSONDecoder().decode(json)
    }
}

@Test("Input byte and nesting limits fail explicitly")
func enforcesDecodeLimits() {
    #expect(throws: DatabaseCLIError.self) {
        try FieldValueJSONDecoder(maximumBytes: 8).decode(
            #"{"$type":"null"}"#
        )
    }
    #expect(throws: DatabaseCLIError.self) {
        try FieldValueJSONDecoder(maximumDepth: 1).decode(
            #"{"$type":"array","value":[{"$type":"array","value":[]}]}"#
        )
    }
}
