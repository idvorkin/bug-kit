import Foundation
import CoreFoundation

/// A JSON value, for the report's `context`: whatever the app wants to attach (EA: exercise and playhead; MM: mode
/// and replay time). Numbers stay numbers, never strings, so `jq` can compare them.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public enum FoundationConversionError: Error, Equatable, Sendable {
    case unsupportedType(String)
    case invalidNumber
  }

  /// Converts JSON-compatible Foundation values without mistaking NSNumber(1) for true.
  /// Unsupported objects, out-of-range integers and non-finite numbers throw rather than lose context silently.
  public init(foundation value: Any) throws {
    if value is NSNull {
      self = .null
    } else if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else if ["f", "d"].contains(String(cString: number.objCType)) {
        guard number.doubleValue.isFinite else { throw FoundationConversionError.invalidNumber }
        self = .double(number.doubleValue)
      } else {
        guard let integer = Int(number.stringValue) else { throw FoundationConversionError.invalidNumber }
        self = .int(integer)
      }
    } else if let string = value as? String {
      self = .string(string)
    } else if let array = value as? [Any] {
      self = .array(try array.map { try JSONValue(foundation: $0) })
    } else if let object = value as? [String: Any] {
      self = .object(try object.mapValues { try JSONValue(foundation: $0) })
    } else {
      throw FoundationConversionError.unsupportedType(String(reflecting: type(of: value)))
    }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? c.decode(Int.self) {
      self = .int(i)
    } else if let d = try? c.decode(Double.self) {
      self = .double(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  /// The Foundation form (`NSNull`, Bool, Int, Double, String, arrays, dictionaries), for an app whose own logger
  /// takes `[String: Any]` for `JSONSerialization` (EA, MM):
  /// `{ type, fields in log.event(type, fields.mapValues(\.foundation)) }`.
  public var foundation: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let a): return a.map(\.foundation)
    case .object(let o): return o.mapValues(\.foundation)
    }
  }

  /// A short text form for the dialog's "Attached automatically" list.
  public var display: String {
    switch self {
    case .null: return "–"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(format: "%.2f", d)
    case .string(let s): return s
    case .array, .object:
      let enc = JSONEncoder()
      enc.outputFormatting = [.sortedKeys]
      return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
