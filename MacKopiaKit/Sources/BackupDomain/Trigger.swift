import Foundation

public enum Trigger: Codable, Sendable, Hashable {
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int, weekdays: Set<Weekday>)
    case onVolumeMount, onNetworkReachable, manual

    public func validate() throws {
        switch self {
        case .interval(let minutes):
            guard minutes > 0, minutes <= Int.max / 60 else { throw DomainValidationError.invalidPlan }
        case .daily(let hour, let minute, let weekdays):
            guard (0...23).contains(hour), (0...59).contains(minute), !weekdays.isEmpty else {
                throw DomainValidationError.invalidPlan
            }
        default: break
        }
    }

    private enum Payload: Codable {
        case interval(minutes: Int)
        case daily(hour: Int, minute: Int, weekdays: Set<Weekday>)
        case onVolumeMount, onNetworkReachable, manual
    }

    public init(from decoder: any Decoder) throws {
        switch try Payload(from: decoder) {
        case .interval(let minutes): self = .interval(minutes: minutes)
        case .daily(let hour, let minute, let weekdays): self = .daily(hour: hour, minute: minute, weekdays: weekdays)
        case .onVolumeMount: self = .onVolumeMount
        case .onNetworkReachable: self = .onNetworkReachable
        case .manual: self = .manual
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        let payload: Payload
        switch self {
        case .interval(let minutes): payload = .interval(minutes: minutes)
        case .daily(let hour, let minute, let weekdays):
            payload = .daily(hour: hour, minute: minute, weekdays: weekdays)
        case .onVolumeMount: payload = .onVolumeMount
        case .onNetworkReachable: payload = .onNetworkReachable
        case .manual: payload = .manual
        }
        try payload.encode(to: encoder)
    }
}
