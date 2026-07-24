import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

struct ProxyTabView: TranslatingView {
    enum ProxyCommandCopyTarget: Equatable {
        case local
        case currentEndpoint
    }

    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var connectionsStore: ConnectionsStore
    @ObservedObject var rootViewModel: ProxyGroupsViewModel

    @AppStorage("clashbar.proxy.group.sort_nodes_by_latency") var sortGroupNodesByLatency: Bool = false
    @AppStorage("clashbar.proxy.group.hide_hidden") var hideHiddenProxyGroups: Bool = true
    @AppStorage("clashbar.proxy.providers.collapsed") var isProxyProvidersCollapsed: Bool = false

    @State var copiedProxyCommandTarget: ProxyCommandCopyTarget?
    @State var proxyCommandCopyResetTask: Task<Void, Never>?
    @State var hoveredProviderName: String?
    @State var showAddProxyProviderSheet = false

    var body: some View {
        self.proxyTabBody
            .onDisappear {
                self.proxyCommandCopyResetTask?.cancel()
                self.proxyCommandCopyResetTask = nil
            }
            .sheet(isPresented: self.$showAddProxyProviderSheet) {
                AddProxyProviderSheet()
                    .environmentObject(self.appViewModel)
            }
    }

    func handleCopyProxyCommand(_ target: ProxyCommandCopyTarget, action: () -> Void) {
        action()

        self.proxyCommandCopyResetTask?.cancel()
        self.proxyCommandCopyResetTask = nil

        withAnimation(.snappy(duration: 0.16)) {
            self.copiedProxyCommandTarget = target
        }

        self.proxyCommandCopyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_600_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                self.copiedProxyCommandTarget = nil
            }
            self.proxyCommandCopyResetTask = nil
        }
    }

    var quickRowTrailingColumnWidth: CGFloat {
        let contentWidth = MenuBarLayoutTokens.panelWidth - (MenuBarLayoutTokens.space8 * 2)
        return min(170, max(126, contentWidth * 0.44))
    }

    var proxyTabBody: some View {
        VStack(alignment: .leading, spacing: T.space6) {
            self.trafficOverview
            self.proxyQuickRows
            if !self.appViewModel.sortedProxyProviderNames.isEmpty {
                proxyProvidersSection
            }
            proxyGroupsSection
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var trafficOverview: some View {
        let sparklineHeight: CGFloat = 64
        let sparklineHorizontalInset = T.space4

        return ZStack {
            TrafficSparklineView(
                upValues: self.appViewModel.trafficHistoryUp,
                downValues: self.appViewModel.trafficHistoryDown)
                .frame(height: sparklineHeight)
                .padding(.horizontal, sparklineHorizontalInset)

            VStack(spacing: 0) {
                HStack(spacing: T.space6) {
                    self.cornerMetric(
                        symbol: "link",
                        value: "\(self.connectionsStore.connectionsCount)",
                        color: nativeIndigo)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    self.cornerMetric(
                        symbol: "arrow.up.circle",
                        value: ValueFormatter.speedAndTotal(
                            rate: self.appViewModel.traffic.up,
                            total: self.appViewModel.displayUpTotal),
                        color: nativeInfo,
                        iconTrailing: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Spacer(minLength: 0)

                HStack(spacing: T.space6) {
                    self.cornerMetric(
                        symbol: "memorychip",
                        value: ValueFormatter.bytesInteger(self.appViewModel.memory.inuse),
                        color: nativeTeal)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    self.cornerMetric(
                        symbol: "arrow.down.circle",
                        value: ValueFormatter.speedAndTotal(
                            rate: self.appViewModel.traffic.down,
                            total: self.appViewModel.displayDownTotal),
                        color: nativePositive.opacity(T.Opacity.solid),
                        iconTrailing: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, T.space4)
            .padding(.vertical, T.space2)
        }
        .frame(height: sparklineHeight)
        .padding(.top, T.space2)
        .cleanContentCard()
    }

    func cornerMetric(
        symbol: String,
        value: String,
        color: Color,
        iconTrailing: Bool = false) -> some View
    {
        let icon = Image(systemName: symbol)
            .font(.app(size: T.FontSize.caption, weight: .semibold))
            .foregroundStyle(color)
        let text = Text(value)
            .font(.app(size: T.FontSize.body, weight: .regular))
            .foregroundStyle(nativeSecondaryLabel)
            .lineLimit(1)
            .minimumScaleFactor(T.minimumScale)

        return HStack(spacing: iconTrailing ? T.space1 : T.space2) {
            if iconTrailing { text; icon } else { icon; text }
        }
    }

    var proxyQuickRows: some View {
        let localTargetDisplay = self.appViewModel.localProxyCommandTargetDisplay()
        let managedTargetDisplay = self.appViewModel.managedEndpointProxyCommandTargetDisplay()
        let showManagedTargetAction = localTargetDisplay != managedTargetDisplay

        return VStack(spacing: 0) {
            if self.appViewModel.isRemoteTarget {
                self.quickRowContent(
                    title: self.tr("ui.quick.current_config"),
                    symbol: "folder",
                    foreground: nativePurple)
                {
                    Text(self.tr("ui.machine.remote_readonly"))
                        .font(.app(size: T.FontSize.caption, weight: .regular))
                        .lineLimit(1)
                        .foregroundStyle(nativeTertiaryLabel)
                }
            } else {
                Button {
                    self.appViewModel.showSelectedConfigInFinder()
                } label: {
                    self.quickRowContent(
                        title: self.tr("ui.quick.current_config"),
                        symbol: "folder",
                        foreground: nativePurple)
                    {
                        Text(self.appViewModel.selectedConfigName)
                            .font(.app(size: T.FontSize.caption, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(nativeSecondaryLabel)
                    }
                }
                .buttonStyle(.plain)
                .help(self.tr("ui.quick.show_in_finder"))
            }

            if AppViewModel.systemProxyFeatureEnabled {
                self.systemProxyQuickToggleRow
            }

            self.quickToggleRow(
                title: self.tr("ui.quick.tun_mode"),
                symbol: "shield.lefthalf.filled",
                foreground: nativePositive,
                isDisabled: !self.appViewModel.isTunToggleEnabled,
                isOn: Binding(
                    get: { self.appViewModel.isTunEnabled },
                    set: { value in
                        Task { await self.appViewModel.toggleTunMode(value) }
                    }))

            self.quickRowContent(
                title: self.tr("ui.quick.copy_terminal"),
                symbol: "terminal",
                foreground: nativeInfo,
                trailingFitsContent: true)
            {
                HStack(spacing: 2) {
                    self.proxyCommandActionButton(
                        title: self.appViewModel.localProxyCommandHostDisplay(),
                        target: .local,
                        helpTitle: self.tr("ui.quick.copy_terminal"),
                        helpDetail: localTargetDisplay)
                    {
                        self.appViewModel.copyLocalProxyCommand()
                    }

                    if showManagedTargetAction {
                        self.proxyCommandActionButton(
                            title: self.appViewModel.managedEndpointProxyCommandHostDisplay(),
                            target: .currentEndpoint,
                            helpTitle: self.tr("ui.quick.copy_terminal_current_endpoint"),
                            helpDetail: managedTargetDisplay)
                        {
                            self.appViewModel.copyManagedEndpointProxyCommand()
                        }
                    }
                }
            }
            .onTapGesture {
                self.handleCopyProxyCommand(.local) {
                    self.appViewModel.copyLocalProxyCommand()
                }
            }
        }
        .menuRowPadding(vertical: T.space2)
        .cleanContentCard()
    }

    func proxyCommandActionButton(
        title: String,
        target: ProxyCommandCopyTarget,
        helpTitle: String,
        helpDetail: String,
        action: @escaping () -> Void) -> some View
    {
        let copied = self.copiedProxyCommandTarget == target
        let foreground = copied
            ? self.nativePositive.opacity(T.Opacity.solid)
            : self.nativeSecondaryLabel
        let iconForeground = copied
            ? self.nativePositive.opacity(T.Opacity.solid)
            : self.nativeTertiaryLabel

        return Button {
            self.handleCopyProxyCommand(target) {
                action()
            }
        } label: {
            HStack(spacing: T.space4) {
                Text(title)
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(T.minimumScale)
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.app(size: T.FontSize.caption, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }
            .padding(T.space2)
            .background {
                Capsule(style: .continuous)
                    .fill(copied ? self.nativePositive.opacity(T.Opacity.tint) : self.nativeBadgeFill)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(
                                copied
                                    ? self.nativePositive.opacity(0.18)
                                    : self.nativeControlBorder.opacity(0.42),
                                lineWidth: T.stroke)
                    }
            }
        }
        .buttonStyle(.plain)
        .help("\(helpTitle)\n\(helpDetail)")
    }

    var systemProxyRowDetailText: String? {
        if let failureHint = self.systemProxyInlineFailureText {
            return failureHint
        }

        return nil
    }

    func quickRowContent(
        title: String,
        symbol: String,
        foreground: Color,
        trailingWidth: CGFloat? = nil,
        trailingFitsContent: Bool = false,
        @ViewBuilder trailing: () -> some View) -> some View
    {
        HStack(spacing: T.space6) {
            self.quickIcon(symbol: symbol, foreground: foreground)
            Text(title)
                .font(.app(size: T.FontSize.body, weight: .medium))
                .foregroundStyle(nativePrimaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(T.minimumScale)
            Spacer(minLength: 0)
            if trailingFitsContent {
                trailing()
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                trailing()
                    .frame(width: trailingWidth ?? self.quickRowTrailingColumnWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, T.space4)
        .padding(.vertical, T.space2)
        .contentShape(Rectangle())
    }

    var systemProxyRowTitle: String {
        if let scopeLabel = self.systemProxyScopeLabel {
            return "\(self.tr("ui.quick.system_proxy")) (\(scopeLabel))"
        }
        return self.tr("ui.quick.system_proxy")
    }

    var systemProxyRowDetailColor: Color {
        if self.systemProxyInlineFailureText != nil {
            return nativeWarning.opacity(T.Opacity.solid)
        }
        return nativeSecondaryLabel
    }

    var systemProxyQuickToggleRow: some View {
        HStack(spacing: T.space6) {
            self.systemProxyCompositeIcon
            HStack(spacing: T.space2) {
                Text(self.systemProxyRowTitle)
                    .font(.app(size: T.FontSize.body, weight: .medium))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(T.minimumScale)

                if self.shouldShowSystemProxyRemoteWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(nativeWarning.opacity(T.Opacity.solid))
                        .help(self.tr("ui.system_proxy.remote_target_warning"))
                        .accessibilityLabel(self.tr("ui.system_proxy.remote_target_warning"))
                }
            }

            if let detailText = self.systemProxyRowDetailText {
                Text(detailText)
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .foregroundStyle(self.systemProxyRowDetailColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(T.minimumScale)
            }

            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { self.appViewModel.isSystemProxyEnabled },
                set: { value in
                    Task { await self.appViewModel.toggleSystemProxy(value) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(self.appViewModel.isProxySyncing)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, T.space4)
        .padding(.vertical, T.space2)
    }

    var systemProxyInlineFailureText: String? {
        guard !self.appViewModel.isSystemProxyEnabled else { return nil }
        return self.appViewModel.systemProxyOpenFailureHint?.trimmedNonEmpty
    }

    var systemProxyScopeLabel: String? {
        if self.appViewModel.isSystemProxyUsingRemoteCore {
            return self.tr("ui.machine.remote_label")
        }
        if self.appViewModel.isRemoteTarget {
            return self.tr("ui.machine.local_label")
        }
        return nil
    }

    var shouldShowSystemProxyRemoteWarning: Bool {
        self.appViewModel.isSystemProxyUsingRemoteCore
    }

    func quickToggleRow(
        title: String,
        symbol: String,
        foreground: Color,
        isDisabled: Bool,
        isOn: Binding<Bool>) -> some View
    {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            self.quickRowContent(
                title: title,
                symbol: symbol,
                foreground: foreground,
                trailingWidth: 50)
            {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(isDisabled)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    func quickIcon(symbol: String, foreground: Color) -> some View {
        Image(systemName: symbol)
            .font(.app(size: T.FontSize.body, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 18, height: 18, alignment: .center)
    }

    var systemProxyCompositeIcon: some View {
        ZStack {
            self.systemProxyCompositeIconLayer(
                tint: self.systemProxyBackgroundActivityTint,
                alignment: .leading)
            self.systemProxyCompositeIconLayer(
                tint: self.systemProxyHelperProcessTint,
                alignment: .trailing)
        }
        .frame(width: 18, height: 18)
        .help(self.systemProxyCompositeIconHelp)
    }

    func systemProxyCompositeIconLayer(tint: Color, alignment: Alignment) -> some View {
        Image(systemName: "network")
            .font(.app(size: T.FontSize.body, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .mask(alignment: alignment) {
                Rectangle()
                    .frame(width: 9)
            }
    }

    var systemProxyBackgroundActivityTint: Color {
        switch self.appViewModel.systemProxyBackgroundActivityAllowed {
        case .some(true):
            nativePositive.opacity(T.Opacity.solid)
        case .some(false):
            nativeCritical.opacity(T.Opacity.solid)
        case .none:
            nativeSecondaryLabel
        }
    }

    var systemProxyHelperProcessTint: Color {
        switch self.appViewModel.systemProxyHelperProcessRunning {
        case .some(true):
            nativePositive.opacity(T.Opacity.solid)
        case .some(false):
            nativeWarning.opacity(T.Opacity.solid)
        case .none:
            nativeSecondaryLabel
        }
    }

    var systemProxyBackgroundActivityHelp: String {
        let value = switch self.appViewModel.systemProxyBackgroundActivityAllowed {
        case .some(true):
            self.tr("ui.system_proxy.background_activity.allowed")
        case .some(false):
            self.tr("ui.system_proxy.background_activity.blocked")
        case .none:
            self.tr("ui.common.unknown")
        }
        return "\(self.tr("ui.system_proxy.background_activity")): \(value)"
    }

    var systemProxyHelperProcessHelp: String {
        let value = switch self.appViewModel.systemProxyHelperProcessRunning {
        case .some(true):
            self.tr("ui.system_proxy.helper_process.running")
        case .some(false):
            self.tr("ui.system_proxy.helper_process.stopped")
        case .none:
            self.tr("ui.common.unknown")
        }
        return "\(self.tr("ui.system_proxy.helper_process")): \(value)"
    }

    var systemProxyCompositeIconHelp: String {
        "\(self.systemProxyBackgroundActivityHelp)\n\(self.systemProxyHelperProcessHelp)"
    }
}
