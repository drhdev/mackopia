import BackupDomain
import Foundation

/// Calendar arithmetic stays separate from monotonic sleeping so wall-clock changes can be reconciled.
package enum ScheduleCalculation {
    package static func next(
        trigger: Trigger, after date: Date, calendar: Calendar, jitterSeconds: Double
    ) -> Date? {
        switch trigger {
        case .interval(let minutes):
            let jitter = jitterSeconds.isFinite ? min(60, max(-60, jitterSeconds)) : 0
            let result = date.addingTimeInterval(max(1, Double(minutes) * 60 + jitter))
            return result > date && result <= .distantFuture ? result : nil
        case .daily(let hour, let minute, let weekdays):
            return weekdays.compactMap { weekday in
                calendar.nextDate(
                    after: date,
                    matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: number(weekday)),
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            }.min()
        default: return nil
        }
    }

    private static func number(_ weekday: Weekday) -> Int {
        switch weekday {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}
