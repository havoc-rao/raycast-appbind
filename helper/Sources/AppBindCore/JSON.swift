import Foundation

// JSONSerialization on macOS can strip a leading U+FEFF from a string value.
// Decode via Codable so validation sees the exact user string, not a repaired one.
private enum JSONValue: Decodable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .number(try container.decode(Double.self)) }
    }
    var value: Any {
        switch self {
        case .object(let object): return object.mapValues(\.value)
        case .array(let array): return array.map(\.value)
        case .string(let string): return string
        case .number(let number): return NSNumber(value: number)
        case .bool(let bool): return NSNumber(value: bool)
        case .null: return NSNull()
        }
    }
}
func decodeJSON(_ data: Data) throws -> Any { try JSONDecoder().decode(JSONValue.self, from: data).value }
