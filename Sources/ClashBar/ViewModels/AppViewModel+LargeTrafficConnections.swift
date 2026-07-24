import Foundation

@MainActor
extension AppViewModel {
    private static let largeTrafficRuleTargetPolicyKey = "clashbar.connections.large_traffic.target_policy"
    private static let largeTrafficThresholdBytesKey = "clashbar.connections.large_traffic.threshold_bytes"
    private static let defaultLargeTrafficThresholdBytes: Int64 = 10 * 1024 * 1024
    private static let defaultRuleTargetPolicy = "优质"
    private static let minimumLargeTrafficThresholdBytes: Int64 = 1024
    private static let maximumLargeTrafficThresholdBytes: Int64 = 1024 * 1024 * 1024
    private static let ignoredLargeTrafficPolicyNames: Set<String> = [
        "direct",
        "global",
        "pass",
        "reject",
        "reject-drop",
    ]

    func restoreLargeTrafficRuleTargetPolicy() {
        self.largeTrafficRuleTargetPolicy =
            self.defaults.string(forKey: Self.largeTrafficRuleTargetPolicyKey)?.trimmedNonEmpty
            ?? Self.defaultRuleTargetPolicy
    }

    func restoreLargeTrafficThreshold() {
        let storedBytes = (self.defaults.object(forKey: Self.largeTrafficThresholdBytesKey) as? NSNumber)?.int64Value
        let thresholdBytes = storedBytes ?? Self.defaultLargeTrafficThresholdBytes
        let normalized = Self.normalizedLargeTrafficThresholdBytes(thresholdBytes)
        self.largeTrafficThresholdBytes = normalized
        self.connectionsStore.setLargeTrafficThresholdBytes(normalized)
    }

    func setLargeTrafficRuleTargetPolicy(_ policy: String) {
        let normalized = policy.trimmedNonEmpty ?? Self.defaultRuleTargetPolicy
        guard self.largeTrafficRuleTargetPolicy != normalized else { return }
        self.largeTrafficRuleTargetPolicy = normalized
        self.defaults.set(normalized, forKey: Self.largeTrafficRuleTargetPolicyKey)
        self.connectionsStore.retargetLargeTrafficCandidates(policy: normalized)
        self.connectionsStore.recordLargeTrafficCandidates(
            from: self.connectionsStore.connections,
            targetPolicy: self.effectiveLargeTrafficRuleTargetPolicy,
            focusedPolicyNames: self.largeTrafficProxyGroupNames)
    }

    func setLargeTrafficThresholdBytes(_ thresholdBytes: Int64) {
        let normalized = Self.normalizedLargeTrafficThresholdBytes(thresholdBytes)
        guard self.largeTrafficThresholdBytes != normalized else { return }

        self.largeTrafficThresholdBytes = normalized
        self.defaults.set(normalized, forKey: Self.largeTrafficThresholdBytesKey)
        self.connectionsStore.setLargeTrafficThresholdBytes(normalized)
        self.connectionsStore.recordLargeTrafficCandidates(
            from: self.connectionsStore.connections,
            targetPolicy: self.effectiveLargeTrafficRuleTargetPolicy,
            focusedPolicyNames: self.largeTrafficProxyGroupNames)
    }

    func removeLargeTrafficConnectionCandidate(_ candidate: LargeTrafficConnectionCandidate) {
        self.connectionsStore.removeLargeTrafficCandidate(id: candidate.id)
    }

    func clearLargeTrafficConnectionCandidates() {
        self.connectionsStore.clearLargeTrafficCandidates()
    }

    private static func normalizedLargeTrafficThresholdBytes(_ value: Int64) -> Int64 {
        min(
            max(value, Self.minimumLargeTrafficThresholdBytes),
            Self.maximumLargeTrafficThresholdBytes)
    }

    var largeTrafficProxyGroupNames: Set<String> {
        Set(self.proxyGroups.compactMap { group in
            guard let name = group.name.trimmedNonEmpty,
                  !Self.ignoredLargeTrafficPolicyNames.contains(name.lowercased())
            else { return nil }
            return name
        })
    }

    var sortedLargeTrafficProxyGroupNames: [String] {
        self.largeTrafficProxyGroupNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var effectiveLargeTrafficRuleTargetPolicy: String {
        if self.largeTrafficProxyGroupNames.contains(self.largeTrafficRuleTargetPolicy) {
            return self.largeTrafficRuleTargetPolicy
        }
        if self.largeTrafficProxyGroupNames.contains(Self.defaultRuleTargetPolicy) {
            return Self.defaultRuleTargetPolicy
        }
        return self.sortedLargeTrafficProxyGroupNames.first ?? self.largeTrafficRuleTargetPolicy
    }

    func refreshLargeTrafficCandidatesForCurrentProxyGroups() {
        let policyNames = self.largeTrafficProxyGroupNames
        self.connectionsStore.pruneLargeTrafficCandidates(focusedPolicyNames: policyNames)
        self.connectionsStore.recordLargeTrafficCandidates(
            from: self.connectionsStore.connections,
            targetPolicy: self.effectiveLargeTrafficRuleTargetPolicy,
            focusedPolicyNames: policyNames)
    }
}
