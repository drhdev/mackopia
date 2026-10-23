import BackupDomain
import Foundation
import Testing

struct BackupPlanTests {
    private func repository(id: UUID = UUID()) throws -> Repository {
        try Repository(
            id: id, name: "Test", kind: .filesystem(path: "/Test", volume: nil),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test"), secretRef: SecretRef())
    }

    private func source(path: String = "/Source", volumeID: UUID = UUID()) throws -> BackupSource {
        try BackupSource(
            path: path,
            volume: VolumeIdentity(
                uuid: volumeID.uuidString, name: "Test",
                isRemovable: false, isNetwork: false))
    }

    private func plan(
        id: UUID = UUID(), repositoryID: UUID = UUID(), sources: [BackupSource]? = nil,
        triggers: [Trigger] = [.manual], enabled: Bool = true, name: String = "Test"
    ) throws -> BackupPlan {
        try BackupPlan(
            id: id, name: name, isEnabled: enabled, repositoryID: repositoryID,
            sources: sources ?? [source()], triggers: triggers,
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: true,
                skipOnConstrainedNetwork: true), retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: true, ignoreCacheDirs: true),
            options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        #expect(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) == value)
    }

    private func rejectMutation<T: Codable>(_ value: T, field: String, replacement: Any) throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json[field] = replacement
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(T.self, from: data) }
    }

    @Test func planRoundTripPreservesIDsUnicodeAndDefaults() throws {
        let original = try plan(sources: [source(path: "/Quelle ü + & ? # %2F")])
        try roundTrip(original)
        #expect(original.conditions.catchUpMissedRuns)
        #expect(original.excludes.oneFileSystem)
        #expect(original.options.compression == .zstd)
        #expect(original.health.warnAfter == .seconds(3 * 86_400))
        #expect(original.health.criticalAfter == .seconds(7 * 86_400))
    }

    @Test func everyTriggerRoundTripsAndRejectsInvalidTimesBeforeEncoding() throws {
        let valid: [Trigger] = [
            .interval(minutes: 1), .daily(hour: 0, minute: 0, weekdays: [.monday]),
            .daily(hour: 23, minute: 59, weekdays: Set(Weekday.allCases)), .onVolumeMount, .onNetworkReachable, .manual,
        ]
        for trigger in valid { try roundTrip(trigger) }
        for trigger: Trigger in [
            .interval(minutes: 0), .interval(minutes: -1), .interval(minutes: Int.max),
            .daily(hour: 24, minute: 0, weekdays: [.monday]), .daily(hour: -1, minute: 0, weekdays: [.monday]),
            .daily(hour: 12, minute: 60, weekdays: [.monday]), .daily(hour: 12, minute: -1, weekdays: [.monday]),
            .daily(hour: 12, minute: 0, weekdays: []),
        ] {
            #expect(throws: DomainValidationError.invalidPlan) { try trigger.validate() }
            #expect(throws: DomainValidationError.invalidPlan) { try JSONEncoder().encode(trigger) }
            #expect(throws: DomainValidationError.invalidPlan) { try plan(triggers: [trigger]) }
        }
        for json in [
            #"{"interval":{"minutes":0}}"#,
            #"{"daily":{"hour":25,"minute":0,"weekdays":["monday"]}}"#,
            #"{"daily":{"hour":12,"minute":0,"weekdays":[]}}"#,
            #"{"daily":{"hour":12,"minute":0,"weekdays":["unknown"]}}"#,
        ] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Trigger.self, from: Data(json.utf8)) }
        }
    }

    @Test func conditionsValidateBatteryAndBoundedSSIDMetadata() throws {
        for battery in [0, 100] {
            let value = try RunConditions(
                requiresACPower: true, minBatteryPercent: battery,
                skipOnExpensiveNetwork: true, skipOnConstrainedNetwork: false, allowedWiFiSSIDs: ["Test ü"],
                catchUpMissedRuns: false)
            try roundTrip(value)
            try rejectMutation(value, field: "minBatteryPercent", replacement: 101)
            try rejectMutation(value, field: "allowedWiFiSSIDs", replacement: ["duplicate", "duplicate"])
        }
        for ssids in [
            [], [""], ["a\0"], [String(repeating: "ü", count: 17)],
            Array(repeating: "a", count: 257),
        ] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try RunConditions(
                    requiresACPower: false, skipOnExpensiveNetwork: false,
                    skipOnConstrainedNetwork: false, allowedWiFiSSIDs: ssids)
            }
        }
        for battery in [-1, 101] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try RunConditions(
                    requiresACPower: false, minBatteryPercent: battery,
                    skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false)
            }
        }
    }

    @Test func retentionPresetsMatchSpecAndCannotMisrepresentCustomCounts() throws {
        for (preset, expected) in [
            (RetentionPreset.balanced, [10, 48, 14, 8, 24, 3]),
            (.spaceSaving, [5, 24, 7, 4, 6, 1]), (.maximum, [20, 72, 60, 26, 60, 10]),
        ] {
            let policy = try RetentionPolicy(preset: preset)
            #expect(
                [
                    policy.keepLatest, policy.keepHourly, policy.keepDaily, policy.keepWeekly,
                    policy.keepMonthly, policy.keepAnnual,
                ] == expected.map(Optional.some))
            try roundTrip(policy)
            try rejectMutation(policy, field: "keepLatest", replacement: 1)
        }
        try roundTrip(RetentionPolicy(keepLatest: 0, keepDaily: 100))
        try roundTrip(RetentionPolicy())
        #expect(throws: DomainValidationError.invalidPlan) { try RetentionPolicy(keepDaily: -1) }
        #expect(throws: DomainValidationError.invalidPlan) { try RetentionPolicy(preset: .custom) }
        try rejectMutation(RetentionPolicy(), field: "keepAnnual", replacement: -1)
    }

    @Test func exclusionRulesPreservePatternsAndRejectMultilineAndOversizeInputs() throws {
        let rules = try ExcludeRules(
            useMacOSDefaults: true, honorTimeMachineExclusions: false, ignoreCacheDirs: true,
            patterns: ["!keep/**", "*.tmp", "Quelle ü/", "# literal"], maxFileSizeMB: 50)
        try roundTrip(rules)
        for patterns in [
            [""], ["bad\nrule"], ["bad\rrule"], ["bad\0rule"],
            [String(repeating: "a", count: 16_385)], Array(repeating: "a", count: 4097),
            Array(repeating: String(repeating: "a", count: 1024), count: 1025),
        ] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try ExcludeRules(
                    useMacOSDefaults: false, honorTimeMachineExclusions: false,
                    ignoreCacheDirs: false, patterns: patterns)
            }
        }
        for size in [0, -1, Int.max] {
            try rejectMutation(rules, field: "maxFileSizeMB", replacement: size)
        }
        try rejectMutation(rules, field: "patterns", replacement: ["a\nb"])
    }

    @Test func performanceOptionsRejectNonfiniteAndOverflowingLimits() throws {
        for compression in Compression.allCases {
            let options = try PlanOptions(
                compression: compression, parallelism: 1, lowPriority: true,
                uploadLimitMbps: 0.5, ejectVolumeAfterBackup: false)
            try roundTrip(options)
            try rejectMutation(options, field: "parallelism", replacement: 0)
            try rejectMutation(options, field: "uploadLimitMbps", replacement: -1)
        }
        for limit in [0, -1, .infinity, -.infinity, .nan, Double.greatestFiniteMagnitude, Double(Int64.max) / 125_000] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try PlanOptions(lowPriority: true, uploadLimitMbps: limit, ejectVolumeAfterBackup: false)
            }
        }
        for parallelism in [0, -1, Int.max] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try PlanOptions(parallelism: parallelism, lowPriority: true, ejectVolumeAfterBackup: false)
            }
        }
    }

    @Test func healthDurationsPreserveSubsecondsAndRejectInvalidOrderingOrRepresentation() throws {
        let value = try HealthThresholds(warnAfter: .nanoseconds(1), criticalAfter: .seconds(1))
        try roundTrip(value)
        for (warning, critical): (Duration, Duration) in [
            (.zero, .seconds(1)),
            (.seconds(-1), .seconds(1)), (.seconds(1), .seconds(1)), (.seconds(2), .seconds(1)),
        ] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try HealthThresholds(warnAfter: warning, criticalAfter: critical)
            }
        }
        for interval in [
            ["seconds": -1, "attoseconds": 1],
            ["seconds": 0, "attoseconds": -1], ["seconds": 0, "attoseconds": 1_000_000_000_000_000_000],
        ] {
            try rejectMutation(value, field: "warnAfter", replacement: interval)
        }
    }

    @Test func plansRequireSourcesDistinctIDsPathsAndTriggers() throws {
        let source = try source()
        #expect(throws: DomainValidationError.invalidPlan) { try plan(sources: []) }
        #expect(throws: DomainValidationError.invalidPlan) { try plan(sources: [source, source]) }
        #expect(throws: DomainValidationError.invalidPlan) { try plan(sources: [source, self.source()]) }
        #expect(throws: DomainValidationError.invalidPlan) { try plan(triggers: []) }
        #expect(throws: DomainValidationError.invalidPlan) { try plan(triggers: [.manual, .manual]) }
        for name in ["", " \n", "bad\0", String(repeating: "a", count: 1025)] {
            #expect(throws: DomainValidationError.invalidPlan) { try plan(name: name) }
        }
        let otherPath = try BackupSource(id: source.id, path: "/Other", volume: source.volume)
        #expect(throws: DomainValidationError.invalidPlan) { try plan(sources: [source, otherPath]) }
        let original = try plan()
        try rejectMutation(original, field: "sources", replacement: [])
        try rejectMutation(original, field: "triggers", replacement: [])
        try rejectMutation(original, field: "name", replacement: "")
    }

    @Test func persistedPlansValidateNestedValuesAndCollectionBounds() throws {
        let original = try plan()
        try rejectMutation(
            original, field: "conditions",
            replacement: [
                "requiresACPower": false,
                "minBatteryPercent": -1, "skipOnExpensiveNetwork": false,
                "skipOnConstrainedNetwork": false, "catchUpMissedRuns": true,
            ])
        try rejectMutation(original, field: "triggers", replacement: [["interval": ["minutes": 0]]])
        let sources = try (0...1024).map { try source(path: "/Source/" + String($0)) }
        #expect(throws: DomainValidationError.invalidPlan) { try plan(sources: sources) }
        let triggers = (1...65).map { Trigger.interval(minutes: $0) }
        #expect(throws: DomainValidationError.invalidPlan) { try plan(triggers: triggers) }
        try roundTrip(plan(sources: Array(sources.prefix(1024)), triggers: Array(triggers.prefix(64))))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["futureField"] = true
        #expect(
            try JSONDecoder().decode(BackupPlan.self, from: JSONSerialization.data(withJSONObject: json)) == original)
    }

    @Test func sameDestinationSourceConflictsEvenWithDifferentVolumeIDsOrDisabledPlan() throws {
        let destination = try repository()
        let first = try plan(repositoryID: destination.id)
        let second = try plan(repositoryID: destination.id, enabled: false)
        #expect(throws: DomainValidationError.sourceConflict) {
            try PlanSetValidator.validate(plans: [first, second], repositories: [destination])
        }
        // A complete prospective set permits an edit replacing the previous value, rather than self-conflicting.
        let replacement = try plan(id: first.id, repositoryID: destination.id, name: "Edited")
        try PlanSetValidator.validate(plans: [replacement], repositories: [destination])
    }

    @Test func differentDestinationsAndLiteralPathsAreIndependentButMissingIDsFail() throws {
        let a = try repository()
        let b = try repository()
        try PlanSetValidator.validate(
            plans: [plan(repositoryID: a.id), plan(repositoryID: b.id)], repositories: [a, b])
        try PlanSetValidator.validate(
            plans: [
                plan(repositoryID: a.id),
                plan(repositoryID: a.id, sources: [source(path: "/Source/Nested")]),
            ], repositories: [a])
        #expect(throws: DomainValidationError.invalidPlan) {
            try PlanSetValidator.validate(plans: [plan()], repositories: [a])
        }
        let first = try plan(repositoryID: a.id)
        #expect(throws: DomainValidationError.invalidPlan) {
            try PlanSetValidator.validate(plans: [first, first], repositories: [a])
        }
        #expect(throws: DomainValidationError.invalidPlan) {
            try PlanSetValidator.validate(plans: [], repositories: [a, a])
        }
    }

    @Test func privatePlanPathsSSIDAndPatternsAreRedacted() throws {
        let marker = UUID().uuidString
        #expect(!String(reflecting: try plan(sources: [source(path: "/" + marker)], name: marker)).contains(marker))
        #expect(
            !String(
                reflecting: try RunConditions(
                    requiresACPower: false, skipOnExpensiveNetwork: false,
                    skipOnConstrainedNetwork: false, allowedWiFiSSIDs: ["PrivateSSID"])
            ).contains("PrivateSSID"))
        #expect(
            !String(
                reflecting: try ExcludeRules(
                    useMacOSDefaults: false, honorTimeMachineExclusions: false,
                    ignoreCacheDirs: false, patterns: [marker])
            ).contains(marker))
    }
}
