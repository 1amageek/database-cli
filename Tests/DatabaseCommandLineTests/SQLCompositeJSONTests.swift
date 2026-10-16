import DatabaseKit
import DatabaseTypes
import Testing
@testable import DatabaseCommandLine

@Suite("SQL composite CLI JSON")
struct SQLCompositeJSONTests {
    private let limits = QueryValueLimits(maximumRetainedBytes: 1_048_576,
        maximumTotalNodes: 10_000, maximumNestingDepth: 64, maximumCollectionElements: 10_000)

    @Test func positionalAndNullableValuesRoundTrip() throws {
        let type = try QueryCompositeType(columns: [
            QueryColumn(number: 1, name: "same", type: .sql(.integer), isNullable: true),
            QueryColumn(number: 2, name: "same", type: .primitive(.string), isNullable: true),
        ], limits: limits)
        let composite = QueryValue.composite(try QueryCompositeValue(type: type,
            fields: [.primitive(.int32(7)), .primitive(.null)], limits: limits))
        let allNull = QueryValue.composite(try QueryCompositeValue(type: type,
            fields: [.primitive(.null), .primitive(.null)], limits: limits))
        let array = QueryValue.array(try QueryArrayValue(elementType: .composite(type),
            dimensions: [QueryArrayDimension(lowerBound: -1, length: 2)],
            elements: [composite, .primitive(.null)], limits: limits))
        for value in [composite, allNull, array] {
            let text = try QueryValueJSONEncoder().encode(value)
            #expect(try QueryValueJSONDecoder().decode(text) == value)
            #expect(try QueryValueTextFormatter().format(value) == text)
        }
        #expect(try QueryValueJSONEncoder().encode(allNull) != QueryValueJSONEncoder().encode(.primitive(.null)))
        let zero = QueryValue.composite(try QueryCompositeValue(
            type: QueryCompositeType(columns: [], limits: limits), fields: [], limits: limits))
        #expect(try QueryValueJSONDecoder().decode(QueryValueJSONEncoder().encode(zero)) == zero)
    }

    @Test func malformedCompositeInputFails() {
        for text in [
            #"{"$type":"composite","type":{"kind":"sql","type":{"kind":"integer"}},"fields":[]}"#,
            #"{"$type":"composite","type":{"kind":"sql","type":{"kind":"composite","columns":[]}},"fields":[{"$type":"int32","value":"1"}]}"#,
            #"{"$type":"composite","type":{"kind":"sql","type":{"kind":"composite","columns":[]}},"fields":[],"extra":true}"#,
            #"{"$type":"composite","type":{"kind":"sql","type":{"kind":"composite","columns":[{"number":1,"name":"x","type":{"kind":"sql","type":{"kind":"integer"}},"isNullable":false}]}},"fields":[{"$type":"null"}]}"#,
            #"{"$type":"composite","type":{"kind":"sql","type":{"kind":"composite","columns":[{"number":1,"name":"x","type":{"kind":"sql","type":{"kind":"integer"}},"isNullable":true}]}},"fields":[{"$type":"string","value":"x"}]}"#,
        ] {
            do { _ = try QueryValueJSONDecoder().decode(text); Issue.record("Malformed composite was accepted") }
            catch let error as DatabaseCLIError { #expect(error.exitCode == .input) }
            catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func descriptorAndValueDepthBudgetsAreCumulative() throws {
        var value = QueryValue.primitive(.int32(1))
        var type = QueryColumnType.sql(.integer)
        for _ in 0..<14 {
            let descriptor = try QueryCompositeType(columns: [
                QueryColumn(number: 1, name: "nested", type: type, isNullable: false),
            ], limits: limits)
            value = .composite(try QueryCompositeValue(type: descriptor, fields: [value], limits: limits))
            type = .sql(.composite(descriptor))
        }
        let depth = Int(try QueryValueValidator.measure(value).maximumNestingDepth)
        let encoded = try QueryValueJSONEncoder(maximumDepth: depth).encode(value)
        #expect(try QueryValueJSONDecoder(maximumDepth: depth).decode(encoded) == value)
        expectResourceFailure { _ = try QueryValueJSONEncoder(maximumDepth: depth - 1).encode(value) }
        expectResourceFailure { _ = try QueryValueJSONDecoder(maximumDepth: depth - 1).decode(encoded) }
        guard case .sql(.composite(let nestedType)) = type else {
            Issue.record("Expected a nested composite descriptor")
            return
        }
        let typedNullArray = QueryValue.array(try QueryArrayValue(elementType: .composite(nestedType),
            dimensions: [QueryArrayDimension(lowerBound: -2, length: 2)],
            elements: [value, .primitive(.null)], limits: limits))
        let arrayDepth = Int(try QueryValueValidator.measure(typedNullArray).maximumNestingDepth)
        let arrayText = try QueryValueJSONEncoder(maximumDepth: arrayDepth).encode(typedNullArray)
        #expect(try QueryValueJSONDecoder(maximumDepth: arrayDepth).decode(arrayText) == typedNullArray)
        expectResourceFailure { _ = try QueryValueJSONEncoder(maximumDepth: arrayDepth - 1).encode(typedNullArray) }
        expectResourceFailure { _ = try QueryValueJSONDecoder(maximumDepth: arrayDepth - 1).decode(arrayText) }
        expectResourceFailure { _ = try QueryValueJSONEncoder(maximumOutputBytes: 8).encode(value) }
        expectResourceFailure { _ = try QueryValueJSONDecoder(maximumBytes: 8).decode(encoded) }
        expectResourceFailure { _ = try QueryValueJSONEncoder(maximumOutputBytes: .max).encode(value) }
        expectResourceFailure { _ = try QueryValueJSONDecoder(maximumBytes: .max).decode(encoded) }
    }
    private func expectResourceFailure(_ body: () throws -> Void) {
        do { try body(); Issue.record("Expected a resource limit failure") }
        catch { #expect(DatabaseCLIError.map(error).exitCode == .resourceLimit) }
    }

}
