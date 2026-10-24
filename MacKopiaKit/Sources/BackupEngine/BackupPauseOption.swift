import BackupDomain
import Foundation

package enum BackupPauseOption: Sendable {
    case oneHour, untilTomorrowMorning, indefinite

    /// Calendar math preserves 08:00 across 23/25-hour days; the chosen date then stays absolute.
    package func deadline(after date: Date, calendar: Calendar = .current) throws -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite, date >= .distantPast, date <= .distantFuture else {
            throw DomainValidationError.invalidPlan
        }
        let result: Date?
        switch self {
        case .indefinite: return nil
        case .oneHour: result = date.addingTimeInterval(3600)
        case .untilTomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else {
                throw DomainValidationError.invalidPlan
            }
            result = calendar.date(
                bySettingHour: 8, minute: 0, second: 0, of: calendar.startOfDay(for: tomorrow),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }
        guard let result, result > date, result <= .distantFuture else { throw DomainValidationError.invalidPlan }
        return result
    }
}
