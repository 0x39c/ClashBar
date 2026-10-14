import AppKit
import Darwin
import SwiftUI

struct ConnectionsTabView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var connectionsStore: ConnectionsStore
    @AppStorage("clashbar.connections.transport_filter") private var storedTransportFilterRawValue =
        ConnectionsTransportFilter.all.rawValue
    @AppStorage("clashbar.connections.sort_option") private var storedSortOptionRawValue =
        ConnectionsSortOption.totalDesc.rawValue
    @ObservedObject var viewModel: ConnectionsViewModel
    @State private var ruleDraftForAdd: RuleDraftForAdd?
    @State private var selectedSubview: ConnectionsSubview = .active
    @State private var largeTrafficThresholdText: String = "10MB"
    @FocusState private var isLargeTrafficThresholdFocused: Bool

    private enum ConnectionsLayout {
        static let topLineSpacing: CGFloat = MenuBarLayoutTokens.space2
        static let topMetaSpacing: CGFloat = MenuBarLayoutTokens.space1
        static let secondLineSpacing: CGFloat = MenuBarLayoutTokens.space2
        static let rowLineHeight: CGFloat = 16
        static let topRuleMinWidth: CGFloat = 26
        static let topPayloadMinWidth: CGFloat = 14
        static let rowTrailingActionWidth: CGFloat = 12
        static let largeTrafficActionButtonSize: CGFloat = 18
        static let largeTrafficActionsWidth: CGFloat =
            (largeTrafficActionButtonSize * 2) + MenuBarLayoutTokens.space4
        static let rowContentWidth: CGFloat =
            MenuBarLayoutTokens.panelWidth
                - (MenuBarLayoutTokens.space8 * 2)
                - (MenuBarLayoutTokens.space4 * 2)
                - MenuBarLayoutTokens.rowLeadingIcon
                - (MenuBarLayoutTokens.space6 * 2)
                - rowTrailingActionWidth
        static let largeTrafficRowContentWidth: CGFloat =
            max(rowContentWidth - largeTrafficActionsWidth + rowTrailingActionWidth, 0)
    }

    private static var textWidthCache: [String: CGFloat] = [:]

    private enum ConnectionsSubview: String, CaseIterable, Identifiable {
        case active
        case largeTraffic

        var id: String {
            rawValue
        }
    }

    private struct RuleDraftForAdd: Identifiable {
        let id = UUID()
        let ruleType: String
        let payload: String
        let policy: String
        let candidate: LargeTrafficConnectionCandidate?
    }

    var body: some View {
        let connections = self.viewModel.visibleConnections

        return VStack(alignment: .leading, spacing: MenuBarLayoutTokens.space6) {
            self.connectionsSubviewTabs
            self.connectionsSubviewContent(connections)
        }
        .onAppear {
            self.restoreStoredPreferences()
            self.syncLargeTrafficThresholdTextFromModel()
            self.refreshData()
        }
        .onChange(of: self.connectionsStore.connections) { _ in self.refreshData() }
        .onChange(of: self.viewModel.filterText) { _ in self.refreshData() }
        .onChange(of: self.viewModel.transportFilter) { _ in self.refreshData() }
        .onChange(of: self.viewModel.sortOption) { _ in self.refreshData() }
        .onChange(of: self.appViewModel.largeTrafficThresholdBytes) { _ in
            self.syncLargeTrafficThresholdTextFromModel()
        }
        .onChange(of: self.isLargeTrafficThresholdFocused) { focused in
            if !focused {
                self.applyLargeTrafficThresholdText()
            }
        }
        .sheet(item: self.$ruleDraftForAdd) { draft in
            AddRuleSheet(
                initialRuleType: draft.ruleType,
                initialPayload: draft.payload,
                initialPolicy: draft.policy)
            {
                if let candidate = draft.candidate {
                    self.appViewModel.removeLargeTrafficConnectionCandidate(candidate)
                }
            }
            .environmentObject(self.appViewModel)
        }
    }

    private func refreshData() {
        self.viewModel.updateVisibleConnections(
            from: self.connectionsStore.connections,
            searchText: { connection in self.connectionSearchText(for: connection) })
    }

    private func restoreStoredPreferences() {
        let transportFilter = ConnectionsTransportFilter(rawValue: self.storedTransportFilterRawValue) ?? .all
        let sortOption = self.storedSortOptionRawValue == "default"
            ? ConnectionsSortOption.totalDesc
            : (ConnectionsSortOption(rawValue: self.storedSortOptionRawValue) ?? .totalDesc)

        self.viewModel.transportFilter = transportFilter
        self.viewModel.sortOption = sortOption

        if self.storedTransportFilterRawValue != transportFilter.rawValue {
            self.storedTransportFilterRawValue = transportFilter.rawValue
        }
        if self.storedSortOptionRawValue != sortOption.rawValue {
            self.storedSortOptionRawValue = sortOption.rawValue
        }
    }

    private func selectTransportFilter(_ filter: ConnectionsTransportFilter) {
        self.viewModel.transportFilter = filter
        self.storedTransportFilterRawValue = filter.rawValue
    }

    private func selectSortOption(_ sortOption: ConnectionsSortOption) {
        self.viewModel.sortOption = sortOption
        self.storedSortOptionRawValue = sortOption.rawValue
    }

    private func ruleDraft(for candidate: LargeTrafficConnectionCandidate) -> RuleDraftForAdd {
        RuleDraftForAdd(
            ruleType: candidate.ruleType,
            payload: candidate.payload,
            policy: candidate.policy,
            candidate: candidate)
    }

    private func ruleDraft(for connection: ConnectionSummary) -> RuleDraftForAdd? {
        guard let host = self.appViewModel.resolvedConnectionHost(for: connection) else { return nil }
        let ruleType = Self.ruleType(forRuleHost: host)
        return RuleDraftForAdd(
            ruleType: ruleType,
            payload: Self.rulePayload(forRuleHost: host, ruleType: ruleType),
            policy: self.appViewModel.effectiveLargeTrafficRuleTargetPolicy,
            candidate: nil)
    }

    private static func ruleType(forRuleHost host: String) -> String {
        self.isIPAddress(host) ? "IP-CIDR" : "DOMAIN-SUFFIX"
    }

    private static func rulePayload(forRuleHost host: String, ruleType: String) -> String {
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

    private func applyLargeTrafficThresholdText() {
        guard let thresholdBytes = Self.parseLargeTrafficThresholdBytes(self.largeTrafficThresholdText) else {
            NSSound.beep()
            self.syncLargeTrafficThresholdTextFromModel()
            return
        }

        self.appViewModel.setLargeTrafficThresholdBytes(thresholdBytes)
        self.syncLargeTrafficThresholdTextFromModel()
    }

    private func syncLargeTrafficThresholdTextFromModel() {
        let text = Self.largeTrafficThresholdDisplayText(for: self.appViewModel.largeTrafficThresholdBytes)
        if self.largeTrafficThresholdText != text {
            self.largeTrafficThresholdText = text
        }
    }

    private static func parseLargeTrafficThresholdBytes(_ text: String) -> Int64? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard !normalized.isEmpty else { return nil }

        var unitStart = normalized.startIndex
        while unitStart < normalized.endIndex {
            let character = normalized[unitStart]
            guard character.isNumber || character == "." else { break }
            unitStart = normalized.index(after: unitStart)
        }

        let numberText = String(normalized[..<unitStart])
        let unitText = String(normalized[unitStart...])
        guard let value = Double(numberText), value > 0 else { return nil }

        let multiplier: Double
        switch unitText {
        case "", "M", "MB", "MIB":
            multiplier = 1024 * 1024
        case "K", "KB", "KIB":
            multiplier = 1024
        case "G", "GB", "GIB":
            multiplier = 1024 * 1024 * 1024
        case "B":
            multiplier = 1
        default:
            return nil
        }
        return Int64((value * multiplier).rounded())
    }

    private static func largeTrafficThresholdDisplayText(for bytes: Int64) -> String {
        let gigabyte = 1024.0 * 1024.0 * 1024.0
        let megabyte = 1024.0 * 1024.0
        let kilobyte = 1024.0
        let value = Double(bytes)

        if value >= gigabyte {
            return "\(Self.compactDecimal(value / gigabyte))GB"
        }
        if value >= megabyte {
            return "\(Self.compactDecimal(value / megabyte))MB"
        }
        if value >= kilobyte {
            return "\(Self.compactDecimal(value / kilobyte))KB"
        }
        return "\(bytes)B"
    }

    private static func compactDecimal(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(.towardZero) {
            return "\(Int64(rounded))"
        }

        var text = String(format: "%.2f", rounded)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    var connectionsSubviewTabs: some View {
        HStack(spacing: MenuBarLayoutTokens.space2) {
            self.connectionsSubviewButton(
                .active,
                title: self.tr("ui.connections.tab.active"),
                symbol: "network",
                count: self.viewModel.visibleConnections.count)
            self.connectionsSubviewButton(
                .largeTraffic,
                title: self.tr("ui.connections.tab.large_traffic"),
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                count: self.connectionsStore.largeTrafficCandidates.count)
        }
        .padding(MenuBarLayoutTokens.space2)
        .cleanContentCard()
    }

    @ViewBuilder
    private func connectionsSubviewContent(_ connections: [ConnectionSummary]) -> some View {
        switch self.selectedSubview {
        case .active:
            self.connectionsControlCard
            self.connectionsListCard(connections)
        case .largeTraffic:
            self.largeTrafficCandidatesCard
        }
    }

    @ViewBuilder
    private func connectionsListCard(_ connections: [ConnectionSummary]) -> some View {
        if connections.isEmpty {
            emptyCard(self.tr("ui.empty.connections"))
        } else {
            MeasurementAwareVStack(spacing: 0) {
                SeparatedForEach(data: connections, id: \.id, separator: nativeSeparator) { conn in
                    self.connectionRow(conn)
                }
            }
            .menuRowPadding(vertical: MenuBarLayoutTokens.space2)
            .cleanContentCard()
        }
    }

    private func connectionsSubviewButton(
        _ subview: ConnectionsSubview,
        title: String,
        symbol: String,
        count: Int) -> some View
    {
        let selected = self.selectedSubview == subview

        return Button {
            self.selectedSubview = subview
        } label: {
            HStack(spacing: MenuBarLayoutTokens.space4) {
                Image(systemName: symbol)
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                    .foregroundStyle(selected ? nativePrimaryLabel : nativeSecondaryLabel)
                    .frame(width: 12, alignment: .center)
                Text(title)
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                    .foregroundStyle(selected ? nativePrimaryLabel : nativeSecondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(MenuBarLayoutTokens.minimumScale)
                if count > 0 {
                    Text("\(count)")
                        .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .bold))
                        .foregroundStyle(selected ? nativePrimaryLabel : nativeSecondaryLabel)
                        .padding(.horizontal, MenuBarLayoutTokens.space4)
                        .padding(.vertical, MenuBarLayoutTokens.space1)
                        .background(nativeBadgeCapsule())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: MenuBarLayoutTokens.cornerRadius, style: .continuous)
                    .fill(selected ? nativeHoverFill : .clear)
            }
            .contentShape(Rectangle())
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: MenuBarLayoutTokens.cornerRadius, style: .continuous)
                        .stroke(nativeControlBorder, lineWidth: MenuBarLayoutTokens.stroke)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    var connectionsControlCard: some View {
        VStack(alignment: .leading, spacing: MenuBarLayoutTokens.space4) {
            HStack(spacing: MenuBarLayoutTokens.space6) {
                self.connectionsFilterMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
                self.connectionsSortMenu
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                self.fractionSummaryBadge(
                    current: self.viewModel.visibleConnections.count,
                    total: min(self.connectionsStore.connections.count, 120))

                self.compactTopIcon(
                    "xmark",
                    label: self.tr("ui.action.close_all"),
                    warning: true)
                {
                    await self.appViewModel.closeAllConnections()
                }
                .help(self.tr("ui.action.close_all"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(self.tr("ui.placeholder.filter_connection"), text: self.$viewModel.filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .regular))
                .foregroundStyle(nativePrimaryLabel)
        }
        .menuRowPadding(vertical: MenuBarLayoutTokens.space4)
        .cleanContentCard()
    }

    var largeTrafficCandidatesCard: some View {
        VStack(alignment: .leading, spacing: MenuBarLayoutTokens.space4) {
            HStack(spacing: MenuBarLayoutTokens.space6) {
                Label(
                    self.tr("ui.connections.large_traffic.title"),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .semibold))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(MenuBarLayoutTokens.minimumScale)

                Text("\(self.connectionsStore.largeTrafficCandidates.count)")
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .bold))
                    .foregroundStyle(nativeCritical.opacity(MenuBarLayoutTokens.Opacity.solid))
                    .padding(.horizontal, MenuBarLayoutTokens.space4)
                    .padding(.vertical, MenuBarLayoutTokens.space1)
                    .background(nativeCritical.opacity(0.12), in: Capsule())

                Spacer(minLength: 0)

                self.largeTrafficThresholdControl
                    .frame(width: 86, alignment: .trailing)

                self.compactTopIcon(
                    "trash",
                    label: self.tr("ui.action.clear"),
                    warning: true)
                {
                    self.appViewModel.clearLargeTrafficConnectionCandidates()
                }
                .help(self.tr("ui.action.clear"))
            }

            if self.connectionsStore.largeTrafficCandidates.isEmpty {
                Text(self.tr("ui.empty.large_traffic"))
                    .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .regular))
                    .foregroundStyle(nativeSecondaryLabel)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, MenuBarLayoutTokens.space4)
                    .padding(.vertical, MenuBarLayoutTokens.space2)
            } else {
                VStack(spacing: 0) {
                    ForEach(self.connectionsStore.largeTrafficCandidates) { candidate in
                        self.largeTrafficCandidateRow(candidate)

                        if candidate.id != self.connectionsStore.largeTrafficCandidates.last?.id {
                            Rectangle()
                                .fill(nativeSeparator)
                                .frame(height: MenuBarLayoutTokens.stroke)
                        }
                    }
                }
            }
        }
        .menuRowPadding(vertical: MenuBarLayoutTokens.space4)
        .cleanContentCard()
    }

    var largeTrafficThresholdControl: some View {
        TextField("10MB", text: self.$largeTrafficThresholdText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .regular))
            .focused(self.$isLargeTrafficThresholdFocused)
            .onSubmit { self.applyLargeTrafficThresholdText() }
        .help(self.tr("ui.connections.large_traffic.threshold"))
    }

    func largeTrafficCandidateRow(_ candidate: LargeTrafficConnectionCandidate) -> some View {
        let visualSymbol = candidate.ruleType == "IP-CIDR" ? "number" : "globe"
        let hostText = candidate.host
        let networkType = candidate.network?.uppercased() ?? "--"
        let upText = ValueFormatter.bytesCompactNoSpace(candidate.upload)
        let downText = ValueFormatter.bytesCompactNoSpace(candidate.download)
        let chainsParts = self.connectionChainsParts(candidate.chains)

        return HStack(spacing: MenuBarLayoutTokens.space6) {
            Image(systemName: visualSymbol)
                .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .semibold))
                .foregroundStyle(nativeWarning.opacity(MenuBarLayoutTokens.Opacity.solid))
                .frame(
                    width: MenuBarLayoutTokens.rowLeadingIcon,
                    height: MenuBarLayoutTokens.rowLeadingIcon,
                    alignment: .center)

            VStack(alignment: .leading, spacing: MenuBarLayoutTokens.space2) {
                self.connectionRowTopLine(
                    host: hostText,
                    ruleType: candidate.ruleType,
                    rulePayload: candidate.payload,
                    contentWidth: ConnectionsLayout.largeTrafficRowContentWidth)
                self.connectionRowMetrics(
                    time: ValueFormatter.bytesCompactNoSpace(candidate.trafficTotal),
                    network: networkType,
                    up: upText,
                    down: downText,
                    contentWidth: ConnectionsLayout.largeTrafficRowContentWidth)
                self.connectionsDetailLine(
                    processName: candidate.processName ?? "",
                    parts: chainsParts,
                    contentWidth: ConnectionsLayout.largeTrafficRowContentWidth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: MenuBarLayoutTokens.space4) {
                self.largeTrafficRowIconButton(
                    symbol: "plus",
                    label: self.tr("ui.connections.large_traffic.add_rule"),
                    tint: nativePositive)
                {
                    self.ruleDraftForAdd = self.ruleDraft(for: candidate)
                }

                self.largeTrafficRowIconButton(
                    symbol: "xmark",
                    label: self.tr("ui.action.delete"),
                    tint: nativeSecondaryLabel)
                {
                    self.appViewModel.removeLargeTrafficConnectionCandidate(candidate)
                }
            }
        }
        .padding(.horizontal, MenuBarLayoutTokens.space4)
        .padding(.vertical, MenuBarLayoutTokens.space2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                self.ruleDraftForAdd = self.ruleDraft(for: candidate)
            } label: {
                Label(self.tr("ui.connections.large_traffic.add_rule"), systemImage: "plus")
            }

            Button {
                self.appViewModel.copyConnectionHost(candidate.host)
            } label: {
                Label(self.tr("ui.action.copy_host"), systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                self.appViewModel.removeLargeTrafficConnectionCandidate(candidate)
            } label: {
                Label(self.tr("ui.action.delete"), systemImage: "trash")
            }
        }
    }

    private func largeTrafficRowIconButton(
        symbol: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                .frame(width: 10, height: 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint.opacity(MenuBarLayoutTokens.Opacity.solid))
        .frame(
            width: ConnectionsLayout.largeTrafficActionButtonSize,
            height: ConnectionsLayout.largeTrafficActionButtonSize)
        .background(nativeBadgeCapsule())
        .help(label)
        .accessibilityLabel(label)
    }

    var connectionsFilterMenu: some View {
        self.compactSelectionMenu(.init(
            selection: self.viewModel.transportFilter,
            options: ConnectionsTransportFilter.allCases,
            symbol: "line.3.horizontal.decrease.circle",
            helpText: self.tr("ui.network.filter.transport"),
            optionTitle: { self.tr($0.titleKey) },
            onSelect: { self.selectTransportFilter($0) }))
    }

    var connectionsSortMenu: some View {
        self.compactSelectionMenu(.init(
            selection: self.viewModel.sortOption,
            options: ConnectionsSortOption.menuOptions,
            symbol: "arrow.up.arrow.down",
            helpText: self.tr("ui.network.sort.label"),
            optionTitle: { self.tr($0.titleKey) },
            onSelect: { self.selectSortOption($0) }))
    }

    func connectionRow(_ conn: ConnectionSummary) -> some View {
        let visual = self.connectionVisual(for: conn)
        let hovered = self.viewModel.hoveredConnectionID == conn.id
        let hostText = conn.metadata?.host.trimmedNonEmpty
            ?? conn.metadata?.destinationIP.trimmedNonEmpty
            ?? self.tr("ui.common.na")
        let networkType = conn.metadata?.network.trimmedNonEmpty?.uppercased() ?? "--"
        let processName = conn.metadata?.processName?.trimmedNonEmpty
            ?? conn.metadata?.processPath?.split(separator: "/").last.map(String.init)?.trimmedNonEmpty
            ?? conn.metadata?.pid.map(String.init)
            ?? ""
        let timeText = self.connectionTimeOnly(conn.start)
        let upText = ValueFormatter.bytesCompactNoSpace(conn.upload ?? 0)
        let downText = ValueFormatter.bytesCompactNoSpace(conn.download ?? 0)
        let chainsParts = self.connectionChainsParts(conn.chains)
        let parsedRule = self.parseConnectionRule(conn.rule)
        let ruleTypeText = self.connectionRuleTypeText(conn.rule, fallback: parsedRule?.type)
        let rulePayloadText = conn.rulePayload.trimmedNonEmpty
            ?? parsedRule?.payload.trimmedNonEmpty
            ?? "--"

        return HStack(alignment: .center, spacing: MenuBarLayoutTokens.space6) {
            Image(systemName: visual.symbol)
                .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .semibold))
                .foregroundStyle(visual.color)
                .frame(
                    width: MenuBarLayoutTokens.rowLeadingIcon,
                    height: MenuBarLayoutTokens.rowLeadingIcon,
                    alignment: .center)

            VStack(alignment: .leading, spacing: MenuBarLayoutTokens.space2) {
                self.connectionRowTopLine(host: hostText, ruleType: ruleTypeText, rulePayload: rulePayloadText)
                self.connectionRowMetrics(time: timeText, network: networkType, up: upText, down: downText)
                self.connectionsDetailLine(processName: processName, parts: chainsParts)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            self.connectionRowCloseButton(id: conn.id, hovered: hovered)
        }
        .padding(.horizontal, MenuBarLayoutTokens.space4)
        .padding(.vertical, MenuBarLayoutTokens.space2)
        .background(nativeHoverRowBackground(hovered))
        .onHover { self.viewModel.hoveredConnectionID = self.nextHovered(
            current: self.viewModel.hoveredConnectionID, target: conn.id, isHovering: $0) }
        .contextMenu { self.connectionRowContextMenu(conn) }
    }

    private func connectionRowTopLine(
        host: String,
        ruleType: String,
        rulePayload: String,
        contentWidth: CGFloat = ConnectionsLayout.rowContentWidth) -> some View
    {
        // Use a static content width, no GeometryReader needed since panel width is fixed.
        let layout = self.connectionsTopLineLayout(
            totalWidth: contentWidth,
            ruleText: ruleType,
            payloadText: rulePayload)

        return HStack(spacing: ConnectionsLayout.topLineSpacing) {
            Text(host)
                .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .semibold))
                .foregroundStyle(nativePrimaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: layout.hostWidth, alignment: .leading)

            HStack(spacing: ConnectionsLayout.topMetaSpacing) {
                self.connectionsTopBadge(text: ruleType)
                    .frame(width: layout.ruleWidth, alignment: .trailing)
                self.connectionsTopPayload(text: rulePayload)
                    .frame(width: layout.payloadWidth, alignment: .trailing)
            }
            .frame(
                width: layout.ruleWidth + ConnectionsLayout.topMetaSpacing + layout.payloadWidth,
                alignment: .trailing)
        }
        .frame(height: ConnectionsLayout.rowLineHeight)
    }

    private func connectionRowMetrics(
        time: String,
        network: String,
        up: String,
        down: String,
        contentWidth: CGFloat = ConnectionsLayout.rowContentWidth) -> some View
    {
        let columnWidth = max(
            (contentWidth - (ConnectionsLayout.secondLineSpacing * 3)) / 4,
            0)

        return HStack(spacing: ConnectionsLayout.secondLineSpacing) {
            self.connectionsMetricColumn(
                symbol: "clock",
                text: time,
                fallback: self.tr("ui.common.na"),
                width: columnWidth)
            self.connectionsMetricColumn(
                symbol: "network",
                text: network,
                fallback: self.tr("ui.common.na"),
                width: columnWidth)
            self.connectionsMetricColumn(
                symbol: "arrow.up",
                text: up,
                symbolColor: nativeInfo.opacity(MenuBarLayoutTokens.Opacity.solid),
                textColor: nativeInfo.opacity(MenuBarLayoutTokens.Opacity.solid),
                spacing: 0,
                truncation: .tail,
                width: columnWidth)
            self.connectionsMetricColumn(
                symbol: "arrow.down",
                text: down,
                symbolColor: nativeTeal.opacity(MenuBarLayoutTokens.Opacity.solid),
                textColor: nativeTeal.opacity(MenuBarLayoutTokens.Opacity.solid),
                spacing: 0,
                truncation: .tail,
                width: columnWidth)
        }
        .frame(height: ConnectionsLayout.rowLineHeight)
    }

    private func connectionsDetailLine(
        processName: String,
        parts: [String],
        contentWidth: CGFloat = ConnectionsLayout.rowContentWidth) -> some View
    {
        let chainText = parts.joined(separator: " > ")

        return HStack(spacing: MenuBarLayoutTokens.space4) {
            HStack(spacing: MenuBarLayoutTokens.space2) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                    .foregroundStyle(nativeSecondaryLabel)
                    .frame(width: 10, alignment: .leading)
                Text(parts.isEmpty ? self.tr("ui.common.na") : chainText)
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .regular))
                    .foregroundStyle(nativeSecondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !processName.isEmpty {
                HStack(spacing: MenuBarLayoutTokens.space2) {
                    Image(systemName: "app.badge")
                        .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                        .foregroundStyle(nativeSecondaryLabel)
                        .frame(width: 10, alignment: .leading)
                    Text(processName)
                        .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .regular))
                        .foregroundStyle(nativeSecondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: contentWidth * 0.35, alignment: .trailing)
            }
        }
        .frame(height: ConnectionsLayout.rowLineHeight, alignment: .leading)
    }

    private func connectionRowCloseButton(id: String, hovered: Bool) -> some View {
        Button {
            Task { await self.appViewModel.closeConnection(id: id) }
        } label: {
            Image(systemName: "xmark")
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                .frame(width: 10, height: 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovered ? nativeSecondaryLabel : nativeTertiaryLabel)
        .frame(width: 12, height: 12)
        .opacity(hovered ? 1 : 0)
    }

    @ViewBuilder
    private func connectionRowContextMenu(_ conn: ConnectionSummary) -> some View {
        Button(role: .destructive) {
            Task { await self.appViewModel.closeConnection(id: conn.id) }
        } label: {
            Label(self.tr("ui.action.close_connection"), systemImage: "xmark.circle")
        }

        if let host = appViewModel.resolvedConnectionHost(for: conn) {
            if let draft = self.ruleDraft(for: conn) {
                Button {
                    self.ruleDraftForAdd = draft
                } label: {
                    Label(self.tr("ui.connections.large_traffic.add_rule"), systemImage: "plus")
                }
            }

            Button {
                self.appViewModel.copyConnectionHost(host)
            } label: {
                Label(self.tr("ui.action.copy_host"), systemImage: "doc.on.doc")
            }
        }

        Button {
            self.appViewModel.copyConnectionID(conn.id)
        } label: {
            Label(self.tr("ui.action.copy_connection_id"), systemImage: "number")
        }
    }

    func connectionsMetricColumn(
        symbol: String,
        text: String,
        symbolColor: Color = .secondary,
        textColor: Color = .secondary,
        fallback: String? = nil,
        spacing: CGFloat = MenuBarLayoutTokens.space2,
        truncation: Text.TruncationMode = .middle,
        width: CGFloat) -> some View
    {
        let renderedText = text.isEmpty ? (fallback ?? "") : text

        return HStack(spacing: spacing) {
            Image(systemName: symbol)
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 10, alignment: .leading)
            Text(renderedText)
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(truncation)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
    }

    func connectionsTopBadge(text: String) -> some View {
        Text(text)
            .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
            .foregroundStyle(nativeSecondaryLabel)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(MenuBarLayoutTokens.minimumScale)
            .padding(.horizontal, MenuBarLayoutTokens.space2)
            .padding(.vertical, MenuBarLayoutTokens.space1)
            .background(nativeBadgeCapsule())
    }

    func connectionsTopPayload(text: String) -> some View {
        Text(text)
            .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .medium))
            .foregroundStyle(nativeSecondaryLabel)
            .lineLimit(1)
            .truncationMode(.middle)
            .minimumScaleFactor(MenuBarLayoutTokens.minimumScale)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    func connectionsTopLineLayout(
        totalWidth: CGFloat,
        ruleText: String,
        payloadText: String) -> (hostWidth: CGFloat, ruleWidth: CGFloat, payloadWidth: CGFloat)
    {
        guard totalWidth > 0 else { return (0, 0, 0) }

        let hostMinWidth = floor(totalWidth * 0.5)
        let metaMaxWidth = max(totalWidth - ConnectionsLayout.topLineSpacing - hostMinWidth, 0)

        var ruleWidth = max(
            ConnectionsLayout.topRuleMinWidth,
            self
                .connectionsMonospacedTextWidth(
                    ruleText,
                    size: MenuBarLayoutTokens.FontSize.caption,
                    weight: .semibold) +
                4)
        var payloadWidth = max(
            ConnectionsLayout.topPayloadMinWidth,
            self.connectionsMonospacedTextWidth(
                payloadText,
                size: MenuBarLayoutTokens.FontSize.caption,
                weight: .medium))
        let desiredMetaWidth = ruleWidth + ConnectionsLayout.topMetaSpacing + payloadWidth

        if desiredMetaWidth > metaMaxWidth {
            var overflow = desiredMetaWidth - metaMaxWidth

            let payloadReducible = max(payloadWidth - ConnectionsLayout.topPayloadMinWidth, 0)
            let payloadReduction = min(overflow, payloadReducible)
            payloadWidth -= payloadReduction
            overflow -= payloadReduction

            if overflow > 0 {
                let ruleReducible = max(ruleWidth - ConnectionsLayout.topRuleMinWidth, 0)
                let ruleReduction = min(overflow, ruleReducible)
                ruleWidth -= ruleReduction
                overflow -= ruleReduction
            }

            if overflow > 0 {
                let metaContentWidth = max(metaMaxWidth - ConnectionsLayout.topMetaSpacing, 0)
                if metaContentWidth <= 0 {
                    ruleWidth = 0
                    payloadWidth = 0
                } else {
                    let total = max(ruleWidth + payloadWidth, 1)
                    let ruleRatio = ruleWidth / total
                    ruleWidth = floor(metaContentWidth * ruleRatio)
                    payloadWidth = max(metaContentWidth - ruleWidth, 0)
                }
            }
        }

        let metaWidth = ruleWidth + ConnectionsLayout.topMetaSpacing + payloadWidth
        let hostWidth = max(totalWidth - ConnectionsLayout.topLineSpacing - metaWidth, hostMinWidth)
        return (hostWidth, ruleWidth, payloadWidth)
    }

    func connectionsMonospacedTextWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let cacheKey = "\(text)\0\(size)\0\(weight.rawValue)"
        if let cached = Self.textWidthCache[cacheKey] {
            return cached
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        ]
        let width = ceil((text as NSString).size(withAttributes: attributes).width)
        Self.textWidthCache[cacheKey] = width
        return width
    }

    func connectionRuleTypeText(_ raw: String?, fallback: String?) -> String {
        let candidate = fallback.trimmedNonEmpty ?? raw.trimmedNonEmpty ?? ""
        guard !candidate.isEmpty else { return "--" }

        let normalized = candidate.uppercased()
        if normalized == "MATCH" || normalized == "FINAL" { return "--" }
        return candidate
    }

    func connectionChainsParts(_ chains: [String]?) -> [String] {
        Array((chains ?? []).compactMap(\.trimmedNonEmpty).reversed())
    }

    func parseConnectionRule(_ raw: String?) -> (type: String, payload: String?)? {
        guard let raw = raw.trimmedNonEmpty else {
            return nil
        }

        if let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close {
            let type = raw[..<open].trimmed
            let payload = raw[raw.index(after: open)..<close].trimmed
            if let type = type.nonEmpty {
                return (type, payload.nonEmpty)
            }
        }

        let commaParts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        if commaParts.count == 2 {
            let type = commaParts[0].trimmed
            let payload = commaParts[1].trimmed
            if let type = type.nonEmpty {
                return (type, payload.nonEmpty)
            }
        }

        return (raw, nil)
    }

    func connectionTimeOnly(_ input: String?) -> String {
        let full = ValueFormatter.dateTimeFromISO(input)
        guard full != "--" else { return full }
        return full.split(separator: " ").last.map(String.init) ?? full
    }

    func connectionVisual(for conn: ConnectionSummary) -> (symbol: String, color: Color) {
        let network = conn.metadata?.network?.lowercased() ?? ""

        if network.contains("udp") {
            return ("icloud.fill", nativeTeal.opacity(MenuBarLayoutTokens.Opacity.solid))
        }
        if network.contains("tcp") {
            return ("network", nativeInfo.opacity(MenuBarLayoutTokens.Opacity.solid))
        }
        return ("globe", nativeSecondaryLabel)
    }

    func connectionSearchText(for conn: ConnectionSummary) -> String {
        let host = conn.metadata?.host ?? ""
        let destinationIP = conn.metadata?.destinationIP ?? ""
        let sourceIP = conn.metadata?.sourceIP ?? ""
        let network = conn.metadata?.network ?? ""
        let processName = conn.metadata?.processName ?? ""
        let processPath = conn.metadata?.processPath ?? ""
        let pid = conn.metadata?.pid.map(String.init) ?? ""
        let id = conn.id
        let rule = conn.rule ?? ""
        let rulePayload = conn.rulePayload ?? ""
        let chains = self.connectionChainsParts(conn.chains).joined(separator: " > ")
        let start = conn.start ?? ""
        return "\(host) \(destinationIP) \(sourceIP) \(network) \(processName) \(processPath) \(pid) \(id) \(rule) \(rulePayload) \(chains) \(start)"
    }
}
