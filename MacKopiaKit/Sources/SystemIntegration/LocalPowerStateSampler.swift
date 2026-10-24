import Foundation
import IOKit.ps

/// Reads one fresh IOKit snapshot; the continuous monitor uses the same conservative decoder.
package actor LocalPowerStateSampler: PowerStateSampling {
    package init() {}

    package func samplePower() async throws -> PowerStateObservation {
        try Task.checkCancellation()
        let result = Self.read()
        try Task.checkCancellation()
        return result
    }

    static func read() -> PowerStateObservation {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerStateObservation(onACPower: nil, sources: nil, lowPowerMode: lowPower)
        }
        let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let onAC: Bool? =
            switch type {
            case kIOPMACPowerKey: true
            case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: false
            default: nil
            }
        let handles = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        let readings = handles?.map { handle -> PowerSourceReading in
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, handle)?.takeUnretainedValue()
                    as? [String: Any]
            else { return PowerSourceReading(kind: .unknown, current: nil, maximum: nil, isPresent: nil) }
            let kind: PowerSourceReading.Kind =
                switch description[kIOPSTypeKey] as? String {
                case kIOPSInternalBatteryType: .internalBattery
                case kIOPSUPSType: .ups
                default: .unknown
                }
            return PowerSourceReading(
                kind: kind, current: Self.integer(description[kIOPSCurrentCapacityKey]),
                maximum: Self.integer(description[kIOPSMaxCapacityKey]),
                isPresent: description[kIOPSIsPresentKey] as? Bool)
        }
        return PowerStateObservation(onACPower: onAC, sources: readings, lowPowerMode: lowPower)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number)
        else { return nil }
        return Int(exactly: number.int64Value)
    }
}
