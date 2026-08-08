import DatabaseTypes
import Foundation

public struct FieldValueJSONEncoder: Sendable {
    public let maximumOutputBytes: Int

    public init(maximumOutputBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func encode(_ value: FieldValue) throws -> String {
        let output = StrictJSONWriter.encode(try node(value))
        guard output.utf8.count <= maximumOutputBytes else {
            throw DatabaseCLIError(
                .resourceLimit,
                "Encoded FieldValue exceeds \(maximumOutputBytes) bytes"
            )
        }
        return output
    }

    func node(_ value: FieldValue) throws -> StrictJSONValue {
        switch value {
        case .null: tagged("null")
        case .bool(let value): tagged("bool", "value", .bool(value))
        case .int8(let value): integer("int8", value)
        case .int16(let value): integer("int16", value)
        case .int32(let value): integer("int32", value)
        case .int64(let value): integer("int64", value)
        case .uint8(let value): integer("uint8", value)
        case .uint16(let value): integer("uint16", value)
        case .uint32(let value): integer("uint32", value)
        case .uint64(let value): integer("uint64", value)
        case .float32(let value):
            tagged("float32", "bits", .string(hex(value.bitPattern, digits: 8)))
        case .float64(let value):
            tagged("float64", "bits", .string(hex(value.bitPattern, digits: 16)))
        case .decimal(let value):
            tagged(
                "decimal",
                "value",
                .string(
                    try value.decimalLexicalForm(
                        maximumUTF8Count: maximumOutputBytes
                    )
                )
            )
        case .string(let value): tagged("string", "value", .string(value))
        case .bytes(let value):
            tagged("bytes", "value", .string(Base64URL.encode(value)))
        case .date(let value):
            .object([
                ("$type", .string("date")),
                ("year", .string(String(value.year))),
                ("month", .string(String(value.month))),
                ("day", .string(String(value.day))),
            ])
        case .time(let value): timeNode(value)
        case .dateTime(let value):
            .object([
                ("$type", .string("dateTime")),
                ("date", try node(.date(value.date))),
                ("time", try node(.time(value.time))),
            ])
        case .timestamp(let value):
            .object([
                ("$type", .string("timestamp")),
                ("seconds", .string(String(value.secondsSinceUnixEpoch))),
                ("nanoseconds", .string(String(value.nanoseconds))),
            ])
        case .timeSpan(let value):
            .object([
                ("$type", .string("timeSpan")),
                ("seconds", .string(String(value.seconds))),
                ("nanoseconds", .string(String(value.nanoseconds))),
            ])
        case .calendarPeriod(let value):
            .object([
                ("$type", .string("calendarPeriod")),
                ("months", .string(String(value.months))),
                ("days", .string(String(value.days))),
            ])
        case .geographicPoint(let value):
            .object([
                ("$type", .string("geographicPoint")),
                ("latitudeBits", .string(hex(value.latitude.bitPattern, digits: 16))),
                ("longitudeBits", .string(hex(value.longitude.bitPattern, digits: 16))),
            ])
        case .geographicPosition(let value):
            .object([
                ("$type", .string("geographicPosition")),
                ("latitudeBits", .string(hex(value.point.latitude.bitPattern, digits: 16))),
                ("longitudeBits", .string(hex(value.point.longitude.bitPattern, digits: 16))),
                ("heightBits", .string(hex(value.ellipsoidalHeightInMeters.bitPattern, digits: 16))),
            ])
        case .vector(let value): try vectorNode(value)
        case .uuid(let value): tagged("uuid", "value", .string(value.description))
        case .array(let values):
            tagged("array", "value", .array(try values.map(node)))
        case .object(let value):
            tagged(
                "object",
                "value",
                .object(
                    try value.fields.map { field in
                        (field.key, try node(field.value))
                    }
                )
            )
        case .reference(let value): try referenceNode(value)
        case .rdfTerm(let value):
            tagged("rdfTerm", "value", try rdfTermNode(value))
        }
    }
}

private extension FieldValueJSONEncoder {
    func tagged(_ type: String) -> StrictJSONValue {
        .object([("$type", .string(type))])
    }

    func tagged(
        _ type: String,
        _ name: String,
        _ value: StrictJSONValue
    ) -> StrictJSONValue {
        .object([("$type", .string(type)), (name, value)])
    }

    func integer<T: FixedWidthInteger>(
        _ type: String,
        _ value: T
    ) -> StrictJSONValue {
        tagged(type, "value", .string(String(value)))
    }

    func hex<T: FixedWidthInteger>(_ value: T, digits: Int) -> String {
        let raw = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: digits - raw.count) + raw
    }

    func timeNode(_ value: CivilTime) -> StrictJSONValue {
        .object([
            ("$type", .string("time")),
            ("hour", .string(String(value.hour))),
            ("minute", .string(String(value.minute))),
            ("second", .string(String(value.second))),
            ("nanoseconds", .string(String(value.nanoseconds))),
        ])
    }

