import DatabaseKit
import DatabaseTypes
import Testing
@testable import DatabaseCommandLine

private let queryJSONTestLimits = QueryValueLimits(
    maximumRetainedBytes: 1_048_576, maximumTotalNodes: 10_000,
    maximumNestingDepth: 64, maximumCollectionElements: 10_000
)

@Suite("Query value JSON contracts")
struct QueryValueJSONTests {
    @Test("Temporal carriers preserve exact tagged values and full offset identity")
    func temporalTaggedRoundTrips() throws {
        for micros: Int64 in [0, 1, 999_999, 1_000_001, 86_399_999_999, 86_400_000_000] {
            let time = try QueryTimeValue(microsecondsSinceMidnight: micros)
            let plain = #"{"$type":"sqlTime","microseconds":"\#(micros)"}"#
            #expect(try QueryValueJSONEncoder().encode(.time(time)) == plain)
            #expect(try QueryValueJSONDecoder().decode(plain) == .time(time))
            for offset: Int32 in [.min, -57_599, -1, 0, 1, 57_599, .max] {
                let value = QueryValue.timeWithTimeZone(QueryTimeWithTimeZoneValue(time: time, utcOffsetSeconds: offset))
                let tagged = #"{"$type":"sqlTimeWithTimeZone","microseconds":"\#(micros)","utcOffsetSeconds":"\#(offset)"}"#
                #expect(try QueryValueJSONEncoder().encode(value) == tagged)
                #expect(try QueryValueJSONDecoder().decode(tagged) == value)
            }
        }
        for (sign, name): (QueryTemporalInfinity, String) in [(.negative, "negative"), (.positive, "positive")] {
            for (value, tagged): (QueryValue, String) in [
                (.dateInfinity(sign), #"{"$type":"dateInfinity","sign":"\#(name)"}"#),
                (.timestampInfinity(sign, withTimeZone: false), #"{"$type":"timestampInfinity","sign":"\#(name)","withTimeZone":false}"#),
                (.timestampInfinity(sign, withTimeZone: true), #"{"$type":"timestampInfinity","sign":"\#(name)","withTimeZone":true}"#),
                (.intervalInfinity(sign), #"{"$type":"intervalInfinity","sign":"\#(name)"}"#),
            ] {
                #expect(try QueryValueJSONEncoder().encode(value) == tagged)
                #expect(try QueryValueJSONDecoder().decode(tagged) == value)
                expectQueryCLIError(.resourceLimit) { _ = try QueryValueJSONDecoder(maximumBytes: 8).decode(tagged) }
                expectQueryCLIError(.resourceLimit) { _ = try QueryValueJSONEncoder(maximumOutputBytes: 8).encode(value) }
            }
        }
        let time = try QueryTimeValue(microsecondsSinceMidnight: 86_400_000_000)
        for (value, type): (QueryValue, DataType) in [
            (.time(time), .time(withTimeZone: false, precision: nil)),
            (.timeWithTimeZone(QueryTimeWithTimeZoneValue(time: time, utcOffsetSeconds: .max)), .time(withTimeZone: true, precision: nil)),
            (.dateInfinity(.positive), .date),
            (.timestampInfinity(.negative, withTimeZone: true), .timestamp(withTimeZone: true, precision: nil)),
            (.intervalInfinity(.negative), .interval()),
        ] {
            let array = QueryValue.array(try QueryArrayValue(elementType: type,
                dimensions: [QueryArrayDimension(lowerBound: -1, length: 2)],
                elements: [value, .primitive(.null)], limits: queryJSONTestLimits))
            let tagged = try QueryValueJSONEncoder().encode(array)
            #expect(try QueryValueJSONDecoder().decode(tagged) == array)
            expectQueryCLIError(.resourceLimit) { _ = try QueryValueJSONDecoder(maximumDepth: 1).decode(tagged) }
        }
    }

    @Test("Finite primitive temporal tags remain byte-for-byte unchanged")
    func finitePrimitiveTemporalGoldens() throws {
        for tagged in [
            #"{"$type":"date","year":"2024","month":"2","day":"29"}"#,
            #"{"$type":"time","hour":"23","minute":"59","second":"59","nanoseconds":"999999000"}"#,
            #"{"$type":"dateTime","date":{"$type":"date","year":"2024","month":"2","day":"29"},"time":{"$type":"time","hour":"0","minute":"0","second":"0","nanoseconds":"0"}}"#,
            #"{"$type":"timestamp","seconds":"-1","nanoseconds":"999999000"}"#,
            #"{"$type":"interval","months":"-2","days":"3","microseconds":"-1"}"#,
        ] {
            let value = try QueryValueJSONDecoder().decode(tagged)
            #expect(try QueryValueJSONEncoder().encode(value) == tagged)
        }
    }

    @Test("Temporal tagged input rejects invalid shape, endpoints and canonical integers")
    func rejectsMalformedTemporalGrammar() {
        for tagged in [
            #"{"$type":"sqlTime"}"#, #"{"$type":"sqlTime","microseconds":"-1"}"#,
            #"{"$type":"sqlTime","microseconds":"86400000001"}"#,
            #"{"$type":"sqlTime","microseconds":"0","extra":true}"#,
            #"{"$type":"sqlTime","microseconds":"0","microseconds":"1"}"#,
            #"{"$type":"sqlTimeWithTimeZone","microseconds":"0"}"#,
            #"{"$type":"sqlTimeWithTimeZone","microseconds":"0","utcOffsetSeconds":"2147483648"}"#,
            #"{"$type":"sqlTimeWithTimeZone","microseconds":"0","utcOffsetSeconds":"-2147483649"}"#,
            #"{"$type":"dateInfinity","sign":"infinity"}"#,
            #"{"$type":"dateInfinity","sign":"positive","value":"infinity"}"#,
            #"{"$type":"timestampInfinity","sign":"positive"}"#,
            #"{"$type":"timestampInfinity","sign":"positive","withTimeZone":"true"}"#,
            #"{"$type":"intervalInfinity","sign":"positive","months":"0"}"#,
            #"{"$type":"intervalInfinity","sign":"negative","sign":"positive"}"#,
        ] { expectQueryCLIError(.input) { _ = try QueryValueJSONDecoder().decode(tagged) } }
        for number in ["01", "+1", "-0", "1.0", " 1", "9223372036854775808"] {
            for tagged in [
                #"{"$type":"sqlTime","microseconds":"\#(number)"}"#,
                #"{"$type":"sqlTimeWithTimeZone","microseconds":"0","utcOffsetSeconds":"\#(number)"}"#,
            ] { expectQueryCLIError(.input) { _ = try QueryValueJSONDecoder().decode(tagged) } }
        }
        expectQueryCLIError(.input) { _ = try QueryValueJSONDecoder().decode(#"{"$type":"sqlTime","microseconds":0}"#) }
    }

    @Test("Temporal text retains midnight endpoint, microseconds, full offsets and infinity")
    func temporalTextAndLimits() throws {
        let formatter = QueryValueTextFormatter()
        for (micros, expected): (Int64, String) in [
            (0, "00:00:00.000000"), (1, "00:00:00.000001"),
            (86_399_999_999, "23:59:59.999999"), (86_400_000_000, "24:00:00.000000"),
        ] {
            let time = try QueryTimeValue(microsecondsSinceMidnight: micros)
            #expect(try formatter.format(.time(time)) == expected)
            for (offset, suffix): (Int32, String) in [
                (.min, "-596523:14:08"), (-19_800, "-05:30:00"), (-1, "-00:00:01"),
                (0, "+00:00:00"), (1, "+00:00:01"), (19_800, "+05:30:00"), (.max, "+596523:14:07"),
            ] {
                let value = QueryValue.timeWithTimeZone(QueryTimeWithTimeZoneValue(time: time, utcOffsetSeconds: offset))
                #expect(try formatter.format(value) == expected + suffix)
                expectQueryCLIError(.resourceLimit) { _ = try QueryValueTextFormatter(maximumBytes: 1).format(value) }
            }
        }
        for (sign, expected): (QueryTemporalInfinity, String) in [(.negative, "-infinity"), (.positive, "infinity")] {
            for value: QueryValue in [.dateInfinity(sign), .timestampInfinity(sign, withTimeZone: false),
                                      .timestampInfinity(sign, withTimeZone: true), .intervalInfinity(sign)] {
                #expect(try formatter.format(value) == expected)
                expectQueryCLIError(.resourceLimit) { _ = try QueryValueTextFormatter(maximumBytes: 1).format(value) }
            }
        }
    }

    @Test("Temporal parameters preserve declared families and reject zone mismatches")
    func temporalDeclaredParameterTypes() throws {
        let time = try QueryTimeValue(microsecondsSinceMidnight: 86_400_000_000)
        let values: [(QueryValue, DataType)] = [
            (.time(time), .time(withTimeZone: false, precision: 6)),
            (.timeWithTimeZone(QueryTimeWithTimeZoneValue(time: time, utcOffsetSeconds: .min)), .time(withTimeZone: true, precision: 6)),
            (.dateInfinity(.positive), .date),
            (.timestampInfinity(.negative, withTimeZone: false), .timestamp(withTimeZone: false, precision: 3)),
            (.timestampInfinity(.positive, withTimeZone: true), .timestamp(withTimeZone: true, precision: nil)),
            (.intervalInfinity(.negative), .interval(fields: .dayToSecond, precision: 3)),
        ]
        for (value, type) in values {
            let specification = StrictJSONWriter.encode(.array([.object([
                ("position", .string("1")), ("value", try QueryValueJSONEncoder().node(value)),
                ("type", try QueryColumnJSONCodec.typeNode(.sql(type))),
            ])]))
            let parameters = try WireRequestBuilder().parameters(CommandOptions(["parameters": [specification]]))
            #expect(parameters == [QueryParameter(position: 1, value: value, type: .sql(type))])
        }
        for (value, type): (QueryValue, DataType) in [
            (.dateInfinity(.positive), .text),
            (.timestampInfinity(.positive, withTimeZone: false), .timestamp(withTimeZone: true, precision: nil)),
            (.timestampInfinity(.positive, withTimeZone: true), .timestamp(withTimeZone: false, precision: nil)),
            (.intervalInfinity(.positive), .date),
            (.time(time), .time(withTimeZone: true, precision: nil)),
        ] {
            let specification = StrictJSONWriter.encode(.array([.object([
                ("position", .string("1")), ("value", try QueryValueJSONEncoder().node(value)),
                ("type", try QueryColumnJSONCodec.typeNode(.sql(type))),
            ])]))
            expectQueryCLIError(.input) { _ = try WireRequestBuilder().parameters(CommandOptions(["parameters": [specification]])) }
        }
    }

    @Test("Interval modifiers survive descriptor, NULL parameter and empty array boundaries")
    func intervalDescriptorCarriage() throws {
        for fields in SQLIntervalFields.allCases {
            let type = QueryColumnType.sql(.interval(fields: fields, precision: nil))
            #expect(try QueryColumnJSONCodec.type(QueryColumnJSONCodec.typeNode(type)) == type)
        }
        let type = DataType.interval(fields: .dayToSecond, precision: 3)
        let descriptor = try QueryColumnJSONCodec.typeNode(.sql(type))
        #expect(try QueryColumnJSONCodec.type(descriptor) == .sql(type))
        #expect(StrictJSONWriter.encode(descriptor) == #"{"kind":"sql","type":{"kind":"interval","fields":"dayToSecond","precision":3}}"#)
        let empty = QueryValue.array(try QueryArrayValue(elementType: type, dimensions: [], elements: [], limits: queryJSONTestLimits))
        #expect(try QueryValueJSONDecoder().decode(QueryValueJSONEncoder().encode(empty)) == empty)
        let specification = StrictJSONWriter.encode(.array([.object([
            ("position", .string("1")), ("value", .object([("$type", .string("null"))])), ("type", descriptor),
        ])]))
        #expect(try WireRequestBuilder().parameters(CommandOptions(["parameters": [specification]])) == [
            QueryParameter(position: 1, value: .primitive(.null), type: .sql(type)),
        ])
    }

    @Test("Every query value case preserves its identity through tagged JSON")
    func allCasesRoundTrip() throws {
        let numeric = try QueryNumericValue(
            value: ExactDecimal(coefficient: 12345, scale: 2), displayScale: 4
        )
        let lexical = try QueryJSONValue(bytes: ByteString(utf8: " {\"a\":1,\"a\":2} "), limits: queryJSONTestLimits)
        let values: [QueryValue] = [
            .primitive(.int64(.min)), .numeric(numeric), .json(lexical),
            .jsonb(try QueryJSONBValue(root: .array([.null, .bool(true), .string("x"), .number(numeric)], limits: queryJSONTestLimits), limits: queryJSONTestLimits)),
            .array(try QueryArrayValue(elementType: .integer,
                                      dimensions: [QueryArrayDimension(lowerBound: -2, length: 2)],
                                      elements: [.primitive(.int32(7)), .primitive(.null)], limits: queryJSONTestLimits)),
            .interval(try QueryIntervalValue(period: CalendarPeriod(months: -2, days: 3),
                                             time: TimeSpan(seconds: -1, nanoseconds: 999_999_000))),
        ]
        for value in values {
            let encoded = try QueryValueJSONEncoder().encode(value)
            #expect(try QueryValueJSONDecoder().decode(encoded) == value)
        }
    }

    @Test("Numeric display scale is independent of canonical coefficient and scale")
    func numericDisplayScale() throws {
        let text = #"{"$type":"numeric","coefficient":"12345","scale":"2","displayScale":"4"}"#
        let value = try QueryValueJSONDecoder().decode(text)
        guard case .numeric(let numeric) = value else {
            Issue.record("Expected a rich numeric value")
            return
        }
        #expect(numeric.value == ExactDecimal(coefficient: 12345, scale: 2))
        #expect(numeric.displayScale == 4)
        #expect(try QueryValueJSONEncoder().encode(value) == text)
    }

    @Test("Lexical JSON retains whitespace and duplicate object members")
    func lexicalJSONIdentity() throws {
        let lexical = " \n{ \"a\": 1.2300, \"a\": 2 }\t"
        let value = QueryValue.json(try QueryJSONValue(bytes: ByteString(utf8: lexical), limits: queryJSONTestLimits))
        let encoded = try QueryValueJSONEncoder().encode(value)
        let decoded = try QueryValueJSONDecoder().decode(encoded)
        guard case .json(let json) = decoded else {
            Issue.record("Expected lexical JSON")
            return
        }
        #expect(json.bytes == ByteString(utf8: lexical))
        #expect(decoded == value)
    }

    @Test("JSONB preserves canonical member order and exact numeric metadata")
    func canonicalJSONBIdentity() throws {
        let json = try QueryJSONValue(bytes: ByteString(utf8: #"{"z":true,"a":1.2300}"#), limits: queryJSONTestLimits)
        let value = QueryValue.jsonb(try QueryJSONBValue(json: json, limits: queryJSONTestLimits))
        let encoded = try QueryValueJSONEncoder().encode(value)
        let expected = #"{"$type":"jsonb","value":{"kind":"object","value":[{"key":"a","value":{"kind":"number","value":{"coefficient":"123","scale":"2","displayScale":"4"}}},{"key":"z","value":{"kind":"bool","value":true}}]}}"#
        #expect(encoded == expected)
        #expect(try QueryValueJSONDecoder().decode(encoded) == value)
        for members in [
            #"[{"key":"z","value":{"kind":"null"}},{"key":"a","value":{"kind":"null"}}]"#,
            #"[{"key":"a","value":{"kind":"null"}},{"key":"a","value":{"kind":"null"}}]"#,
        ] {
            expectQueryCLIError(.input) {
                _ = try QueryValueJSONDecoder().decode(#"{"$type":"jsonb","value":{"kind":"object","value":\#(members)}}"#)
            }
        }
    }

    @Test("SQL arrays preserve dimensions, lower bounds, NULL cells, and empty element types")
    func arrayShapeIdentity() throws {
        let value = QueryValue.array(try QueryArrayValue(
            elementType: .integer,
            dimensions: [QueryArrayDimension(lowerBound: -3, length: 2), QueryArrayDimension(lowerBound: 5, length: 2)],
            elements: [.primitive(.int32(1)), .primitive(.null), .primitive(.int32(3)), .primitive(.int32(4))],
            limits: queryJSONTestLimits
        ))
        let decoded = try QueryValueJSONDecoder().decode(QueryValueJSONEncoder().encode(value))
        #expect(decoded == value)
        let empty = QueryValue.array(try QueryArrayValue(elementType: .text, dimensions: [], elements: [], limits: queryJSONTestLimits))
        #expect(try QueryValueJSONDecoder().decode(QueryValueJSONEncoder().encode(empty)) == empty)
    }

    @Test("Intervals retain separate signed components at every microsecond boundary")
    func intervalMicrosecondBoundaries() throws {
        for micros: Int64 in [.min, -1_000_001, -1, 0, 1, 1_000_001, .max] {
            let text = #"{"$type":"interval","months":"-2","days":"3","microseconds":"\#(micros)"}"#
            let value = try QueryValueJSONDecoder().decode(text)
            guard case .interval(let interval) = value else {
                Issue.record("Expected an interval")
                return
            }
            #expect(interval.microseconds == micros)
            #expect(interval.period.months == -2)
            #expect(interval.period.days == 3)
            #expect(interval.time.nanoseconds < 1_000_000_000)
            #expect(try QueryValueJSONEncoder().encode(value) == text)
        }
    }

    @Test("Unknown tags and malformed or duplicate members fail explicitly")
    func rejectsMalformedGrammar() {
        for text in [
            "1", #"{"$type":"unknown"}"#, #"{"$type":"numeric","coefficient":"1","scale":"0"}"#,
            #"{"$type":"interval","months":"0","days":"0","microseconds":"0","extra":true}"#,
            #"{"$type":"json","value":"null","value":"true"}"#,
            #"{"$type":"jsonb","value":{"kind":"unknown","value":null}}"#,
            #"{"$type":"jsonb","value":{"kind":"null","value":null}}"#,
        ] {
            expectQueryCLIError(.input) { _ = try QueryValueJSONDecoder().decode(text) }
        }
    }

    @Test("Integer components accept only canonical in-range decimal strings")
    func rejectsNoncanonicalIntegers() {
        for component in ["01", "+1", "-0", "1.0", " 1", "9223372036854775808"] {
            expectQueryCLIError(.input) {
                _ = try QueryValueJSONDecoder().decode(#"{"$type":"interval","months":"0","days":"0","microseconds":"\#(component)"}"#)
            }
        }
        expectQueryCLIError(.input) {
            _ = try QueryValueJSONDecoder().decode(#"{"$type":"numeric","coefficient":1,"scale":"0","displayScale":"0"}"#)
        }
        expectQueryCLIError(.input) {
            _ = try QueryValueJSONDecoder().decode(#"{"$type":"numeric","coefficient":"10","scale":"1","displayScale":"1"}"#)
        }
        for text in [
            #"{"$type":"numeric","coefficient":"170141183460469231731687303715884105728","scale":"0","displayScale":"0"}"#,
            #"{"$type":"numeric","coefficient":"1","scale":"2147483648","displayScale":"0"}"#,
            #"{"$type":"interval","months":"2147483648","days":"0","microseconds":"0"}"#,
        ] {
            expectQueryCLIError(.input) { _ = try QueryValueJSONDecoder().decode(text) }
        }
    }

    @Test("Intrinsic numeric, JSON, array shape, and element type violations are rejected")
    func rejectsInvalidValues() {
        for text in [
            #"{"$type":"numeric","coefficient":"123","scale":"2","displayScale":"1"}"#,
            #"{"$type":"numeric","coefficient":"0","scale":"0","displayScale":"16384"}"#,
            #"{"$type":"numeric","coefficient":"1","scale":"0","displayScale":"-1"}"#,
            #"{"$type":"json","value":"{"}"#,
            #"{"$type":"sqlArray","elementType":{"kind":"sql","type":{"kind":"integer"}},"dimensions":[{"lowerBound":"1","length":"2"}],"elements":[{"$type":"int32","value":"1"}]}"#,
            #"{"$type":"sqlArray","elementType":{"kind":"sql","type":{"kind":"integer"}},"dimensions":[{"lowerBound":"1","length":"1"}],"elements":[{"$type":"string","value":"x"}]}"#,
        ] {
            expectQueryCLIError(.input) { _ = try QueryValueJSONDecoder().decode(text) }
        }
        expectQueryCLIError(.input) {
            _ = try QueryValueJSONDecoder().decode(#"{"$type":"sqlArray","elementType":{"kind":"primitive","type":"string","isArray":false},"dimensions":[],"elements":[]}"#)
        }
    }

    @Test("Decode rejects configured input byte and depth limits")
    func decodeResourceLimits() {
        expectQueryCLIError(.resourceLimit) {
            _ = try QueryValueJSONDecoder(maximumBytes: 8).decode(#"{"$type":"null"}"#)
        }
        expectQueryCLIError(.resourceLimit) {
            _ = try QueryValueJSONDecoder(maximumDepth: 2).decode(#"{"$type":"jsonb","value":{"kind":"array","value":[{"kind":"array","value":[{"kind":"null"}]}]}}"#)
        }
        expectQueryCLIError(.resourceLimit) {
            _ = try QueryValueJSONDecoder(maximumDepth: 2).decode(#"{"$type":"json","value":"[[[0]]]"}"#)
        }
        var descriptor = StrictJSONValue.object([("kind", .string("integer"))])
        for _ in 0..<80 {
            descriptor = .object([("kind", .string("array")), ("element", descriptor)])
        }
        expectQueryCLIError(.resourceLimit) {
            _ = try QueryColumnJSONCodec.type(.object([("kind", .string("sql")), ("type", descriptor)]))
        }
    }

    @Test("Tagged JSON envelope depth preserves the exact semantic depth boundary")
    func semanticDepthBoundaryRoundTrip() throws {
        let limits = QueryValueLimits(maximumRetainedBytes: 1_048_576,
                                      maximumTotalNodes: 10_000,
                                      maximumNestingDepth: 65,
                                      maximumCollectionElements: 10_000)
        let number = try QueryNumericValue(value: ExactDecimal(coefficient: 123, scale: 2), displayScale: 4)
        var reported = QueryJSONBNode.null
        for _ in 0..<32 { reported = try .array([reported], limits: limits) }
        var alternating = QueryJSONBNode.number(number)
        var objects = QueryJSONBNode.number(number)
        for index in 0..<63 {
            alternating = try index.isMultiple(of: 2)
                ? .object([QueryJSONBMember(key: "value", value: alternating)], limits: limits)
                : .array([alternating], limits: limits)
            objects = try .object([QueryJSONBMember(key: "value", value: objects)], limits: limits)
        }
        for (node, depth) in [(reported, UInt64(33)), (alternating, 64), (objects, 64)] {
            let value = QueryValue.jsonb(try QueryJSONBValue(root: node, limits: limits))
            #expect(try QueryValueValidator.measure(value).maximumNestingDepth == depth)
            let encoded = try QueryValueJSONEncoder().encode(value)
            #expect(try QueryValueJSONDecoder().decode(encoded) == value)
        }
        let excessive = QueryValue.jsonb(try QueryJSONBValue(root: .array([alternating], limits: limits), limits: limits))
        #expect(try QueryValueValidator.measure(excessive).maximumNestingDepth == 65)
        #expect(throws: QueryValueError.self) { try QueryValueJSONEncoder().encode(excessive) }
        let encoded = try QueryValueJSONEncoder(maximumDepth: 65).encode(excessive)
        expectQueryCLIError(.resourceLimit) { _ = try QueryValueJSONDecoder().decode(encoded) }

        for invalid in [0, -1] {
            expectQueryCLIError(.resourceLimit) {
                _ = try QueryValueJSONDecoder(maximumBytes: invalid).decode(#"{"$type":"null"}"#)
            }
            expectQueryCLIError(.resourceLimit) {
                _ = try QueryValueJSONDecoder(maximumDepth: invalid).decode(#"{"$type":"null"}"#)
            }
            expectQueryCLIError(.resourceLimit) {
                _ = try QueryValueJSONEncoder(maximumOutputBytes: invalid).encode(.primitive(.null))
            }
            expectQueryCLIError(.resourceLimit) {
                _ = try QueryValueJSONEncoder(maximumDepth: invalid).encode(.primitive(.null))
            }
        }
        expectQueryCLIError(.resourceLimit) {
            _ = try QueryValueJSONDecoder(maximumDepth: .max).decode(#"{"$type":"null"}"#)
        }
    }

    @Test("Encode rejects output byte and intrinsic nesting limits")
    func encodeResourceLimits() throws {
        expectQueryCLIError(.resourceLimit) {
            _ = try QueryValueJSONEncoder(maximumOutputBytes: 1).encode(.primitive(.null))
        }
        let nested = QueryValue.jsonb(try QueryJSONBValue(root: .array([.array([.null], limits: queryJSONTestLimits)], limits: queryJSONTestLimits), limits: queryJSONTestLimits))
        #expect(throws: QueryValueError.self) {
            try QueryValueJSONEncoder(maximumDepth: 1).encode(nested)
        }
    }

    @Test("Output value resource failures map to the resource exit code")
    func outputResourceFailureClassification() throws {
        let nested = QueryValue.jsonb(try QueryJSONBValue(root: .array([.array([.null], limits: queryJSONTestLimits)], limits: queryJSONTestLimits), limits: queryJSONTestLimits))
        do {
            _ = try QueryValueJSONEncoder(maximumDepth: 1).encode(nested)
            Issue.record("Nested output exceeded its depth limit without failing")
        } catch let error as QueryValueError {
            guard case .resourceLimit = error else {
                Issue.record("Expected an intrinsic resource limit, received \(error)")
                return
            }
            #expect(DatabaseCLIError.map(error).exitCode == .resourceLimit)
        }
        #expect(DatabaseCLIError.map(QueryValueError.incompatibleType).exitCode == .internalFailure)
    }

    @Test("Structured parameters retain declared types for NULL and empty SQL arrays")
    func typedParameters() throws {
        let nullType = QueryColumnType.sql(.decimal(precision: 10, scale: 4))
        let arrayType = QueryColumnType.sql(.array(.integer))
        let array = QueryValue.array(try QueryArrayValue(elementType: .integer, dimensions: [], elements: [], limits: queryJSONTestLimits))
        let specification = StrictJSONWriter.encode(.array([
            .object([("position", .string("1")), ("name", .string("amount")),
                     ("value", .object([("$type", .string("null"))])), ("type", try QueryColumnJSONCodec.typeNode(nullType))]),
            .object([("position", .string("2")), ("value", try QueryValueJSONEncoder().node(array)),
                     ("type", try QueryColumnJSONCodec.typeNode(arrayType))]),
            .object([("position", .string("3")), ("value", .object([("$type", .string("null"))])), ("type", .null)]),
            .object([("position", .string("4")), ("value", .object([("$type", .string("null"))]))]),
        ]))
        var arguments = ["query", "sql", "SELECT 1", "--parameters", specification]
        #if DATABASE_CLI_MULTI_BASE
        arguments += ["--base", "company-a"]
        #endif
        let command = try CommandParser().parse(arguments)
        let parameters = try WireRequestBuilder().parameters(command.options)
        #expect(parameters == [
            QueryParameter(position: 1, name: "amount", value: .primitive(.null), type: nullType),
            QueryParameter(position: 2, value: array, type: arrayType),
            QueryParameter(position: 3, value: .primitive(.null)),
            QueryParameter(position: 4, value: .primitive(.null)),
        ])
    }

    @Test("Structured parameters reject incompatible declarations and unknown members")
    func rejectsInvalidParameters() throws {
        for specification in [
            #"[{"position":"1","value":{"$type":"string","value":"x"},"type":{"kind":"sql","type":{"kind":"integer"}}}]"#,
            #"[{"position":"1","value":{"$type":"null"},"extra":true}]"#,
        ] {
            var arguments = ["query", "sql", "SELECT 1", "--parameters", specification]
            #if DATABASE_CLI_MULTI_BASE
            arguments += ["--base", "company-a"]
            #endif
            let command = try CommandParser().parse(arguments)
            expectQueryCLIError(.input) { _ = try WireRequestBuilder().parameters(command.options) }
        }
        expectQueryCLIError(.input) {
            _ = try QueryColumnJSONCodec.type(StrictJSONParser().parse(#"{"kind":"sql","type":{"kind":"unknown"}}"#))
        }
    }
}

private func expectQueryCLIError(_ expected: DatabaseCLIExitCode, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("Expected CLI failure with exit code \(expected)")
    } catch let error as DatabaseCLIError {
        #expect(error.exitCode == expected)
    } catch {
        Issue.record("Expected a CLI boundary error, received \(error)")
    }
}
