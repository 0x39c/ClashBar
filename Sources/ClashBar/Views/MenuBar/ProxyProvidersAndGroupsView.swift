import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

extension ProxyTabView {
    private var visibleProxyProviderNames: [String] {
        let providers = appViewModel.sortedProxyProviderNames
        guard !providers.isEmpty else { return [] }
        if !isProxyProvidersCollapsed {
            return providers
        }
        if let selected = appViewModel.selectedProxyProviderName,
           providers.contains(selected)
        {
            return [selected]
        }
        return []
    }

    var proxyProvidersSection: some View {
        let providers = appViewModel.sortedProxyProviderNames
        let visible = self.visibleProxyProviderNames

        return VStack(alignment: .leading, spacing: T.space6) {
            self.nodesSectionHeader(
                tr("ui.section.proxy_providers"),
                symbol: "externaldrive.fill",
                count: "\(providers.count)")
            {
                HStack(spacing: T.space6) {
                    Image(systemName: isProxyProvidersCollapsed ? "chevron.right" : "chevron.down")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(nativeSecondaryLabel)
                        .frame(width: T.rowLeadingIcon, height: T.rowLeadingIcon)

                    self.compactTopIcon(
                        "plus",
                        label: self.tr("ui.action.add_proxy_provider"),
                        toneOverride: nativeTeal)
                    {
                        await self.appViewModel.addProxyProviderToLocalDefaultConfig()
                    }
                    .disabled(!self.appViewModel.canBindProviderToSelectedLocalDefaultConfig)
                    .help(self.appViewModel.canBindProviderToSelectedLocalDefaultConfig
                        ? self.tr("ui.action.add_proxy_provider")
                        : self.tr("ui.proxy_provider.help.local_only"))
                    .opacity(self.appViewModel.canBindProviderToSelectedLocalDefaultConfig ? 1 : 0.72)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    isProxyProvidersCollapsed.toggle()
                }
            }

            if providers.isEmpty {
                emptyCard(tr("ui.empty.proxy_providers"))
            } else if !visible.isEmpty {
                VStack(spacing: T.space4) {
                    ForEach(visible, id: \.self) { name in
                        self.proxyProviderRow(name: name, detail: appViewModel.proxyProvidersDetail[name])
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    }
                }
                .clipped()
            }
        }
        .menuRowPadding(vertical: T.space4)
        .cleanContentCard()
    }

