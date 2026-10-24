import BackupDomain
import Foundation
import KopiaServer

/// A source-local 30-second window, smoothed with EWMA alpha 0.2; ETA waits for 15 seconds of observations.
struct BackupProgressEstimator {
    private var samples: [(time: Double, bytes: Double)] = []
    private var rate: Double?

    mutating func progress(
        planID: UUID, sourceID: UUID, upload: KopiaSourceStatus.Upload, elapsed: Duration
    ) -> BackupProgress {
        let parts = elapsed.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        var remaining: Double?
        if let hashed = upload.hashedBytes, hashed >= 0, let cached = upload.cachedBytes, cached >= 0 {
            let bytes = Double(hashed) + Double(cached)
            if let last = samples.last, seconds <= last.time || bytes < last.bytes {
                samples.removeAll()
                rate = nil
            }
            samples.append((seconds, bytes))
            while samples.count > 2, samples[1].time < seconds - 30 { samples.removeFirst() }
            if let first = samples.first, seconds > first.time {
                let current = (bytes - first.bytes) / (seconds - first.time)
                rate = rate.map { 0.2 * current + 0.8 * $0 } ?? current
                if seconds - first.time >= 15, let estimated = upload.estimatedBytes, estimated > 0,
                    let rate, rate > 0
                {
                    let estimate = max(0, Double(estimated) - bytes) / rate
                    if estimate.isFinite { remaining = estimate }
                }
            }
        } else {
            samples.removeAll()
            rate = nil
        }
        return BackupProgress(
            planID: planID, sourceID: sourceID, hashedBytes: upload.hashedBytes, cachedBytes: upload.cachedBytes,
            uploadedBytes: upload.uploadedBytes, estimatedBytes: upload.estimatedBytes,
            hashedFiles: upload.hashedFiles, cachedFiles: upload.cachedFiles, estimatedFiles: upload.estimatedFiles,
            errors: upload.errors, ignoredErrors: upload.ignoredErrors,
            bytesPerSecond: rate, remainingSeconds: remaining, directory: upload.directory)
    }
}
