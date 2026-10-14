import SwiftUI
import UniformTypeIdentifiers

struct RulesTabView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @StateObject private var viewModel = RulesViewModel()
    @State private var hoveredRuleIndex: Int?
    @State private var showAddRuleSheet = false
    @State private var draggingRule: RuleItem?
    @State private var dropTargetRule: RuleItem?
    @State private var rulePendingDeletion: RuleItem?

    private enum RulesLayout {
        static let targetWidth: CGFloat = 120
        static let policyWidth: CGFloat = 40
        static let groupWidth: CGFloat = 56
        static let usageColumnWidth: CGFloat = 42
        static let rowActionSize: CGFloat = 18
        static let statsSpacing: CGFloat = 4
    }

    var body: some View {
        let visibleRules = self.viewModel.visibleRules
        let providerLookup = self.viewModel.providerLookup

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: MenuBarLayoutTokens.space8) {
                    self.rulesStatChip(title: self.tr("ui.rule.stats.rules"), value: "\(self.appViewModel.rulesCount)")
                    self.rulesStatChip(
                        title: self.tr("ui.rule.stats.sets"),
                        value: "\(self.appViewModel.providerRuleCount)")
                }

                Spacer(minLength: 0)
                HStack(spacing: MenuBarLayoutTokens.space4) {
                    self.rulesAddButton
                    self.rulesRefreshButton
                }
            }
            .padding(.vertical, MenuBarLayoutTokens.space6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(nativeSeparator)
                    .frame(height: MenuBarLayoutTokens.stroke)
            }

            HStack(spacing: 0) {
                Color.clear.frame(width: 24)
                Text(self.tr("ui.rules.column.target_type"))
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .medium))
                    .foregroundStyle(nativeTertiaryLabel)
                    .frame(width: RulesLayout.targetWidth, alignment: .leading)
                    .padding(.trailing, MenuBarLayoutTokens.space6)
                Text(self.tr("ui.rules.column.policy"))
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .medium))
                    .foregroundStyle(nativeTertiaryLabel)
                    .padding(.leading, MenuBarLayoutTokens.space6)
                    .frame(width: RulesLayout.policyWidth, alignment: .leading)
                Text(self.tr("ui.rules.column.stats"))
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .medium))
                    .foregroundStyle(nativeTertiaryLabel)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .textCase(.uppercase)
            .padding(.horizontal, MenuBarLayoutTokens.space4)
            .padding(.vertical, MenuBarLayoutTokens.space6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(nativeSeparator)
                    .frame(height: MenuBarLayoutTokens.stroke)
            }

            if visibleRules.isEmpty {
                Text(self.tr("ui.empty.rules"))
                    .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .regular))
                    .foregroundStyle(nativeSecondaryLabel)
                    .padding(.horizontal, MenuBarLayoutTokens.space4)
                    .padding(.vertical, MenuBarLayoutTokens.space8)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRules.enumerated()), id: \.offset) { index, rule in
                        self.rulesRow(
                            rule: rule,
                            index: index,
                            rules: visibleRules,
                            providerLookup: providerLookup,
                            isDropTarget: self.dropTargetRule == rule)

                        if index < visibleRules.count - 1 {
                            Rectangle()
                                .fill(nativeSeparator)
                                .frame(height: MenuBarLayoutTokens.stroke)
                        }
                    }
                }
            }
        }
        .cleanContentCard()
        .sheet(isPresented: self.$showAddRuleSheet) {
            AddRuleSheet()
                .environmentObject(self.appViewModel)
        }
        .sheet(isPresented: self.deleteRuleSheetBinding) {
            if let rule = self.rulePendingDeletion {
                ConfirmDeleteRuleSheet(rule: rule)
                    .environmentObject(self.appViewModel)
            }
        }
        .onAppear { self.refreshData() }
        .onChange(of: self.appViewModel.ruleItems) { _ in self.refreshData() }
        .onChange(of: self.appViewModel.ruleProviders) { _ in self.refreshData() }
    }

    private func refreshData() {
        self.viewModel.updateVisibleRules(
            items: self.appViewModel.ruleItems,
            providers: self.appViewModel.ruleProviders)
    }

    private var deleteRuleSheetBinding: Binding<Bool> {
        Binding(
            get: { self.rulePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    self.rulePendingDeletion = nil
                }
            })
    }

    func rulesStatChip(title: String, value: String) -> some View {
        HStack(spacing: MenuBarLayoutTokens.space4) {
            Text(title.uppercased())
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                .foregroundStyle(nativeTertiaryLabel)
            Text(value)
                .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .bold))
                .foregroundStyle(nativePrimaryLabel)
        }
        .padding(.horizontal, MenuBarLayoutTokens.space6)
        .padding(.vertical, MenuBarLayoutTokens.space2)
    }

    var rulesRefreshButton: some View {
        self.compactTopIcon(
            "arrow.clockwise",
            label: self.tr("ui.action.refresh"),
            toneOverride: nativeInfo,
            isLoading: self.appViewModel.isRuleProvidersRefreshing)
        {
            await self.appViewModel.refreshRuleProviders()
        }
        .help(self.tr("ui.action.refresh"))
        .opacity(self.appViewModel.isRuleProvidersRefreshing ? 0.6 : 1)
    }

    var rulesAddButton: some View {
        self.compactTopIcon(
            "plus",
            label: self.tr("ui.action.add_rule"),
            toneOverride: nativePositive)
        {
            self.showAddRuleSheet = true
        }
        .help(self.tr("ui.action.add_rule"))
        .disabled(!self.appViewModel.canEditRulesInSelectedLocalConfig)
        .opacity(self.appViewModel.canEditRulesInSelectedLocalConfig ? 1 : 0.6)
    }

    func rulesRow(
        rule: RuleItem,
        index: Int,
        rules: [RuleItem],
        providerLookup: [String: ProviderDetail],
        isDropTarget: Bool) -> some View
    {
        let hovered = self.hoveredRuleIndex == index
        let typeText = (rule.type.trimmedNonEmpty ?? self.tr("ui.common.na")).uppercased()
        let targetText = rule.payload.trimmedNonEmpty ?? self.tr("ui.common.na")
        let policyText = rule.proxy.trimmedNonEmpty ?? self.tr("ui.common.na")
        let iconSpec = self.ruleTypeIcon(for: typeText)
        let badge = self.rulePolicyBadge(for: policyText)
        let stats = self.ruleStats(payload: targetText, providerLookup: providerLookup)
        let usage = self.ruleUsage(rule.extra)

        return HStack(spacing: 0) {
            Image(systemName: iconSpec.symbol)
                .font(.app(size: MenuBarLayoutTokens.FontSize.subhead, weight: .medium))
                .foregroundStyle(iconSpec.color)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: MenuBarLayoutTokens.space1) {
                Text(targetText)
                    .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .medium))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(typeText)
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .regular))
                    .foregroundStyle(nativeTertiaryLabel)
                    .lineLimit(1)
            }
            .frame(width: RulesLayout.targetWidth, alignment: .leading)
            .padding(.trailing, MenuBarLayoutTokens.space6)

            HStack(spacing: MenuBarLayoutTokens.space1) {
                if let symbol = badge.symbol {
                    Image(systemName: symbol)
                        .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                        .foregroundStyle(badge.color)
                }
                Text(policyText)
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .medium))
                    .foregroundStyle(badge.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: RulesLayout.policyWidth, alignment: .leading)

            HStack(alignment: .top, spacing: RulesLayout.statsSpacing) {
                HStack(alignment: .top, spacing: RulesLayout.statsSpacing) {
                    self.ruleUsageMetricColumn(count: usage.hitCount, text: usage.hitText, color: nativePositive.opacity(MenuBarLayoutTokens.Opacity.solid))
                    self.ruleUsageMetricColumn(count: usage.missCount, text: usage.missText, color: nativeWarning.opacity(MenuBarLayoutTokens.Opacity.solid))
                }
                .frame(width: (RulesLayout.usageColumnWidth * 2) + RulesLayout.statsSpacing, alignment: .trailing)

                self.ruleGroupStatsOrDelete(rule: rule, stats: stats, isVisible: hovered)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, MenuBarLayoutTokens.space4)
        .padding(.vertical, MenuBarLayoutTokens.space2)
        .contentShape(Rectangle())
        .background(nativeHoverRowBackground(hovered || isDropTarget))
        .overlay(alignment: .leading) {
            if isDropTarget && self.appViewModel.canEditRulesInSelectedLocalConfig {
                Rectangle()
                    .fill(nativeAccent.opacity(MenuBarLayoutTokens.Opacity.solid))
                    .frame(width: 2)
            }
        }
        .onDrag {
            guard self.appViewModel.canEditRulesInSelectedLocalConfig else {
                return NSItemProvider()
            }
            self.draggingRule = rule
            return NSItemProvider(object: self.ruleDragIdentifier(for: rule) as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: RuleDropDelegate(
                targetRule: rule,
                rules: rules,
                draggingRule: self.$draggingRule,
                dropTargetRule: self.$dropTargetRule,
                canEdit: self.appViewModel.canEditRulesInSelectedLocalConfig)
            { sourceRule, targetRule, rules in
                Task {
                    await self.moveDraggedRule(sourceRule, to: targetRule, in: rules)
                }
            })
        .onHover { self.hoveredRuleIndex = self.nextHovered(
            current: self.hoveredRuleIndex, target: index, isHovering: $0) }
    }

    func ruleDragIdentifier(for rule: RuleItem) -> String {
        [
            rule.type ?? "",
            rule.payload ?? "",
            rule.proxy ?? "",
        ].joined(separator: "\u{1f}")
    }

    func moveDraggedRule(_ sourceRule: RuleItem, to targetRule: RuleItem, in rules: [RuleItem]) async {
        guard self.appViewModel.canEditRulesInSelectedLocalConfig,
              sourceRule != targetRule,
              let sourceIndex = rules.firstIndex(of: sourceRule),
              let targetIndex = rules.firstIndex(of: targetRule)
        else {
            return
        }

        if sourceIndex < targetIndex {
            if self.isFinalRule(targetRule) {
                await self.appViewModel.moveRuleInSelectedLocalConfig(sourceRule, before: targetRule)
            } else {
                await self.appViewModel.moveRuleInSelectedLocalConfig(sourceRule, after: targetRule)
            }
        } else {
            await self.appViewModel.moveRuleInSelectedLocalConfig(sourceRule, before: targetRule)
        }
    }

    func isFinalRule(_ rule: RuleItem) -> Bool {
        guard let type = rule.type?.trimmed.uppercased() else { return false }
        return type == "MATCH" || type == "FINAL"
    }

    func ruleGroupStatsOrDelete(
        rule: RuleItem,
        stats: (count: Int, updatedText: String?, hasProvider: Bool),
        isVisible: Bool) -> some View
    {
        let canEdit = self.appViewModel.canEditRulesInSelectedLocalConfig

        return ZStack(alignment: .trailing) {
            VStack(alignment: .trailing, spacing: MenuBarLayoutTokens.space1) {
                Text("\(stats.count)")
                    .font(.app(size: MenuBarLayoutTokens.FontSize.body, weight: .regular))
                    .foregroundStyle(stats.hasProvider ? nativeSecondaryLabel : nativeTertiaryLabel)
                if let updatedText = stats.updatedText {
                    Text(updatedText)
                        .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .regular))
                        .foregroundStyle(nativeTertiaryLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .opacity(isVisible && canEdit ? 0 : 1)

            self.ruleRowActionButton(
                symbol: "trash",
                tint: nativeCritical,
                help: self.tr("ui.action.delete"),
                isEnabled: canEdit)
            {
                await MainActor.run {
                    self.rulePendingDeletion = rule
                }
            }
            .opacity(isVisible && canEdit ? 1 : 0)
            .allowsHitTesting(isVisible && canEdit)
        }
        .frame(width: RulesLayout.groupWidth, height: 30, alignment: .trailing)
    }

    func ruleRowActionButton(
        symbol: String,
        tint: Color,
        help: String,
        isEnabled: Bool,
        action: @escaping () async -> Void) -> some View
    {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                .foregroundStyle(tint.opacity(MenuBarLayoutTokens.Opacity.solid))
                .frame(width: RulesLayout.rowActionSize, height: RulesLayout.rowActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }

    func ruleTypeIcon(for type: String) -> (symbol: String, color: Color) {
        let lower = type.lowercased()
        if lower.contains("ipcidr") {
            return ("globe.americas.fill", nativeInfo.opacity(MenuBarLayoutTokens.Opacity.solid))
        }
        if lower.contains("domain") || lower.contains("suffix") || lower.contains("keyword") {
            return ("network", nativeTeal.opacity(MenuBarLayoutTokens.Opacity.solid))
        }
        if lower.contains("ruleset") {
            return ("list.bullet.rectangle.fill", nativeWarning.opacity(MenuBarLayoutTokens.Opacity.solid))
        }
        return ("circle.grid.2x2.fill", nativeIndigo.opacity(MenuBarLayoutTokens.Opacity.solid))
    }

    func rulePolicyBadge(for policy: String) -> (symbol: String?, color: Color) {
        let lower = policy.lowercased()
        if lower.contains("fishy") {
            return (
                symbol: "exclamationmark.triangle.fill",
                color: nativeAccent.opacity(MenuBarLayoutTokens.Opacity.solid))
        }
        return (
            symbol: nil,
            color: nativeSecondaryLabel)
    }

    func ruleStats(
        payload: String,
        providerLookup: [String: ProviderDetail]) -> (count: Int, updatedText: String?, hasProvider: Bool)
    {
        let payloadTrimmed = payload.trimmed
        guard !payloadTrimmed.isEmpty, payloadTrimmed != self.tr("ui.common.na") else {
            return (count: 0, updatedText: nil, hasProvider: false)
        }

        if let provider = providerLookup[payloadTrimmed.lowercased()] {
            let count = max(0, provider.ruleCount ?? 0)
            return (
                count: count,
                updatedText: ValueFormatter.relativeTime(from: provider.updatedAt, language: self.language),
                hasProvider: true)
        }
        return (count: 0, updatedText: nil, hasProvider: false)
    }

    func ruleUsage(_ extra: RuleExtra?) -> (hitCount: Int, hitText: String?, missCount: Int, missText: String?) {
        (
            hitCount: max(0, extra?.hitCount ?? 0),
            hitText: self.ruleUsageRelativeTime(extra?.hitAt),
            missCount: max(0, extra?.missCount ?? 0),
            missText: self.ruleUsageRelativeTime(extra?.missAt))
    }

    func ruleUsageMetricColumn(count: Int, text: String?, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: MenuBarLayoutTokens.space1) {
            Text("\(count)")
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            if let text {
                Text(text)
                    .font(.app(size: MenuBarLayoutTokens.FontSize.caption, weight: .regular))
                    .foregroundStyle(nativeTertiaryLabel)
                    .lineLimit(1)
            }
        }
        .frame(width: RulesLayout.usageColumnWidth, alignment: .trailing)
    }

    func ruleUsageRelativeTime(_ input: String?) -> String? {
        let text = ValueFormatter.relativeTime(from: input, language: self.language)
        return text == "--" ? nil : text
    }
}

private struct RuleDropDelegate: DropDelegate {
    let targetRule: RuleItem
    let rules: [RuleItem]
    @Binding var draggingRule: RuleItem?
    @Binding var dropTargetRule: RuleItem?
    let canEdit: Bool
    let onMove: (RuleItem, RuleItem, [RuleItem]) -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        guard self.canEdit,
              let sourceRule = self.draggingRule,
              sourceRule != self.targetRule
        else {
            return false
        }
        return true
    }

    func dropEntered(info _: DropInfo) {
        guard self.canEdit,
              let sourceRule = self.draggingRule,
              sourceRule != self.targetRule
        else {
            return
        }
        self.dropTargetRule = self.targetRule
    }

    func dropExited(info _: DropInfo) {
        if self.dropTargetRule == self.targetRule {
            self.dropTargetRule = nil
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        defer {
            self.draggingRule = nil
            self.dropTargetRule = nil
        }

        guard self.canEdit,
              let sourceRule = self.draggingRule,
              sourceRule != self.targetRule
        else {
            return false
        }

        self.onMove(sourceRule, self.targetRule, self.rules)
        return true
    }
}
