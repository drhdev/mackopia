public enum RetentionPreset: String, Codable, Sendable, Hashable, CaseIterable {
    case balanced, spaceSaving, maximum, custom

    var counts: [Int?]? {
        switch self {
        case .balanced: [10, 48, 14, 8, 24, 3]
        case .spaceSaving: [5, 24, 7, 4, 6, 1]
        case .maximum: [20, 72, 60, 26, 60, 10]
        case .custom: nil
        }
    }
}
