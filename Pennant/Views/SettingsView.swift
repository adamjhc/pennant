import SwiftUI
import ServiceManagement
import Sparkle

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @State private var draftToken: String = ""
    @State private var editingRule: RuleEditorItem?
    @State private var selectedRuleID: RuleDraft.ID?
    @State private var showResetConfirm = false
    @State private var showDiscardConfirm = false
    @State private var showDeleteTokenConfirm = false
    @State private var saveResult: SaveResult?
    @State private var isSaving = false
    @State private var localDraft: SettingsDraft
    @State private var calendars: [CalendarDescriptor] = []
    @State private var calendarAuth: CalendarAuthorizationStatus = .unknown
    @State private var hasToken = false
    @State private var launchStatus: LaunchAtLoginStatus = .unknown
    @State private var checksForUpdates = false

    init(model: AppModel, updater: SPUUpdater) {
        self.model = model
        self.updater = updater
        _localDraft = State(initialValue: SettingsDraft.from(settings: model.settingsViewModel.saved))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !(calendarAuth == .fullAccess && hasToken) {
                    Section {
                        Label {
                            Text("Finish setup")
                            Text("Grant Calendar full access and paste a Slack user token, then click Save. Rules are optional.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                accessSection
                slackSection
                calendarSections
                rulesSection
                generalSection
            }
            .formStyle(.grouped)

            Divider()
            footerBar
        }
        .frame(minWidth: 640, minHeight: 680)
        .onAppear {
            localDraft = SettingsDraft.from(settings: model.settingsViewModel.saved)
            draftToken = ""
            refreshStatus()
            checksForUpdates = updater.automaticallyChecksForUpdates
            model.start()
        }
        // Pick up permission changes made in System Settings while the window was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
        .sheet(item: $editingRule) { item in
            RuleEditorSheet(
                rule: item.rule,
                isNew: item.isNew,
                previewProvider: { rule in
                    model.settingsViewModel.previewEvents(for: rule)
                },
                sampleTester: { rule, title in
                    model.settingsViewModel.sampleMatches(rule: rule, sampleTitle: title)
                },
                onSave: { updated in
                    if let idx = localDraft.rules.firstIndex(where: { $0.id == updated.id }) {
                        localDraft.rules[idx] = updated
                    } else {
                        localDraft.rules.append(updated)
                    }
                    selectedRuleID = updated.id
                    editingRule = nil
                },
                onCancel: { editingRule = nil }
            )
        }
        .confirmationDialog("Reset Pennant?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                try? model.settingsViewModel.resetApp()
                localDraft = SettingsDraft.from(settings: model.settingsViewModel.saved)
                draftToken = ""
                refreshStatus()
                saveResult = .success("Pennant was reset")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes rules, calendar selections, runtime state, and the stored Slack token. It does not revoke Calendar access or the Slack token remotely.")
        }
        .confirmationDialog("Remove Slack token?", isPresented: $showDeleteTokenConfirm) {
            Button("Remove Token", role: .destructive) {
                try? model.settingsViewModel.deleteToken()
                refreshStatus()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pennant will stop updating your Slack status until you add a new token.")
        }
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm) {
            Button("Discard", role: .destructive) {
                localDraft = SettingsDraft.from(settings: model.settingsViewModel.saved)
                draftToken = ""
                closeWindow()
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var accessSection: some View {
        Section("Calendar Access") {
            LabeledContent {
                switch calendarAuth {
                case .fullAccess:
                    EmptyView()
                case .notDetermined, .unknown:
                    Button("Request Access…") {
                        Task {
                            _ = await model.settingsViewModel.requestCalendarAccess()
                            refreshStatus()
                        }
                    }
                case .denied, .restricted, .writeOnly:
                    Button("Open System Settings…") {
                        model.calendarService.openSystemCalendarSettings()
                    }
                }
            } label: {
                StatusLabel(title: "Calendars", ok: calendarAuth == .fullAccess)
                Text(calendarAuth.userDescription)
            }
        }
    }

    private var slackSection: some View {
        Section {
            LabeledContent {
                if hasToken {
                    Button("Remove…", role: .destructive) {
                        showDeleteTokenConfirm = true
                    }
                }
            } label: {
                StatusLabel(title: "Slack user token", ok: hasToken)
                Text(model.settingsViewModel.connectionLabel)
            }
            SecureField(hasToken ? "Replace token" : "Token", text: $draftToken, prompt: Text("xoxp-…"))
                .autocorrectionDisabled()
        } header: {
            Text("Slack")
        } footer: {
            Text("Requires scopes: users.profile:read, users.profile:write, dnd:read, dnd:write")
        }
    }

    @ViewBuilder
    private var calendarSections: some View {
        if calendars.isEmpty {
            Section("Calendars") {
                Text("Grant Calendar full access to choose which calendars Pennant watches.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let groups = CalendarMapping.groupedBySource(calendars)
            ForEach(Array(groups.enumerated()), id: \.element.source) { index, group in
                Section {
                    ForEach(group.calendars) { cal in
                        Toggle(cal.title, isOn: calendarBinding(cal.id))
                            .toggleStyle(.checkbox)
                    }
                } header: {
                    if index == 0 {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Calendars — \(group.source)")
                            Spacer()
                            Button("Select All") { localDraft.disabledCalendarIDs.removeAll() }
                            Button("Select None") { localDraft.disabledCalendarIDs = Set(calendars.map(\.id)) }
                        }
                        .buttonStyle(.link)
                    } else {
                        Text(group.source)
                    }
                }
            }
        }
    }

    private var rulesSection: some View {
        Section {
            List(selection: $selectedRuleID) {
                ForEach(localDraft.rules) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.titleRegex.isEmpty ? "(empty pattern)" : rule.titleRegex)
                            .font(.body.monospaced())
                        Text("\(rule.statusEmoji) \(rule.statusText)\(rule.enableDND ? " · Do Not Disturb" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(rule.id)
                }
                .onMove { from, to in
                    localDraft.rules.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)
            .overlay {
                if localDraft.rules.isEmpty {
                    ContentUnavailableView(
                        "No Rules",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Add a rule to set a Slack status when an event title matches.")
                    )
                }
            }
            .contextMenu(forSelectionType: RuleDraft.ID.self) { ids in
                if let id = ids.first {
                    Button("Edit…") { editRule(id) }
                    Button("Delete", role: .destructive) { deleteRule(id) }
                }
            } primaryAction: { ids in
                if let id = ids.first { editRule(id) }
            }
            .onDeleteCommand {
                if let selectedRuleID { deleteRule(selectedRuleID) }
            }

            HStack(spacing: 0) {
                Button {
                    editingRule = RuleEditorItem(rule: RuleDraft(), isNew: true)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .help("Add a rule")
                Divider().frame(height: 16)
                Button {
                    if let selectedRuleID { deleteRule(selectedRuleID) }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .help("Remove the selected rule")
                .disabled(selectedRuleID == nil)
                Spacer()
                Button("Edit…") {
                    if let selectedRuleID { editRule(selectedRuleID) }
                }
                .disabled(selectedRuleID == nil)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Rules")
        } footer: {
            Text("Rules are checked top to bottom and the first match wins. Drag to reorder; double-click to edit.")
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle(isOn: $localDraft.launchAtLoginDesired) {
                Text("Launch at login")
                if let detail = launchStatus.userDetail {
                    Text(detail)
                }
            }
            if launchStatus == .requiresApproval {
                Button("Open Login Items Settings…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            // Applies immediately, like Sparkle's own preference, rather than waiting for Save.
            Toggle("Automatically check for updates", isOn: $checksForUpdates)
                .onChange(of: checksForUpdates) { _, enabled in
                    updater.automaticallyChecksForUpdates = enabled
                }
            LabeledContent("Version", value: Self.version)

            LabeledContent {
                Button("Reset…", role: .destructive) {
                    showResetConfirm = true
                }
            } label: {
                Text("Reset Pennant")
                Text("Deletes local settings, runtime state, and the Keychain token.")
            }
        }
    }

    private var footerBar: some View {
        HStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Verifying…")
                    .foregroundStyle(.secondary)
            } else if let saveResult {
                switch saveResult {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Cancel") {
                if isDirty {
                    showDiscardConfirm = true
                } else {
                    closeWindow()
                }
            }
            .keyboardShortcut(.cancelAction)
            Button("Save") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
        }
        .font(.callout)
        .padding()
    }

    // MARK: - Helpers

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var isDirty: Bool {
        let compare = SettingsDraft.from(settings: model.settingsViewModel.saved)
        return localDraft.rules != compare.rules
            || localDraft.disabledCalendarIDs != compare.disabledCalendarIDs
            || localDraft.launchAtLoginDesired != compare.launchAtLoginDesired
            || !draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !localDraft.disabledCalendarIDs.contains(id) },
            set: { enabled in
                if enabled {
                    localDraft.disabledCalendarIDs.remove(id)
                } else {
                    localDraft.disabledCalendarIDs.insert(id)
                }
            }
        )
    }

    private func editRule(_ id: RuleDraft.ID) {
        guard let rule = localDraft.rules.first(where: { $0.id == id }) else { return }
        editingRule = RuleEditorItem(rule: rule, isNew: false)
    }

    private func deleteRule(_ id: RuleDraft.ID) {
        localDraft.rules.removeAll { $0.id == id }
        if selectedRuleID == id { selectedRuleID = nil }
    }

    private func refreshStatus() {
        let vm = model.settingsViewModel
        vm.reloadCalendars()
        calendars = vm.calendars
        calendarAuth = model.calendarService.authorizationStatus()
        hasToken = vm.hasToken
        launchStatus = model.launchAtLogin.status()
    }

    private func save() async {
        isSaving = true
        saveResult = nil
        defer { isSaving = false }

        let vm = model.settingsViewModel
        vm.updateDraft { d in
            d.rules = localDraft.rules
            d.disabledCalendarIDs = localDraft.disabledCalendarIDs
            d.launchAtLoginDesired = localDraft.launchAtLoginDesired
            d.replacementToken = draftToken
        }

        if let error = await vm.save() {
            saveResult = .failure(error.userDescription(rules: localDraft.rules))
            return
        }
        localDraft = SettingsDraft.from(settings: vm.saved)
        draftToken = ""
        refreshStatus()
        saveResult = .success("Saved")
        model.settingsDidSave()
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

private enum SaveResult {
    case success(String)
    case failure(String)
}

private struct RuleEditorItem: Identifiable {
    var rule: RuleDraft
    var isNew: Bool
    var id: RuleDraft.ID { rule.id }
}

private struct StatusLabel: View {
    var title: String
    var ok: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}

struct RuleEditorSheet: View {
    @State var rule: RuleDraft
    var isNew: Bool
    var previewProvider: (RuleDraft) -> [CalendarOccurrence]
    var sampleTester: (RuleDraft, String) -> Bool
    var onSave: (RuleDraft) -> Void
    var onCancel: () -> Void

    @State private var sampleTitle = "Focus block"
    @State private var validationMessage: String?
    @State private var previews: [CalendarOccurrence] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Title pattern", text: $rule.titleRegex, prompt: Text("e.g. focus|deep work"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    TextField("Status text", text: $rule.statusText, prompt: Text("In a meeting"))
                    TextField("Emoji", text: $rule.statusEmoji, prompt: Text(":calendar:"))
                        .autocorrectionDisabled()
                    Toggle("Turn on Do Not Disturb", isOn: $rule.enableDND)
                } header: {
                    Text(isNew ? "New Rule" : "Edit Rule")
                } footer: {
                    Text("The pattern is a case-insensitive regular expression matched anywhere in the event title. Use a Slack emoji shortcode such as :spiral_calendar_pad:.")
                }

                Section("Test") {
                    TextField("Sample title", text: $sampleTitle)
                    LabeledContent("Result") {
                        if sampleTester(rule, sampleTitle) {
                            Label("Matches", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("No match", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Upcoming Matches (7 days)") {
                    if previews.isEmpty {
                        Text("No upcoming events match this pattern.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(previews.prefix(10), id: \.id) { occ in
                            LabeledContent {
                                Text(occ.start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                            } label: {
                                Text(occ.title)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    if let error = RuleValidator.validate(rule.asRule()) {
                        validationMessage = error.userDescription
                    } else {
                        onSave(rule)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        // Live preview; debounce so each keystroke doesn't hit EventKit.
        .task(id: rule.titleRegex) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            previews = previewProvider(rule)
        }
        .onChange(of: rule) {
            validationMessage = nil
        }
    }
}

// MARK: - User-facing text

private extension CalendarAuthorizationStatus {
    var userDescription: String {
        switch self {
        case .fullAccess: return "Full access granted"
        case .notDetermined: return "Access not requested yet"
        case .denied: return "Access denied — allow Pennant in System Settings"
        case .restricted: return "Access is restricted on this Mac"
        case .writeOnly: return "Pennant needs full access, not add-only"
        case .unknown: return "Status unknown"
        }
    }
}

private extension LaunchAtLoginStatus {
    var userDetail: String? {
        switch self {
        case .requiresApproval: return "Waiting for approval in System Settings"
        case .notFound: return "The login item could not be found"
        case .enabled, .notRegistered, .unknown: return nil
        }
    }
}

private extension RuleValidationError {
    var userDescription: String {
        switch self {
        case .emptyRegex: return "Enter a title pattern."
        case .invalidRegex: return "The title pattern isn't a valid regular expression."
        case .emptyStatusText: return "Enter status text."
        case .statusTextTooLong: return "Status text must be \(RuleValidator.maxStatusTextLength) characters or fewer."
        case .invalidEmoji: return "Emoji must be a Slack shortcode like :calendar:."
        }
    }
}

private extension SettingsValidationError {
    func userDescription(rules: [RuleDraft]) -> String {
        switch self {
        case .rule(let index, let error):
            let name = rules.indices.contains(index) ? "“\(rules[index].titleRegex)”" : "\(index + 1)"
            return "Rule \(name): \(error.userDescription)"
        case .tokenRequired: return "Paste a Slack user token to continue."
        case .tokenInvalid: return "That doesn't look like a valid Slack user token (xoxp-…)."
        case .tokenMissingScopes(let scopes): return "Token is missing scopes: \(scopes.sorted().joined(separator: ", "))."
        case .tokenOffline: return "Couldn't reach Slack to verify the token. Check your connection and try again."
        case .calendarAccessRequired: return "Pennant needs full Calendar access."
        }
    }
}
