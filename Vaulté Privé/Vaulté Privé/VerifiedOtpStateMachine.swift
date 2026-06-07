import Foundation

enum VerifiedOtpStateMachine {
    static func statusForRemainingBytes(
        remainingBytes: Int,
        totalBytes: Int,
        lowCapacityThresholdRatio: Double = 0.15
    ) -> VerifiedOtpBundleStatus {
        guard remainingBytes > 0 else { return .exhausted }
        let ratio = totalBytes > 0 ? Double(remainingBytes) / Double(totalBytes) : 0
        return ratio <= lowCapacityThresholdRatio ? .lowCapacity : .active
    }
}
