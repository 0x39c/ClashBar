import AppKit
import SwiftUI

private typealias T = MenuBarLayoutTokens

private enum LocalConfigEditorSheetTokens {
    static let width: CGFloat = T.panelWidth
    static let contentPadding: CGFloat = T.space8 * 2
    static let rowSpacing: CGFloat = T.space8
    static let fieldSpacing: CGFloat = T.space6
    static let buttonHeight: CGFloat = 30
}

struct AddProxyProviderSheet: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var name = ""
    @State private var isFetchingName = false
    @State private var isSubmitting = false
    @FocusState private var isURLFocused: Bool

    private var canSubmit: Bool {
        self.url.trimmedNonEmpty != nil && self.name.trimmedNonEmpty != nil && !self.isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LocalConfigEditorSheetTokens.rowSpacing) {
            self.header(title: self.tr("ui.action.add_proxy_provider"), symbol: "externaldrive.fill")

            self.labeledField(
                title: self.tr("app.provider.add.url_label"),
                placeholder: self.tr("app.provider.add.url_placeholder"),
                text: self.$url)
                .focused(self.$isURLFocused)

            VStack(alignment: .leading, spacing: LocalConfigEditorSheetTokens.fieldSpacing) {
                Text(self.tr("app.provider.add.name_label"))
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .foregroundStyle(nativeSecondaryLabel)
                HStack(spacing: T.space6) {
                    TextField(self.tr("app.provider.add.name_placeholder"), text: self.$name)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await self.fetchName() }
                    } label: {
                        if self.isFetchingName {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(self.tr("app.provider.add.fetch_name"))
                        }
                    }
                    .frame(width: 74, height: LocalConfigEditorSheetTokens.buttonHeight)
                    .disabled(self.url.trimmedNonEmpty == nil || self.isFetchingName)
                }
            }

            self.actions {
                await self.submit()
            }
        }
        .padding(LocalConfigEditorSheetTokens.contentPadding)
        .frame(width: LocalConfigEditorSheetTokens.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { self.isURLFocused = true }
    }

    private func fetchName() async {
        guard let urlString = self.url.trimmedNonEmpty else {
            NSSound.beep()
            return
        }

        self.isFetchingName = true
        defer { self.isFetchingName = false }
        if let suggested = await self.appViewModel.suggestedProxyProviderName(from: urlString) {
            self.name = suggested
        } else {
            NSSound.beep()
        }
    }

    private func submit() async {
        guard self.canSubmit else {
            NSSound.beep()
            return
        }

        self.isSubmitting = true
        await self.appViewModel.addProxyProviderToLocalDefaultConfig(name: self.name, url: self.url)
        self.isSubmitting = false
        self.dismiss()
    }

    private func header(title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.app(size: T.FontSize.title, weight: .semibold))
            .foregroundStyle(nativePrimaryLabel)
    }

    private func labeledField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: LocalConfigEditorSheetTokens.fieldSpacing) {
            Text(title)
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .foregroundStyle(nativeSecondaryLabel)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func actions(submit: @escaping () async -> Void) -> some View {
        HStack(spacing: T.space8) {
            Button(self.tr("ui.action.cancel")) {
                self.dismiss()
            }
            Spacer()
            Button {
                Task { await submit() }
            } label: {
                if self.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(self.tr("ui.action.add_exception"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!self.canSubmit)
        }
        .padding(.top, T.space4)
    }
}

struct AddRuleSheet: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var ruleType = "DOMAIN-SUFFIX"
    @State private var payload = ""
    @State private var policy = "DIRECT"
    @State private var isSubmitting = false
    @FocusState private var isPayloadFocused: Bool
    private let onSubmitted: (() -> Void)?

    init(
        initialRuleType: String = "DOMAIN-SUFFIX",
        initialPayload: String = "",
        initialPolicy: String = "DIRECT",
        onSubmitted: (() -> Void)? = nil)
    {
        self._ruleType = State(initialValue: initialRuleType)
        self._payload = State(initialValue: initialPayload)
        self._policy = State(initialValue: initialPolicy)
        self.onSubmitted = onSubmitted
    }

    private let ruleTypes = [
        "DOMAIN-SUFFIX",
        "DOMAIN",
        "DOMAIN-KEYWORD",
        "DOMAIN-REGEX",
        "IP-CIDR",
        "IP-CIDR6",
        "GEOIP",
        "GEOSITE",
        "RULE-SET",
        "PROCESS-NAME",
        "PROCESS-PATH",
        "SRC-IP-CIDR",
        "DST-PORT",
    ]

    private var policyOptions: [String] {
        var options: [String] = []
        var seen: Set<String> = []
        for policy in ["DIRECT", "REJECT", "REJECT-DROP", "PASS"] + self.appViewModel.proxyGroups.map(\.name).sorted() {
            guard let normalized = policy.trimmedNonEmpty else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            options.append(normalized)
        }
        return options
    }

    private var canSubmit: Bool {
        self.ruleType.trimmedNonEmpty != nil &&
            self.payload.trimmedNonEmpty != nil &&
            self.policy.trimmedNonEmpty != nil &&
            !self.isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LocalConfigEditorSheetTokens.rowSpacing) {
            Label(self.tr("ui.action.add_rule"), systemImage: "plus")
                .font(.app(size: T.FontSize.title, weight: .semibold))
                .foregroundStyle(nativePrimaryLabel)

            HStack(alignment: .top, spacing: T.space8) {
                self.pickerField(
                    title: self.tr("app.rule.add.type_label"),
                    selection: self.$ruleType,
                    options: self.ruleTypes)
                    .frame(width: 150, alignment: .leading)

                self.pickerField(
                    title: self.tr("app.rule.add.policy_label"),
                    selection: self.$policy,
                    options: self.policyOptions)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            self.payloadField

            HStack(spacing: T.space8) {
                Button(self.tr("ui.action.cancel")) {
                    self.dismiss()
                }
                Spacer()
                Button {
                    Task { await self.submit() }
                } label: {
                    if self.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(self.tr("ui.action.add_exception"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!self.canSubmit)
            }
            .padding(.top, T.space4)
        }
        .padding(LocalConfigEditorSheetTokens.contentPadding)
        .frame(width: LocalConfigEditorSheetTokens.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { self.isPayloadFocused = true }
    }

    private var payloadField: some View {
        VStack(alignment: .leading, spacing: LocalConfigEditorSheetTokens.fieldSpacing) {
            Text(self.tr("app.rule.add.payload_label"))
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .foregroundStyle(nativeSecondaryLabel)
            TextField(self.tr("app.rule.add.payload_placeholder"), text: self.$payload)
                .textFieldStyle(.roundedBorder)
                .focused(self.$isPayloadFocused)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerField(title: String, selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: LocalConfigEditorSheetTokens.fieldSpacing) {
            Text(title)
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .foregroundStyle(nativeSecondaryLabel)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option)
                        .tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() async {
        guard self.canSubmit else {
            NSSound.beep()
            return
        }

        self.isSubmitting = true
        let rule = [self.ruleType.trimmed, self.payload.trimmed, self.policy.trimmed].joined(separator: ",")
        let success = await self.appViewModel.addRuleToSelectedLocalConfig(ruleText: rule)
        self.isSubmitting = false
        if success {
            self.onSubmitted?()
            self.dismiss()
        }
    }
}

struct ConfirmDeleteRuleSheet: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let rule: RuleItem
    @State private var isDeleting = false

    private var ruleText: String {
        let input = LocalRuleMutationInput(
            type: self.rule.type?.trimmedNonEmpty ?? "",
            payload: self.rule.payload?.trimmedNonEmpty ?? "",
            policy: self.rule.proxy?.trimmedNonEmpty ?? "")
        let normalized = LocalRuleMutator().normalizedInput(input)
        return [normalized.type, normalized.payload, normalized.policy].joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LocalConfigEditorSheetTokens.rowSpacing) {
            Label(self.tr("app.rule.delete.confirm.title"), systemImage: "trash")
                .font(.app(size: T.FontSize.title, weight: .semibold))
                .foregroundStyle(nativeCritical)

            Text(self.tr("app.rule.delete.confirm.message"))
                .font(.app(size: T.FontSize.body, weight: .regular))
                .foregroundStyle(nativeSecondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            Text(self.ruleText)
                .font(.app(size: T.FontSize.caption, weight: .medium).monospaced())
                .foregroundStyle(nativePrimaryLabel)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, T.space6)
                .padding(.vertical, T.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(nativeControlFill)
                .clipShape(RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous))

            HStack(spacing: T.space8) {
                Button(self.tr("ui.action.cancel")) {
                    self.dismiss()
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await self.deleteRule() }
                } label: {
                    if self.isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(self.tr("ui.action.delete"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.isDeleting)
            }
            .padding(.top, T.space4)
        }
        .padding(LocalConfigEditorSheetTokens.contentPadding)
        .frame(width: LocalConfigEditorSheetTokens.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func deleteRule() async {
        guard !self.isDeleting else { return }
        self.isDeleting = true
        await self.appViewModel.deleteRuleFromSelectedLocalConfig(self.rule)
        self.isDeleting = false
        self.dismiss()
    }
}
