import BackupDomain
import Foundation
import Testing

@testable import BackupEngine
@testable import KopiaServer

struct BackupProgressEstimatorTests {
    @Test func directoryReachesProgressWithoutAppearingInReflection() throws {
        var estimator = BackupProgressEstimator()
        let directory = "/private-source-marker"
        let upload = try JSONDecoder().decode(
            KopiaSourceStatus.Upload.self,
            from: JSONSerialization.data(withJSONObject: ["directory": directory]))
        let value = estimator.progress(planID: UUID(), sourceID: UUID(), upload: upload, elapsed: .zero)
        #expect(value.directory == directory)
        #expect(value.fractionCompleted == nil)
        #expect(!String(reflecting: upload).contains(directory))
        #expect(!String(reflecting: value).contains(directory))
        #expect(try JSONDecoder().decode(BackupProgress.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func cachedBytesCountWithoutUploadsAndEtaWaitsForStableObservations() throws {
        var estimator = BackupProgressEstimator()
        let plan = UUID()
        let source = UUID()
        for time in 0...30 {
            let upload = try JSONDecoder().decode(
                KopiaSourceStatus.Upload.self,
                from: JSONSerialization.data(withJSONObject: [
                    "hashedBytes": time * 100, "cachedBytes": time * 100, "uploadedBytes": 0, "estimatedBytes": 10_000,
                ]))
            let value = estimator.progress(planID: plan, sourceID: source, upload: upload, elapsed: .seconds(time))
            #expect(value.fractionCompleted == Double(time * 200) / 10_000)
            #expect(value.uploadedBytes == 0)
            if time < 15 {
                #expect(value.remainingSeconds == nil)
            } else {
                #expect(value.remainingSeconds == Double(10_000 - time * 200) / 200)
            }
        }
    }

    @Test func missingOrInvalidCountersResetEstimatesAndNeverOverflow() throws {
        var estimator = BackupProgressEstimator()
        let plan = UUID()
        let source = UUID()
        let upload = try JSONDecoder().decode(
            KopiaSourceStatus.Upload.self,
            from: Data(
                #"{"hashedBytes":9223372036854775807,"cachedBytes":9223372036854775807,"estimatedBytes":1}"#.utf8))
        #expect(
            estimator.progress(planID: plan, sourceID: source, upload: upload, elapsed: .zero).fractionCompleted == 1)
        let invalid = try JSONDecoder().decode(KopiaSourceStatus.Upload.self, from: Data(#"{"hashedBytes":-1}"#.utf8))
        let value = estimator.progress(planID: plan, sourceID: source, upload: invalid, elapsed: .seconds(20))
        #expect(value.hashedBytes == nil)
        #expect(value.fractionCompleted == nil)
        #expect(value.bytesPerSecond == nil)
        #expect(value.remainingSeconds == nil)
    }
}
