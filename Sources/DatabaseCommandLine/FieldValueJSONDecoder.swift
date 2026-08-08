import DatabaseTypes
import Foundation

public struct FieldValueJSONDecoder: Sendable {
    public let maximumBytes: Int
    public let maximumDepth: Int

    public init(
        maximumBytes: Int = 16 * 1_024 * 1_024,
        maximumDepth: Int = 64
    ) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
    }

    public func decode(_ text: String) throws -> FieldValue {
        let node = try StrictJSONParser(
            maximumBytes: maximumBytes,
            maximumDepth: maximumDepth
        ).parse(text)
        return try decode(node, depth: 0)
    }

    public func decodeObject(_ text: String) throws -> FieldObject {
        let value = try decode(text)
        guard case .object(let object) = value else {
            throw DatabaseCLIError(.input, "Expected a tagged FieldValue object")
        }
        return object
    }

    func decode(_ node: StrictJSONValue, depth: Int) throws -> FieldValue {
        guard depth <= maximumDepth else {
            throw DatabaseCLIError(.resourceLimit, "FieldValue nesting limit exceeded")
        }
        if case .number = node {
            throw DatabaseCLIError(.input, "Untagged JSON numbers are not allowed")
        }
        let object = try StrictJSONObject(node)
        let tag = try object.required("$type").string(named: "$type")
        switch tag {
        case "null":
            try object.validateKeys(["$type"])
            return .null
        case "bool":
            try object.validateKeys(["$type", "value"])
            return .bool(try object.required("value").bool(named: "value"))
        case "int8": return .int8(try integer(object, tag: tag))
        case "int16": return .int16(try integer(object, tag: tag))
        case "int32": return .int32(try integer(object, tag: tag))
        case "int64": return .int64(try integer(object, tag: tag))
        case "uint8": return .uint8(try integer(object, tag: tag))
        case "uint16": return .uint16(try integer(object, tag: tag))
        case "uint32": return .uint32(try integer(object, tag: tag))
        case "uint64": return .uint64(try integer(object, tag: tag))
        case "float32":
            return .float32(try float32(object))
        case "float64":
            return .float64(try float64(object))
        case "decimal":
            try object.validateKeys(["$type", "value"])
            return .decimal(
                try decimal(object.required("value").string(named: "value"))
            )
        case "string":
            try object.validateKeys(["$type", "value"])
            return .string(try object.required("value").string(named: "value"))
        case "bytes":
            try object.validateKeys(["$type", "value"])
            return .bytes(
                try Base64URL.decode(
                    object.required("value").string(named: "value")
                )
            )
        case "date": return .date(try date(object))
        case "time": return .time(try time(object))
        case "dateTime": return .dateTime(try dateTime(object, depth: depth))
        case "timestamp": return .timestamp(try timestamp(object))
        case "timeSpan": return .timeSpan(try timeSpan(object))
        case "calendarPeriod": return .calendarPeriod(try calendarPeriod(object))
        case "geographicPoint": return .geographicPoint(try geographicPoint(object))
        case "geographicPosition":
            return .geographicPosition(try geographicPosition(object))
        case "vector": return .vector(try vector(object))
        case "uuid":
            try object.validateKeys(["$type", "value"])
            let string = try object.required("value").string(named: "value")
            guard let value = DatabaseTypes.UUID(canonicalString: string),
                  value.description == string else {
                throw DatabaseCLIError(.input, "Invalid canonical UUID")
            }
            return .uuid(value)
        case "array":
            try object.validateKeys(["$type", "value"])
            return .array(
                try object.required("value").array(named: "value").map {
                    try decode($0, depth: depth + 1)
                }
            )
        case "object":
            try object.validateKeys(["$type", "value"])
            return .object(try fieldObject(object.required("value"), depth: depth + 1))
        case "reference":
            return .reference(try reference(object, depth: depth + 1))
        case "rdfTerm":
            try object.validateKeys(["$type", "value"])
            return .rdfTerm(try rdfTerm(object.required("value"), depth: depth + 1))
        default:
            throw DatabaseCLIError(.input, "Unknown FieldValue tag '\(tag)'")
        }
    }
}

private extension FieldValueJSONDecoder {
    func integer<T: FixedWidthInteger>(
        _ object: StrictJSONObject,
        tag: String
    ) throws -> T {
        try object.validateKeys(["$type", "value"])
        let string = try object.required("value").string(named: "value")
        guard isCanonicalInteger(string), let value = T(string) else {
            throw DatabaseCLIError(.input, "Invalid \(tag) value")
        }
        return value
    }

