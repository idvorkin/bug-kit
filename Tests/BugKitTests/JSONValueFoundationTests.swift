import Foundation
import Testing
@testable import BugKit

@Test func foundationContextRoundTripsRecursively() throws {
  let original: JSONValue = .object([
    "null": .null, "bool": .bool(true), "int": .int(1), "double": .double(1.25),
    "string": .string("watch"), "array": .array([.int(-42), .bool(false), .object(["key": .string("value")])])
  ])
  #expect(try JSONValue(foundation: original.foundation) == original)
  let data = try JSONSerialization.data(withJSONObject: original.foundation)
  let parsed = try JSONSerialization.jsonObject(with: data)
  #expect(try JSONValue(foundation: parsed) == original)
}

@Test func numericNSNumbersAreNotBooleans() throws {
  #expect(try JSONValue(foundation: NSNumber(value: 1)) == .int(1))
  #expect(try JSONValue(foundation: NSNumber(value: 0)) == .int(0))
  #expect(try JSONValue(foundation: NSNumber(value: true)) == .bool(true))
  #expect(try JSONValue(foundation: NSNumber(value: false)) == .bool(false))
  #expect(try JSONValue(foundation: NSNumber(value: Int.max)) == .int(Int.max))
  #expect(try JSONValue(foundation: NSNumber(value: Int.min)) == .int(Int.min))
  #expect(try JSONValue(foundation: NSNumber(value: 2.5)) == .double(2.5))
}

@Test func invalidFoundationContextThrowsWithoutDroppingValues() {
  #expect(throws: JSONValue.FoundationConversionError.self) { try JSONValue(foundation: Date()) }
  #expect(throws: JSONValue.FoundationConversionError.self) { try JSONValue(foundation: ["unsupported": Date()]) }
  #expect(throws: JSONValue.FoundationConversionError.self) { try JSONValue(foundation: ["ok", Date()] as [Any]) }
  #expect(throws: JSONValue.FoundationConversionError.self) { try JSONValue(foundation: NSNumber(value: UInt64.max)) }
  #expect(throws: JSONValue.FoundationConversionError.self) { try JSONValue(foundation: Double.infinity) }
  #expect(throws: JSONValue.FoundationConversionError.self) { try JSONValue(foundation: Double.nan) }
  #expect(throws: JSONValue.FoundationConversionError.self) { try JSONValue(foundation: NSDictionary(object: "bad", forKey: NSNumber(value: 3))) }
}
