import Foundation

/// Comparable JSON values keep the persisted backend allowlist exact, including absent credential fields.
package enum KopiaStorageValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool)
    package init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else {
            self = .string(try value.decode(String.self))
        }
    }
    package func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text);
        case .bool(let flag): try value.encode(flag)
        }
    }
}