    func isCanonicalInteger(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value == "0" { return true }
        let bytes = Array(value.utf8)
        let digits: ArraySlice<UInt8>
        if bytes[0] == 0x2D {
            guard bytes.count > 1, bytes[1] != 0x30 else { return false }
            digits = bytes[1...]
        } else {
            guard bytes[0] != 0x30 else { return false }
            digits = bytes[...]
        }
        return digits.allSatisfy { (0x30...0x39).contains($0) }
    }

    func float32(_ object: StrictJSONObject) throws -> Float {
        try object.validateKeys(["$type", "bits"])
        let bits: UInt32 = try hexadecimalBits(
            object.required("bits").string(named: "bits"),
            digits: 8
        )
        let value = Float(bitPattern: bits)
        guard value.isFinite else {
            throw DatabaseCLIError(.input, "Non-finite float32 is not allowed")
        }
        return value
    }

    func float64(_ object: StrictJSONObject) throws -> Double {
        try object.validateKeys(["$type", "bits"])
        let bits: UInt64 = try hexadecimalBits(
            object.required("bits").string(named: "bits"),
            digits: 16
        )
        let value = Double(bitPattern: bits)
        guard value.isFinite else {
            throw DatabaseCLIError(.input, "Non-finite float64 is not allowed")
        }
        return value
    }

