//
//  RewardCalculator.swift
//  HealthKitExample2
//
//  coins(epoch) = (steps/1000 × rate[activity] + verifiedKm × coinsPerKm) × trust × multiplier
//  then daily step cap and daily coin cap are applied in epoch order.
//

import Foundation

nonisolated struct EpochReward: Codable, Hashable, Sendable {
    var index: Int
    var steps: Int
    var coins: Double
}

nonisolated struct RewardBreakdown: Codable, Hashable, Sendable {
    var totalSteps: Int
    var rewardedSteps: Int
    var verifiedDistance: Double
    var validEpochs: Int
    var invalidEpochs: Int
    var stepCoins: Double
    var distanceCoins: Double
    var grossCoins: Double
    var coins: Double
    var cappedBy: [FlagCode]
    var perEpoch: [EpochReward]

    static let zero = RewardBreakdown(totalSteps: 0, rewardedSteps: 0, verifiedDistance: 0, validEpochs: 0,
                                      invalidEpochs: 0, stepCoins: 0, distanceCoins: 0, grossCoins: 0, coins: 0,
                                      cappedBy: [], perEpoch: [])
}

nonisolated enum RewardCalculator {
    static func calculate(epochs: [Epoch], result: VerificationResult, config: RewardConfig,
                          todayCoins: Double = 0, todaySteps: Int = 0) -> RewardBreakdown {
        let reward = config.reward
        var remainingSteps = max(0, config.limits.dailyStepCap - todaySteps)
        var stepCoins = 0.0
        var distanceCoins = 0.0
        var rewardedSteps = 0
        var verifiedDistance = 0.0
        var capped: [FlagCode] = []
        var perEpoch: [EpochReward] = []

        let verdicts = Dictionary(uniqueKeysWithValues: result.verdicts.map { ($0.index, $0) })
        for epoch in epochs.sorted(by: { $0.index < $1.index }) {
            guard let v = verdicts[epoch.index], v.valid, v.rewardSteps > 0 || v.verifiedDistance > 0 else {
                perEpoch.append(EpochReward(index: epoch.index, steps: 0, coins: 0))
                continue
            }
            let steps = min(v.rewardSteps, remainingSteps)
            if steps < v.rewardSteps, !capped.contains(.dailyStepCap) { capped.append(.dailyStepCap) }
            remainingSteps -= steps
            let distance = v.rewardSteps > 0 ? v.verifiedDistance * Double(steps) / Double(v.rewardSteps) : 0
            let rate = v.activity == .running ? reward.coinsPer1000StepsRunning : reward.coinsPer1000StepsWalking
            let factor = v.trust * v.multiplier
            let sc = Double(steps) / 1000 * rate * factor
            let dc = distance / 1000 * reward.coinsPerVerifiedKm * factor
            stepCoins += sc
            distanceCoins += dc
            rewardedSteps += steps
            verifiedDistance += distance
            perEpoch.append(EpochReward(index: epoch.index, steps: steps, coins: round(sc + dc, reward.decimals)))
        }

        let gross = stepCoins + distanceCoins
        let remainingCoins = max(0, config.limits.dailyCoinCap - todayCoins)
        var coins = gross
        if gross > remainingCoins {
            coins = remainingCoins
            capped.append(.dailyCoinCap)
        }
        return RewardBreakdown(totalSteps: epochs.reduce(0) { $0 + $1.steps }, rewardedSteps: rewardedSteps,
                               verifiedDistance: verifiedDistance, validEpochs: result.validEpochs,
                               invalidEpochs: result.verdicts.count - result.validEpochs,
                               stepCoins: round(stepCoins, reward.decimals), distanceCoins: round(distanceCoins, reward.decimals),
                               grossCoins: round(gross, reward.decimals), coins: round(coins, reward.decimals),
                               cappedBy: capped, perEpoch: perEpoch)
    }

    static func round(_ value: Double, _ decimals: Int) -> Double {
        let p = pow(10, Double(max(0, decimals)))
        return (value * p).rounded(.down) / p
    }
}
