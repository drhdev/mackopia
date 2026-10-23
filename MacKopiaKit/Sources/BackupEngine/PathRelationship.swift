import Foundation

/// Component boundaries matter: /Source and /Source-archive are independent directories.
enum PathRelationship {
    static func overlaps(_ lhs: String, _ rhs: String, caseSensitive: Bool = true) -> Bool {
        let left = lhs.split(separator: "/")
        let right = rhs.split(separator: "/")
        return zip(left, right).allSatisfy { a, b in
            if caseSensitive { return a == b }
            return String(a).compare(
                String(b), options: .caseInsensitive,
                locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }
    }
}