    func hexadecimalBits<T: FixedWidthInteger>(
        _ value: String,
        digits: Int
    ) throws -> T {
        guard value.utf8.count == digits,
              value.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }),
              let result = T(value, radix: 16) else {
            throw DatabaseCLIError(.input, "Invalid fixed-width IEEE bit pattern")
        }
        return result
    }

    func decimal(_ value: String) throws -> ExactDecimal {
        guard !value.isEmpty else {
            throw DatabaseCLIError(.input, "Decimal value is empty")
        }
        var text = value[...]
        let negative = text.first == "-"
        if negative { text = text.dropFirst() }
        guard !text.isEmpty else {
            throw DatabaseCLIError(.input, "Invalid decimal value")
        }
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
              !components[0].isEmpty,
              components.allSatisfy({ part in
                  part.utf8.allSatisfy { (0x30...0x39).contains($0) }
              }) else {
            throw DatabaseCLIError(.input, "Invalid decimal value")
        }
        let fractional = components.count == 2 ? components[1] : Substring()
        guard components.count == 1 || !fractional.isEmpty,
              let scale = Int32(exactly: fractional.utf8.count) else {
            throw DatabaseCLIError(.input, "Invalid decimal scale")
        }
        let digits = String(components[0] + fractional)
        let signedDigits = negative ? "-" + digits : digits
        guard let coefficient = Int128(signedDigits) else {
            throw DatabaseCLIError(.input, "Decimal coefficient is out of range")
        }
        let decimal = ExactDecimal(coefficient: coefficient, scale: scale)
        let canonical = try decimal.decimalLexicalForm(maximumUTF8Count: maximumBytes)
        guard canonical == value else {
            throw DatabaseCLIError(.input, "Decimal value is not canonical")
        }
        return decimal
    }

    func date(_ object: StrictJSONObject) throws -> CivilDate {
        try object.validateKeys(["$type", "year", "month", "day"])
        return try CivilDate(
            year: integerValue(object, "year"),
            month: integerValue(object, "month"),
            day: integerValue(object, "day")
        )
    }

    func time(_ object: StrictJSONObject) throws -> CivilTime {
        try object.validateKeys(["$type", "hour", "minute", "second", "nanoseconds"])
        return try CivilTime(
            hour: integerValue(object, "hour"),
            minute: integerValue(object, "minute"),
            second: integerValue(object, "second"),
            nanoseconds: integerValue(object, "nanoseconds")
        )
    }

    func dateTime(
        _ object: StrictJSONObject,
        depth: Int
    ) throws -> CivilDateTime {
        try object.validateKeys(["$type", "date", "time"])
        guard case .date(let date) = try decode(object.required("date"), depth: depth + 1),
              case .time(let time) = try decode(object.required("time"), depth: depth + 1) else {
            throw DatabaseCLIError(.input, "dateTime requires tagged date and time values")
        }
        return CivilDateTime(date: date, time: time)
    }

    func timestamp(_ object: StrictJSONObject) throws -> Timestamp {
        try object.validateKeys(["$type", "seconds", "nanoseconds"])
        return try Timestamp(
            secondsSinceUnixEpoch: integerValue(object, "seconds"),
            nanoseconds: integerValue(object, "nanoseconds")
        )
    }

    func timeSpan(_ object: StrictJSONObject) throws -> TimeSpan {
        try object.validateKeys(["$type", "seconds", "nanoseconds"])
        return try TimeSpan(
            seconds: integerValue(object, "seconds"),
            nanoseconds: integerValue(object, "nanoseconds")
        )
    }

    func calendarPeriod(_ object: StrictJSONObject) throws -> CalendarPeriod {
        try object.validateKeys(["$type", "months", "days"])
        return CalendarPeriod(
            months: try integerValue(object, "months"),
            days: try integerValue(object, "days")
        )
    }

    func geographicPoint(_ object: StrictJSONObject) throws -> GeographicPoint {
        try object.validateKeys(["$type", "latitudeBits", "longitudeBits"])
        return try GeographicPoint(
            latitude: try doubleBits(object, "latitudeBits"),
            longitude: try doubleBits(object, "longitudeBits")
        )
    }

    func geographicPosition(
        _ object: StrictJSONObject
    ) throws -> GeographicPosition {
        try object.validateKeys([
            "$type", "latitudeBits", "longitudeBits", "heightBits",
        ])
        return try GeographicPosition(
            latitude: doubleBits(object, "latitudeBits"),
            longitude: doubleBits(object, "longitudeBits"),
            ellipsoidalHeightInMeters: doubleBits(object, "heightBits")
        )
    }

    func doubleBits(_ object: StrictJSONObject, _ name: String) throws -> Double {
        let bits: UInt64 = try hexadecimalBits(
            object.required(name).string(named: name),
            digits: 16
        )
        let value = Double(bitPattern: bits)
        guard value.isFinite else {
            throw DatabaseCLIError(.input, "Non-finite coordinate is not allowed")
        }
        return value
    }

    func vector(_ object: StrictJSONObject) throws -> Vector {
        try object.validateKeys(["$type", "elementType", "values"])
        let type = try object.required("elementType").string(named: "elementType")
        let nodes = try object.required("values").array(named: "values")
        let strings = try nodes.map { try $0.string(named: "values[]") }
        switch type {
        case "int8": return Vector(int8: try strings.map(parseInteger))
        case "int16": return Vector(int16: try strings.map(parseInteger))
        case "int32": return Vector(int32: try strings.map(parseInteger))
        case "int64": return Vector(int64: try strings.map(parseInteger))
        case "uint8": return Vector(uint8: try strings.map(parseInteger))
        case "uint16": return Vector(uint16: try strings.map(parseInteger))
        case "uint32": return Vector(uint32: try strings.map(parseInteger))
        case "uint64": return Vector(uint64: try strings.map(parseInteger))
        case "float32":
            return try Vector(float32: strings.map {
                let bits: UInt32 = try hexadecimalBits($0, digits: 8)
                let value = Float(bitPattern: bits)
                guard value.isFinite else {
                    throw DatabaseCLIError(.input, "Non-finite vector value")
                }
                return value
            })
        case "float64":
            return try Vector(float64: strings.map {
                let bits: UInt64 = try hexadecimalBits($0, digits: 16)
                let value = Double(bitPattern: bits)
                guard value.isFinite else {
                    throw DatabaseCLIError(.input, "Non-finite vector value")
                }
                return value
            })
        default:
            throw DatabaseCLIError(.input, "Unknown vector element type '\(type)'")
        }
    }

    func parseInteger<T: FixedWidthInteger>(_ value: String) throws -> T {
        guard isCanonicalInteger(value), let parsed = T(value) else {
            throw DatabaseCLIError(.input, "Invalid vector integer")
        }
        return parsed
    }

    func integerValue<T: FixedWidthInteger>(
        _ object: StrictJSONObject,
        _ name: String
    ) throws -> T {
        try parseInteger(object.required(name).string(named: name))
    }

    func fieldObject(
        _ node: StrictJSONValue,
        depth: Int
    ) throws -> FieldObject {
        guard case .object(let fields) = node else {
            throw DatabaseCLIError(.input, "Tagged object value must be a JSON object")
        }
        return try FieldObject(
            fields.map { field in
                (field.key, try decode(field.value, depth: depth))
            }
        )
    }

    func reference(
        _ object: StrictJSONObject,
        depth: Int
    ) throws -> EntityReference {
        try object.validateKeys(["$type", "entity", "id", "partitions"])
        let partitions: FieldObject
        if let node = object.optional("partitions") {
            guard case .object(let value) = try decode(node, depth: depth) else {
                throw DatabaseCLIError(.input, "Reference partitions must be a tagged object")
            }
            partitions = value
        } else {
            partitions = FieldObject()
        }
        return try EntityReference(
            entity: object.required("entity").string(named: "entity"),
            id: referenceIdentifier(object.required("id"), depth: depth),
            partitions: partitions
        )
    }

    func referenceIdentifier(
        _ node: StrictJSONValue,
        depth: Int
    ) throws -> ReferenceIdentifier {
        guard depth <= maximumDepth else {
            throw DatabaseCLIError(.resourceLimit, "Reference identifier nesting limit exceeded")
        }
        let object = try StrictJSONObject(node)
        try object.validateKeys(["kind", "value"])
        let kind = try object.required("kind").string(named: "kind")
        let value = try object.required("value")
        switch kind {
        case "bool": return .bool(try value.bool(named: "value"))
        case "int8": return .int8(try parseInteger(value.string(named: "value")))
        case "int16": return .int16(try parseInteger(value.string(named: "value")))
        case "int32": return .int32(try parseInteger(value.string(named: "value")))
        case "int64": return .int64(try parseInteger(value.string(named: "value")))
        case "uint8": return .uint8(try parseInteger(value.string(named: "value")))
        case "uint16": return .uint16(try parseInteger(value.string(named: "value")))
        case "uint32": return .uint32(try parseInteger(value.string(named: "value")))
        case "uint64": return .uint64(try parseInteger(value.string(named: "value")))
        case "string": return .string(try value.string(named: "value"))
        case "bytes": return .bytes(try Base64URL.decode(value.string(named: "value")))
        case "uuid":
            let string = try value.string(named: "value")
            guard let uuid = DatabaseTypes.UUID(canonicalString: string) else {
                throw DatabaseCLIError(.input, "Invalid reference UUID")
            }
            return .uuid(uuid)
        case "composite":
            return .composite(
                try value.array(named: "value").map {
                    try referenceIdentifier($0, depth: depth + 1)
                }
            )
        default:
            throw DatabaseCLIError(.input, "Unknown reference identifier kind '\(kind)'")
        }
    }

    func rdfTerm(_ node: StrictJSONValue, depth: Int) throws -> RDFTerm {
        guard depth <= maximumDepth else {
            throw DatabaseCLIError(.resourceLimit, "RDF term nesting limit exceeded")
        }
        let object = try StrictJSONObject(node)
        let kind = try object.required("kind").string(named: "kind")
        switch kind {
        case "iri":
            try object.validateKeys(["kind", "value"])
            return .iri(try RDFIRI(object.required("value").string(named: "value")))
        case "blankNode":
            try object.validateKeys(["kind", "value"])
            return .blankNode(
                try RDFBlankNodeIdentifier(
                    object.required("value").string(named: "value")
                )
            )
        case "literal":
            try object.validateKeys([
                "kind", "lexicalForm", "datatype", "language", "direction",
            ])
            let lexical = try object.required("lexicalForm").string(named: "lexicalForm")
            if let datatype = object.optional("datatype") {
                guard object.optional("language") == nil,
                      object.optional("direction") == nil else {
                    throw DatabaseCLIError(.input, "Typed RDF literal cannot have language")
                }
                return .literal(
                    try RDFLiteral(
                        lexicalForm: lexical,
                        datatype: datatype.string(named: "datatype")
                    )
                )
            }
            let language = try RDFLanguageTag(
                object.required("language").string(named: "language")
            )
            if let direction = object.optional("direction") {
                guard let value = RDFDirection(
                    rawValue: try direction.string(named: "direction")
                ) else {
                    throw DatabaseCLIError(.input, "Invalid RDF base direction")
                }
                return .literal(
                    RDFLiteral(
                        lexicalForm: lexical,
                        language: language,
                        direction: value
                    )
                )
            }
            return .literal(RDFLiteral(lexicalForm: lexical, language: language))
        case "tripleTerm":
            try object.validateKeys(["kind", "subject", "predicate", "object"])
            let subject = try rdfSubject(object.required("subject"), depth: depth + 1)
            let predicate = try RDFPredicateIRI(
                object.required("predicate").string(named: "predicate")
            )
            return .tripleTerm(
                subject: subject,
                predicate: predicate,
                object: try rdfTerm(object.required("object"), depth: depth + 1)
            )
        default:
            throw DatabaseCLIError(.input, "Unknown RDF term kind '\(kind)'")
        }
    }

    func rdfSubject(_ node: StrictJSONValue, depth: Int) throws -> RDFSubject {
        let term = try rdfTerm(node, depth: depth)
        switch term {
        case .iri(let value): return .iri(value)
        case .blankNode(let value): return .blankNode(value)
        case .literal, .tripleTerm:
            throw DatabaseCLIError(.input, "RDF triple subject must be an IRI or blank node")
        }
    }
}