    func proxyProviderRow(name: String, detail: ProviderDetail?) -> some View {
        let nodeCount = detail?.proxies?.count ?? 0
        let updatedText = ValueFormatter.relativeTime(from: detail?.updatedAt, language: language)
        let expireSeconds = detail?.subscriptionInfo?.expire
        let expireText = ValueFormatter.daysUntilExpiryShort(from: expireSeconds, language: language)
        let expireColor: Color = expireSeconds == 0 ? nativeSecondaryLabel : nativeInfo
        let upload = detail?.subscriptionInfo?.upload
        let download = detail?.subscriptionInfo?.download
        let total = detail?.subscriptionInfo?.total
        let usedRatio: Double? = {
            guard let total, total > 0, let upload, let download else { return nil }
            let used = upload + download
            return min(max(Double(used) / Double(total), 0), 1)
        }()
        let rowHorizontalPadding = T.space6
        let isUpdating = appViewModel.providerUpdating.contains(name)
        let hovered = hoveredProviderName == name
        let isBindingEnabled = appViewModel.canBindProviderToSelectedLocalDefaultConfig
        let isSelected = appViewModel.selectedProxyProviderName == name
        let updateTimeWidth: CGFloat = 44
        let hasSubscription = detail?.subscriptionInfo != nil
        let bindingHelpText = self.tr("ui.proxy_provider.help.bind")
        let disabledHelpText = self.tr("ui.proxy_provider.help.local_only")

        return HStack(alignment: .top, spacing: T.space6) {
            Button {
                Task { await appViewModel.selectProxyProviderForLocalDefaultConfig(name: name) }
            } label: {
                VStack(alignment: .leading, spacing: T.space6) {
                    HStack(alignment: .center, spacing: T.space6) {
                        ZStack {
                            Circle()
                                .fill(self.providerRowIconBackground(isSelected: isSelected, hovered: hovered))
                                .frame(width: 24, height: 24)

                            Image(systemName: "externaldrive.fill")
                                .font(.app(size: T.FontSize.caption, weight: .semibold))
                                .foregroundStyle(isSelected ? nativeTeal.opacity(T.Opacity.solid) : nativeSecondaryLabel)
                        }

                        HStack(alignment: .center, spacing: T.space4) {
                            HStack(alignment: .center, spacing: T.space4) {
                                Text(name)
                                    .font(.app(size: T.FontSize.body, weight: isSelected ? .bold : .semibold))
                                    .foregroundStyle(isSelected ? Color.primary : nativePrimaryLabel)
                                    .lineLimit(1)
                                    .layoutPriority(1)

                                Text("\(nodeCount)")
                                    .font(.app(size: T.FontSize.caption, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.primary.opacity(0.76) : nativeSecondaryLabel)
                                    .fixedSize()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(updatedText)
                                .font(.app(size: T.FontSize.caption, weight: .regular))
                                .foregroundStyle(isSelected ? Color.primary.opacity(0.68) : nativeTertiaryLabel)
                                .lineLimit(1)
                                .frame(width: updateTimeWidth, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if hasSubscription {
                        VStack(alignment: .leading, spacing: T.space2) {
                            HStack(spacing: 0) {
                                Text(expireText)
                                    .font(.app(size: T.FontSize.caption, weight: .regular))
                                    .foregroundStyle(expireColor)
                                Spacer(minLength: T.space4)
                                if let upload, let download, let total {
                                    let used = upload + download
                                    let quotaText =
                                        "\(ValueFormatter.bytesCompactNoSpace(used)) / " +
                                        "\(ValueFormatter.bytesCompactNoSpace(total))"
                                    Text(quotaText)
                                        .font(.app(size: T.FontSize.caption, weight: .regular))
                                        .foregroundStyle(isSelected ? Color.primary.opacity(0.72) : nativeSecondaryLabel)
                                        .lineLimit(1)
                                }
                            }

                            if let usedRatio {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(nativeControlFill.opacity(T.Opacity.solid))
                                        Capsule()
                                            .fill((usedRatio >= 0.9 ? nativeCritical : usedRatio >= 0.75 ? nativeWarning :
                                                    nativeAccent).opacity(T.Opacity.solid))
                                            .frame(width: geo.size.width * usedRatio)
                                    }
                                }
                                .frame(height: T.space6)
                            }
                        }
                        .padding(.leading, 24 + T.space6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isBindingEnabled)
            .help(isBindingEnabled ? bindingHelpText : disabledHelpText)
            .opacity(isBindingEnabled ? 1 : 0.72)

            Button {
                Task { await appViewModel.updateProxyProvider(name: name) }
            } label: {
                ZStack {
                    Circle()
                        .fill(isUpdating ? nativeTeal.opacity(T.Opacity.tint) : nativeBadgeFill)
                        .frame(width: 24, height: 24)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hovered || isSelected ? nativeTeal.opacity(T.Opacity.solid) : nativeSecondaryLabel)
                        .opacity(isUpdating ? 0 : 1)
                    ProgressView()
                        .scaleEffect(0.5)
                        .opacity(isUpdating ? 1 : 0)
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("ui.action.refresh"))
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, T.space6)
        .background {
            self.providerRowBackground(isSelected: isSelected, hovered: hovered)
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(nativeTeal.opacity(T.Opacity.solid))
                    .frame(width: 3)
                    .padding(.vertical, T.space6)
                    .padding(.leading, T.space2)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if isBindingEnabled {
                Button(role: .destructive) {
                    Task { await self.appViewModel.deleteProxyProviderFromLocalDefaultConfig(name: name) }
                } label: {
                    Text(self.tr("ui.action.delete"))
                }
            }
        }
        .onHover { hoveredProviderName = self.nextHovered(
            current: hoveredProviderName,
            target: name,
            isHovering: $0) }
    }

    func providerRowIconBackground(isSelected: Bool, hovered: Bool) -> Color {
        if isSelected {
            return nativeTeal.opacity(isDarkAppearance ? 0.22 : 0.16)
        }
        if hovered {
            return nativeHoverFill.opacity(isDarkAppearance ? 0.16 : 0.10)
        }
        return nativeBadgeFill
    }

    func providerRowBackground(isSelected: Bool, hovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)

        return shape
            .fill(self.providerRowFill(isSelected: isSelected, hovered: hovered))
            .overlay(alignment: .topLeading) {
                if isSelected {
                    LinearGradient(
                        colors: [nativeTeal.opacity(isDarkAppearance ? 0.10 : 0.06), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                        .clipShape(shape)
                }
            }
            .overlay {
                shape.stroke(
                    isSelected
                        ? nativeTeal.opacity(isDarkAppearance ? 0.46 : 0.34)
                        : nativeControlBorder.opacity(hovered ? 0.42 : 0.28),
                    lineWidth: T.stroke)
            }
            .shadow(
                color: Color(nsColor: .shadowColor).opacity(isSelected ? (isDarkAppearance ? 0.20 : 0.10) : 0),
                radius: isSelected ? 6 : 0,
                x: 0,
                y: isSelected ? 3 : 0)
    }

    func providerRowFill(isSelected: Bool, hovered: Bool) -> Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor).opacity(isDarkAppearance ? 0.20 : 0.12)
        }
        if hovered {
            return nativeHoverFill.opacity(isDarkAppearance ? 0.14 : 0.08)
        }
        return Color(nsColor: isDarkAppearance ? .windowBackgroundColor : .controlBackgroundColor)
            .opacity(isDarkAppearance ? 0.22 : 0.42)
    }

    enum ProviderAction {
        case healthcheck
        case refresh

        var symbol: String {
            switch self {
            case .healthcheck: "gauge.with.dots.needle.50percent"
            case .refresh: "arrow.triangle.2.circlepath"
            }
        }

        var labelKey: String {
            switch self {
            case .healthcheck: "ui.action.test_latency"
            case .refresh: "ui.action.refresh"
            }
        }
    }

    func providerActionButton(
        _ kind: ProviderAction,
        isLoading: Bool = false,
        action: @escaping () async -> Void) -> some View
    {
        let tone = kind == .healthcheck ? nativeTeal : nativeInfo
        return self.compactAsyncIconButton(
            symbol: kind.symbol,
            label: tr(kind.labelKey),
            tint: tone.opacity(T.Opacity.solid),
            isLoading: isLoading,
            size: T.rowLeadingIcon,
            fontSize: T.FontSize.caption,
            hierarchicalSymbol: true,
            action: action)
    }

    var proxyGroupsSection: some View {
        // Use @State filteredProxyGroups which is updated via .onChange — avoids filtering on every render
        let groups = rootViewModel.filteredProxyGroups

        return VStack(alignment: .leading, spacing: T.space6) {
            self.nodesSectionHeader(
                tr("ui.section.proxy_groups"),
                symbol: "point.3.connected.trianglepath.dotted",
                count: "\(groups.count)")
            {
                HStack(spacing: T.space6) {
                    self.compactTopIcon(
                        sortGroupNodesByLatency ? "timer" : "list.number",
                        label: tr(
                            sortGroupNodesByLatency
                                ? "ui.action.sort_nodes_default"
                                : "ui.action.sort_nodes_by_latency"),
                        toneOverride: nativeTeal)
                    {
                        sortGroupNodesByLatency.toggle()
                    }
                    .help(
                        tr(
                            sortGroupNodesByLatency
                                ? "ui.action.sort_nodes_default"
                                : "ui.action.sort_nodes_by_latency"))

                    self.compactTopIcon(
                        hideHiddenProxyGroups ? "eye.slash" : "eye",
                        label: tr(
                            hideHiddenProxyGroups
                                ? "ui.action.show_hidden_proxy_groups"
                                : "ui.action.hide_hidden_proxy_groups"),
                        toneOverride: nativeIndigo)
                    {
                        hideHiddenProxyGroups.toggle()
                    }
                    .help(
                        tr(
                            hideHiddenProxyGroups
                                ? "ui.action.show_hidden_proxy_groups"
                                : "ui.action.hide_hidden_proxy_groups"))

                    self.compactTopIcon(
                        "gauge",
                        label: tr("ui.action.test_latency"),
                        toneOverride: nativeTeal)
                    {
                        await appViewModel.refreshAllGroupLatencies(includeHiddenGroups: !hideHiddenProxyGroups)
                    }
                    .help(tr("ui.action.test_latency"))
                }
            }

            if groups.isEmpty {
                emptyCard(tr("ui.empty.proxy_groups"))
            } else {
                VStack(spacing: T.space2) {
                    ForEach(groups, id: \.name) { group in
                        self.proxyGroupInlineRow(group)
                    }
                }
            }
        }
        .menuRowPadding(vertical: T.space4)
        .cleanContentCard()
    }

    func proxyGroupInlineRow(_ group: ProxyGroup) -> some View {
        let currentNode = group.now ?? tr("ui.common.na")
        let delayText = appViewModel.delayText(
            group: group.name,
            node: currentNode,
            fallbackToGroupHistory: true)
        let delayValue = appViewModel.delayValue(
            group: group.name,
            node: currentNode,
            fallbackToGroupHistory: true)
        let nodeCount = group.all.filter { !rootViewModel.hiddenGroupNames.contains($0) }.count
        let iconURL = self.proxyGroupIconURL(group)
        let hasLeadingIcon = iconURL != nil
        let rowHorizontalPadding = T.space4
        let rowVerticalPadding: CGFloat = T.space1

        return AttachedPopoverMenu { isHovered in
            GeometryReader { geo in
                let columns = self.proxyGroupMainColumnWidths(
                    totalWidth: geo.size.width,
                    hasLeadingIcon: hasLeadingIcon)
                HStack(spacing: T.space1) {
                    if let iconURL {
                        self.proxyGroupLeadingIcon(iconURL)
                    }

                    Text(group.name)
                        .font(.app(size: T.FontSize.body, weight: .semibold))
                        .foregroundStyle(nativePrimaryLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(T.minimumScale)
                        .frame(width: columns.name, alignment: .leading)

                    Text(currentNode)
                        .font(.app(size: T.FontSize.caption, weight: .medium))
                        .foregroundStyle(nativeSecondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(T.minimumScale)
                        .padding(.horizontal, T.space4)
                        .padding(.vertical, T.space1)
                        .background(nativeBadgeCapsule())
                        .frame(width: columns.current, alignment: .leading)

                    Text(delayText)
                        .font(.app(size: T.FontSize.caption, weight: .regular))
                        .foregroundStyle(latencyColor(delayValue))
                        .lineLimit(1)
                        .minimumScaleFactor(T.minimumScale)
                        .frame(width: columns.delay, alignment: .trailing)

                    self.providerActionButton(
                        .healthcheck,
                        isLoading: appViewModel.isGroupLatencyLoading(group))
                    {
                        await appViewModel.refreshDisplayedGroupLatency(group)
                    }
                    .frame(width: 18, alignment: .center)

                    Image(systemName: "chevron.right")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(nativeTertiaryLabel)
                        .frame(width: T.space8, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: T.compactRowHeight)
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            .background(nativeHoverRowBackground(isHovered))
        } content: { dismiss in
            self.popoverHeader(name: group.name, count: nodeCount) {
                if let iconURL {
                    self.proxyGroupLeadingIcon(iconURL)
                }
            } trailing: {
                self.providerActionButton(
                    .healthcheck,
                    isLoading: appViewModel.groupLatencyLoading.contains(group.name))
                {
                    await appViewModel.refreshGroupLatency(group)
                }
                .help(tr("ui.action.test_latency"))
            }

            let nodes = sortGroupNodesByLatency
                ? self.sortedGroupNodes(group)
                : self.defaultGroupNodes(group)
            FrozenPopoverNodesList(nodes: nodes, emptyText: tr("ui.common.na")) { node in
                ProxyGroupPopoverNodeItem(
                    title: node,
                    typeText: appViewModel.proxyNodeTypes[node].trimmedNonEmpty,
                    delayText: appViewModel.delayText(group: group.name, node: node),
                    delayValue: appViewModel.delayValue(group: group.name, node: node),
                    delayColor: latencyColor(appViewModel.delayValue(group: group.name, node: node)),
                    isTesting: appViewModel.isProxyLatencyTesting(group: group.name, node: node),
                    selected: node == group.now,
                    testLatencyLabel: tr("ui.action.test_latency"),
                    onTestLatency: {
                        await appViewModel.refreshProxyLatency(group: group.name, node: node)
                    },
                    action: {
                        dismiss()
                        Task { await appViewModel.switchProxy(group: group.name, target: node) }
                    })
            }
        }
    }

    func proxyGroupMainColumnWidths(
        totalWidth: CGFloat,
        hasLeadingIcon: Bool) -> (name: CGFloat, current: CGFloat, delay: CGFloat)
    {
        let iconWidth: CGFloat = hasLeadingIcon ? T.rowLeadingIcon : 0
        let actionWidth: CGFloat = 18
        let chevronWidth: CGFloat = 8
        let spacingCount: CGFloat = hasLeadingIcon ? 5 : 4
        let spacing = T.space1 * spacingCount
        let available = max(0, totalWidth - iconWidth - actionWidth - chevronWidth - spacing)
        let name = floor(available * 0.34)
        let delay = floor(available * 0.17)
        let current = max(0, available - name - delay)
        return (name, current, delay)
    }

    func proxyGroupLeadingIcon(_ iconURL: URL) -> some View {
        AsyncImage(url: iconURL) { phase in
            if case let .success(image) = phase {
                image
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: T.rowLeadingIcon,
                        maxHeight: T.rowLeadingIcon)
            }
        }
        .frame(
            width: T.rowLeadingIcon,
            height: T.rowLeadingIcon,
            alignment: .center)
    }

    func proxyGroupIconURL(_ group: ProxyGroup) -> URL? {
        guard let icon = group.icon else { return nil }
        return URL(string: icon)
    }

    func nodesSectionHeader(
        _ title: String,
        symbol: String,
        count: String? = nil,
        @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View
    {
        HStack(spacing: T.space6) {
            Image(systemName: symbol)
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(nativeTertiaryLabel)
                .frame(
                    width: T.rowLeadingIcon,
                    height: T.rowLeadingIcon,
                    alignment: .center)

            Text(title)
                .font(.app(size: T.FontSize.body, weight: .bold))
                .foregroundStyle(nativeTertiaryLabel)
                .textCase(.uppercase)

            if let count {
                Text(count)
                    .font(.app(size: T.FontSize.caption, weight: .bold))
                    .foregroundStyle(nativeSecondaryLabel)
                    .padding(.horizontal, T.space4)
                    .padding(.vertical, T.space1)
                    .background(nativeBadgeCapsule())
            }

            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, T.space4)
    }

    func popoverHeader(
        name: String,
        count: Int,
        @ViewBuilder leading: () -> some View = { EmptyView() },
        @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View
    {
        VStack(spacing: 0) {
            HStack(spacing: T.space1) {
                leading()

                Text(name)
                    .font(.app(size: T.FontSize.body, weight: .semibold))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)

                Text("\(count)")
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .foregroundStyle(nativeSecondaryLabel)
                    .padding(.horizontal, T.space4)
                    .padding(.vertical, T.space1)
                    .background(nativeBadgeCapsule())

                Spacer(minLength: 0)

                trailing()
            }
            .padding(.horizontal, T.space4)
            .padding(.bottom, T.space2)

            Divider()
                .overlay(nativeSeparator)
                .padding(.bottom, T.space1)
        }
    }

    @ViewBuilder
    func popoverNodesList<Node: Hashable>(
        _ nodes: [Node],
        @ViewBuilder row: @escaping (Node) -> some View) -> some View
    {
        if nodes.isEmpty {
            Text(tr("ui.common.na"))
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(nativeSecondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.space6)
                .padding(.vertical, T.space4)
        } else {
            VStack(spacing: 0) {
                ForEach(nodes, id: \.self) { node in
                    row(node)
                }
            }
        }
    }

    // MARK: - Node Sorting Helpers

    func orderedUniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(names.count)
        for name in names where !name.isEmpty {
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    func sortedGroupNodes(_ group: ProxyGroup) -> [String] {
        let filtered = group.all.filter { !rootViewModel.hiddenGroupNames.contains($0) }
        return self.sortedNodes(names: filtered, latencyForNode: { appViewModel.delayValue(group: group.name, node: $0) })
    }

    func defaultGroupNodes(_ group: ProxyGroup) -> [String] {
        let filtered = group.all.filter { !rootViewModel.hiddenGroupNames.contains($0) }
        let unique = self.orderedUniqueNames(filtered)
        guard appViewModel.hideUnavailableProxyNodes else { return unique }
        return unique.filter { self.isProxyNodeAvailable(appViewModel.delayValue(group: group.name, node: $0)) }
    }

    private func sortedNodes(names: [String], latencyForNode: (String) -> Int?) -> [String] {
        let unique = self.orderedUniqueNames(names)
        let sorted = unique.sorted { lhs, rhs in
            let cmp = self.compareLatency(lhs: latencyForNode(lhs), rhs: latencyForNode(rhs), ascending: true)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        guard appViewModel.hideUnavailableProxyNodes else { return sorted }
        return sorted.filter { self.isProxyNodeAvailable(latencyForNode($0)) }
    }
}

private struct FrozenPopoverNodesList<Row: View>: View {
    let nodes: [String]
    let emptyText: String
    let row: (String) -> Row

    @State private var frozenNodes: [String]

    init(nodes: [String], emptyText: String, @ViewBuilder row: @escaping (String) -> Row) {
        self.nodes = nodes
        self.emptyText = emptyText
        self.row = row
        self._frozenNodes = State(initialValue: nodes)
    }

    var body: some View {
        if self.frozenNodes.isEmpty {
            Text(self.emptyText)
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.space6)
                .padding(.vertical, T.space4)
        } else {
            VStack(spacing: 0) {
                ForEach(self.frozenNodes, id: \.self) { node in
                    self.row(node)
                }
            }
        }
    }
}

private struct ProxyGroupPopoverNodeItem: View {
    let title: String
    let typeText: String?
    let delayText: String
    let delayValue: Int?
    let delayColor: Color
    let isTesting: Bool
    let selected: Bool
    let testLatencyLabel: String
    let onTestLatency: () async -> Void
    let action: () -> Void

    @State private var isHovered = false
    @State private var isTestButtonHovered = false

    var body: some View {
        HStack(spacing: T.space1) {
            Button(action: self.action) {
                HStack(spacing: T.space1) {
                    Image(systemName: self.selected ? "checkmark.circle.fill" : "circle")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(self
                            .selected ? Color(nsColor: .controlAccentColor) : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 11, alignment: .center)

                    Text(self.title)
                        .font(.app(size: T.FontSize.body, weight: self.selected ? .semibold : .medium))
                        .foregroundStyle(self.selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(T.minimumScale)

                    Spacer(minLength: 0)

                    if let typeText = self.typeText {
                        Text(typeText)
                            .font(.app(size: T.FontSize.caption, weight: .medium))
                            .foregroundStyle(self.selected ? Color.primary.opacity(0.72) : Color.secondary
                                .opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, T.space4)
                            .padding(.vertical, T.space1)
                            .background(
                                RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(self.selected ? 0.18 : 0.1)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            self.latencyControl
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: T.compactRowHeight)
        .padding(.horizontal, T.space4)
        .padding(.vertical, T.space1)
        .background(
            RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                .fill(self.rowBackground))
        .onHover {
            self.isHovered = $0
            if !$0 {
                self.isTestButtonHovered = false
            }
        }
    }

    @ViewBuilder
    var latencyControl: some View {
        if self.isHovered {
            if self.isTesting {
                LatencyLoadingIndicator()
            } else {
                Button {
                    Task { await self.onTestLatency() }
                } label: {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(self.isTestButtonHovered ? self.testButtonTint : self.testButtonBaseTint)
                        .frame(width: 18, height: 18, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(self.testLatencyLabel)
                .accessibilityLabel(self.testLatencyLabel)
                .onHover { self.isTestButtonHovered = $0 }
            }
        } else {
            self.delayMetricView
        }
    }

    var rowBackground: Color {
        if self.selected {
            return Color(nsColor: .controlAccentColor).opacity(T.Opacity.tint)
        }
        if self.isHovered {
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
        }
        return .clear
    }

    var testButtonTint: Color {
        Color(nsColor: .systemTeal).opacity(T.Opacity.solid)
    }

    var testButtonBaseTint: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    @ViewBuilder
    var delayMetricView: some View {
        if self.delayValue != nil {
            Text(self.delayText)
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(self.delayColor.opacity(self.selected ? 1 : 0.94))
                .lineLimit(1)
        } else {
            Text(self.delayText)
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(self.delayColor.opacity(self.selected ? 1 : 0.85))
                .lineLimit(1)
                .minimumScaleFactor(T.minimumScale)
        }
    }
}

private struct LatencyLoadingIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 30, height: 14, alignment: .center)
    }
}
