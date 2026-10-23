public enum Compression: String, Codable, Sendable, Hashable, CaseIterable {
    case zstd, s2, none
}
