//
//  HealthKitProvider.swift
//  HealthKitExample2
//
//  HealthKit is NOT used as the reward source (any app or the user can write
//  steps into it). It is used to:
//   • cross-check CMPedometer against the iPhone's own HealthKit samples,
//   • detect manually entered / third-party step samples,
//   • wake the app in the background (observer query + background delivery)
//     so pending sessions can be recovered and uploaded.
//

import Foundation
import HealthKit

nonisolated final class HealthKitProvider: @unchecked Sendable {
    static let shared = HealthKitProvider()

    private let store = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let distanceType = HKQuantityType(.distanceWalkingRunning)
    private var observer: HKObserverQuery?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: [], read: [stepType, distanceType])
    }

    /// `true` once the user has been shown the HealthKit sheet (read access is never disclosed).
    func hasRequestedAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: [stepType, distanceType])
        return status == .unnecessary
    }

    static func isAppleDeviceHardware(bundleIdentifier: String) -> Bool {
        let bundleLower = bundleIdentifier.lowercased()
        return bundleLower.hasPrefix("com.apple.health") ||
               bundleLower.hasPrefix("com.apple.coremotion") ||
               bundleLower.hasPrefix("com.apple.fitness")
    }

    func summary(from: Date, to: Date) async -> HealthKitSummary? {
        guard let samples = await fetchStepSamples(from: from, to: to) else { return nil }
        var summary = HealthKitSummary(authorized: true, iPhoneSteps: 0, watchSteps: 0, thirdPartySteps: 0,
                                       manualSteps: 0, thirdPartySources: [])
        var sources = Set<String>()
        for sample in samples {
            let steps = Int(sample.quantity.doubleValue(for: .count()))
            let bundle = sample.sourceRevision.source.bundleIdentifier
            let product = sample.sourceRevision.productType ?? sample.device?.model ?? ""
            if (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) == true {
                summary.manualSteps += steps
            } else if Self.isAppleDeviceHardware(bundleIdentifier: bundle) {
                if product.hasPrefix("Watch") { summary.watchSteps += steps } else { summary.iPhoneSteps += steps }
            } else {
                summary.thirdPartySteps += steps
                sources.insert(sample.sourceRevision.source.name)
            }
        }
        summary.thirdPartySources = sources.sorted()
        return summary
    }

    /// Fetches raw step count samples within a time window for analysis.
    func fetchStepSamples(from: Date, to: Date) async -> [HKQuantitySample]? {
        guard isAvailable else { return nil }
        if !(await hasRequestedAuthorization()) {
            try? await requestAuthorization()
        }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            let query = HKSampleQuery(sampleType: stepType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, results, error in
                continuation.resume(returning: error == nil ? (results as? [HKQuantitySample] ?? []) : nil)
            }
            store.execute(query)
        }
    }

    /// Fetches cumulative step count via HKStatisticsQuery directly from HealthKit database.
    func fetchCumulativeSteps(from: Date, to: Date) async -> Int {
        guard isAvailable else { return 0 }
        if !(await hasRequestedAuthorization()) {
            try? await requestAuthorization()
        }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                guard error == nil, let sum = result?.sumQuantity() else {
                    continuation.resume(returning: 0)
                    return
                }
                continuation.resume(returning: Int(sum.doubleValue(for: .count())))
            }
            store.execute(query)
        }
    }

    /// Wakes the app (even after it was terminated) when new step samples land.
    func enableBackgroundDelivery(onUpdate: @escaping @Sendable () async -> Void) {
        guard isAvailable, observer == nil else { return }
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            Task {
                await onUpdate()
                completion()
            }
        }
        observer = query
        store.execute(query)
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { _, _ in }
    }
}