    func vectorNode(_ value: Vector) throws -> StrictJSONValue {
        let values: [StrictJSONValue]
        let elementType: String
        switch value.elementType {
        case .int8:
            elementType = "int8"
            values = try requireVectorStorage(
                value.withInt8Elements { $0.map { .string(String($0)) } }
            )
        case .int16:
            elementType = "int16"
            values = try requireVectorStorage(
                value.withInt16Elements { $0.map { .string(String($0)) } }
            )
        case .int32:
            elementType = "int32"
            values = try requireVectorStorage(
                value.withInt32Elements { $0.map { .string(String($0)) } }
            )
        case .int64:
            elementType = "int64"
            values = try requireVectorStorage(
                value.withInt64Elements { $0.map { .string(String($0)) } }
            )
        case .uint8:
            elementType = "uint8"
            values = try requireVectorStorage(
                value.withUInt8Elements { $0.map { .string(String($0)) } }
            )
        case .uint16:
            elementType = "uint16"
            values = try requireVectorStorage(
                value.withUInt16Elements { $0.map { .string(String($0)) } }
            )
        case .uint32:
            elementType = "uint32"
            values = try requireVectorStorage(
                value.withUInt32Elements { $0.map { .string(String($0)) } }
            )
        case .uint64:
            elementType = "uint64"
            values = try requireVectorStorage(
                value.withUInt64Elements { $0.map { .string(String($0)) } }
            )
        case .float32:
            elementType = "float32"
            values = try requireVectorStorage(value.withFloat32Elements {
                $0.map { .string(hex($0.bitPattern, digits: 8)) }
            })
        case .float64:
            elementType = "float64"
            values = try requireVectorStorage(value.withFloat64Elements {
                $0.map { .string(hex($0.bitPattern, digits: 16)) }
            })
        }
        guard values.count == value.count else {
            throw DatabaseCLIError(.internalFailure, "Vector storage type mismatch")
        }
        return .object([
            ("$type", .string("vector")),
            ("elementType", .string(elementType)),
            ("values", .array(values)),
        ])
    }

    func requireVectorStorage(
        _ values: [StrictJSONValue]?
    ) throws -> [StrictJSONValue] {
        guard let values else {
            throw DatabaseCLIError(
                .internalFailure,
                "Vector storage does not match its declared element type"
            )
        }
        return values
    }

    func referenceNode(_ value: EntityReference) throws -> StrictJSONValue {
        .object([
            ("$type", .string("reference")),
            ("entity", .string(value.entity)),
            ("id", referenceIdentifierNode(value.id)),
            ("partitions", try node(.object(value.partitions))),
        ])
    }

    func referenceIdentifierNode(
        _ value: ReferenceIdentifier
    ) -> StrictJSONValue {
        let kind: String
        let node: StrictJSONValue
        switch value {
        case .bool(let value): kind = "bool"; node = .bool(value)
        case .int8(let value): kind = "int8"; node = .string(String(value))
        case .int16(let value): kind = "int16"; node = .string(String(value))
        case .int32(let value): kind = "int32"; node = .string(String(value))
        case .int64(let value): kind = "int64"; node = .string(String(value))
        case .uint8(let value): kind = "uint8"; node = .string(String(value))
        case .uint16(let value): kind = "uint16"; node = .string(String(value))
        case .uint32(let value): kind = "uint32"; node = .string(String(value))
        case .uint64(let value): kind = "uint64"; node = .string(String(value))
        case .string(let value): kind = "string"; node = .string(value)
        case .bytes(let value): kind = "bytes"; node = .string(Base64URL.encode(value))
        case .uuid(let value): kind = "uuid"; node = .string(value.description)
        case .composite(let values):
            kind = "composite"
            node = .array(values.map(referenceIdentifierNode))
        }
        return .object([("kind", .string(kind)), ("value", node)])
    }

    func rdfTermNode(_ value: RDFTerm) throws -> StrictJSONValue {
        switch value {
        case .iri(let value):
            .object([("kind", .string("iri")), ("value", .string(value.rawValue))])
        case .blankNode(let value):
            .object([("kind", .string("blankNode")), ("value", .string(value.rawValue))])
        case .literal(let value):
            try rdfLiteralNode(value)
        case .tripleTerm(let subject, let predicate, let object):
            .object([
                ("kind", .string("tripleTerm")),
                ("subject", try rdfTermNode(subject.term)),
                ("predicate", .string(predicate.rawValue)),
                ("object", try rdfTermNode(object)),
            ])
        }
    }

    func rdfLiteralNode(_ value: RDFLiteral) throws -> StrictJSONValue {
        var fields: [(key: String, value: StrictJSONValue)] = [
            ("kind", .string("literal")),
            ("lexicalForm", .string(value.lexicalForm)),
        ]
        switch value.annotation {
        case .typed(let datatype):
            fields.append(("datatype", .string(datatype.rawValue)))
        case .languageTagged(let language):
            fields.append(("language", .string(language.rawValue)))
        case .directionalLanguageTagged(let language, let direction):
            fields.append(("language", .string(language.rawValue)))
            fields.append(("direction", .string(direction.rawValue)))
        }
        return .object(fields)
    }
}
