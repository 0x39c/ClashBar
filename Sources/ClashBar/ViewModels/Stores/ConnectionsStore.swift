import Darwin
import Foundation

@MainActor
final class ConnectionsStore: ObservableObject {
    private static let retainedLargeTrafficCandidateLimit = 60

    @Published var connections: [ConnectionSummary] = []
    @Published var connectionsCount: Int = 0
    @Published var largeTrafficThresholdBytes: Int64 = 10 * 1024 * 1024
    @Published var largeTrafficCandidates: [LargeTrafficConnectionCandidate] = []

    func recordLargeTrafficCandidates(
        from connections: [ConnectionSummary],
        targetPolicy: String,
        focusedPolicyNames: Set<String>)
    {
        let normalizedPolicy = targetPolicy.trimmedNonEmpty ?? "DIRECT"
        let normalizedFocusedPolicyNames = Set(focusedPolicyNames.map { $0.trimmed.lowercased() }.filter { !$0.isEmpty })
        var candidatesByID = Dictionary(uniqueKeysWithValues: self.largeTrafficCandidates.map { ($0.id, $0) })

        for connection in connections {
            guard let candidate = Self.largeTrafficCandidate(
                from: connection,
                targetPolicy: normalizedPolicy,
                focusedPolicyNames: normalizedFocusedPolicyNames,
                thresholdBytes: self.largeTrafficThresholdBytes)
            else {
                continue
            }

            if let existing = candidatesByID[candidate.id],
               existing.trafficTotal >= candidate.trafficTotal
            {
                continue
            }
            candidatesByID[candidate.id] = candidate
        }

        let nextCandidates = candidatesByID.values
            .sorted {
                if $0.trafficTotal != $1.trafficTotal {
                    return $0.trafficTotal > $1.trafficTotal
                }
                if $0.lastSeenAt != $1.lastSeenAt {
                    return $0.lastSeenAt > $1.lastSeenAt
                }
                return $0.payload.localizedStandardCompare($1.payload) == .orderedAscending
            }
            .prefix(Self.retainedLargeTrafficCandidateLimit)

        let next = Array(nextCandidates)
        if self.largeTrafficCandidates != next {
            self.largeTrafficCandidates = next
        }
    }

    func pruneLargeTrafficCandidates(focusedPolicyNames: Set<String>) {
        let normalizedFocusedPolicyNames = Set(focusedPolicyNames.map { $0.trimmed.lowercased() }.filter { !$0.isEmpty })
        guard !normalizedFocusedPolicyNames.isEmpty else {
            self.clearLargeTrafficCandidates()
            return
        }

        self.largeTrafficCandidates.removeAll { candidate in
            !candidate.chains.contains { normalizedFocusedPolicyNames.contains($0.trimmed.lowercased()) }
        }
    }

    func removeLargeTrafficCandidate(id: LargeTrafficConnectionCandidate.ID) {
        self.largeTrafficCandidates.removeAll { $0.id == id }
    }

    func retargetLargeTrafficCandidates(policy: String) {
        let normalizedPolicy = policy.trimmedNonEmpty ?? "DIRECT"
        self.largeTrafficCandidates = self.largeTrafficCandidates.map { candidate in
            LargeTrafficConnectionCandidate(
                id: candidate.id,
                ruleType: candidate.ruleType,
                payload: candidate.payload,
                policy: normalizedPolicy,
                host: candidate.host,
                processName: candidate.processName,
                network: candidate.network,
                rule: candidate.rule,
                rulePayload: candidate.rulePayload,
                chains: candidate.chains,
                upload: candidate.upload,
                download: candidate.download,
                trafficTotal: candidate.trafficTotal,
                lastSeenAt: candidate.lastSeenAt)
        }
    }

    func setLargeTrafficThresholdBytes(_ thresholdBytes: Int64) {
        let normalized = max(1024, thresholdBytes)
        guard self.largeTrafficThresholdBytes != normalized else { return }

        self.largeTrafficThresholdBytes = normalized
        self.largeTrafficCandidates.removeAll { $0.trafficTotal < normalized }
    }

    func clearLargeTrafficCandidates() {
        self.largeTrafficCandidates.removeAll(keepingCapacity: false)
    }

    private static func largeTrafficCandidate(
        from connection: ConnectionSummary,
        targetPolicy: String,
        focusedPolicyNames: Set<String>,
        thresholdBytes: Int64) -> LargeTrafficConnectionCandidate?
    {
        let trafficTotal = (connection.upload ?? 0) + (connection.download ?? 0)
        guard trafficTotal >= thresholdBytes else { return nil }
        guard self.connectionUsesTargetPolicy(connection, targetPolicy: targetPolicy) else { return nil }
        guard let host = self.connectionHost(connection) else { return nil }
        let focusedChains = (connection.chains ?? [])
            .compactMap(\.trimmedNonEmpty)
            .filter { $0.trimmed.lowercased() == targetPolicy.trimmed.lowercased() }
        let fallbackChains = (connection.chains ?? [])
            .compactMap(\.trimmedNonEmpty)
            .filter { focusedPolicyNames.contains($0.trimmed.lowercased()) }
        guard !focusedChains.isEmpty else { return nil }

        let ruleType = self.ruleType(for: host)
        let payload = self.rulePayload(for: host, ruleType: ruleType)
        let processName = connection.metadata?.processName?.trimmedNonEmpty
            ?? connection.metadata?.processPath?.split(separator: "/").last.map(String.init)?.trimmedNonEmpty

        return LargeTrafficConnectionCandidate(
            id: payload.lowercased(),
            ruleType: ruleType,
            payload: payload,
            policy: targetPolicy,
            host: host,
            processName: processName,
            network: connection.metadata?.network?.trimmedNonEmpty,
            rule: connection.rule?.trimmedNonEmpty,
            rulePayload: connection.rulePayload?.trimmedNonEmpty,
            chains: fallbackChains.isEmpty ? focusedChains : fallbackChains,
            upload: connection.upload ?? 0,
            download: connection.download ?? 0,
            trafficTotal: trafficTotal,
            lastSeenAt: Date())
    }

    private static func connectionUsesTargetPolicy(_ connection: ConnectionSummary, targetPolicy: String) -> Bool {
        let normalizedPolicy = targetPolicy.trimmed.lowercased()
        guard !normalizedPolicy.isEmpty else { return false }

        let candidates = (connection.chains ?? []) + [
            connection.rule,
            connection.rulePayload,
        ].compactMap { $0 }

        return candidates.contains { value in
            value.trimmed.lowercased() == normalizedPolicy
        }
    }

    private func connectionUsesAnyPolicy(_ connection: ConnectionSummary, policyNames: Set<String>) -> Bool {
        guard !policyNames.isEmpty else { return false }
        return (connection.chains ?? []).contains { value in
            policyNames.contains(value.trimmed.lowercased())
        }
    }

    private static func connectionHost(_ connection: ConnectionSummary) -> String? {
        connection.metadata?.host.trimmedNonEmpty
            ?? connection.metadata?.destinationIP.trimmedNonEmpty
    }

    private static func ruleType(for host: String) -> String {
        self.isIPAddress(host) ? "IP-CIDR" : "DOMAIN-SUFFIX"
    }

    private static func rulePayload(for host: String, ruleType: String) -> String {
        guard ruleType == "IP-CIDR" else { return host }
        return host.contains(":") ? "\(host)/128" : "\(host)/32"
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
        }
    }
}
