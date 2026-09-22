import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draftToken: String = ""
    @State private var editingRule: RuleDraft?
    @State private var showRuleEditor = false
    @State private var showResetConfirm = false
    @State private var showDiscardConfirm = false
    @State private var saveMessage: String?
    @State private var isSaving = false
    @State private var localDraft: SettingsDraft
    @State private var calendars: [CalendarDescriptor] = []
    @State private var calendarStatus: String = "Unknown"
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _localDraft = State(initialValue: SettingsDraft.from(settings: model.settingsViewModel.saved))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.settingsViewModel.setupComplete {
                setupBanner
            }
            Form {
                Section("Setup") {
                    HStack {
                        Image(systemName: model.menuSnapshot.calendarAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(model.menuSnapshot.calendarAuthorized ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text("Calendar access")
                            Text(calendarStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.menuSnapshot.calendarAuthorized ? "Recheck" : "Request Access") {
                            Task {
                                _ = await model.settingsViewModel.requestCalendarAccess()
                                refreshCalendars()
                            }
                        }
                        if !model.menuSnapshot.calendarAuthorized {
                            Button("Open System Settings") {
                                model.calendarService.openSystemCalendarSettings()
                            }
                        }
                    }

                    HStack {
                        Image(systemName: model.settingsViewModel.hasToken ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(model.settingsViewModel.hasToken ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text("Slack user token")
                            Text(model.settingsViewModel.connectionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    SecureField("xoxp-…", text: $draftToken)
                        .textFieldStyle(.roundedBorder)
                    Text("Requires scopes: users.profile:read, users.profile:write, dnd:read, dnd:write")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.settingsViewModel.hasToken {
                        Button("Delete Token", role: .destructive) {
                            try? model.settingsViewModel.deleteToken()
                        }
                    }
                }

                Section("Calendars") {
                    HStack {
                        Button("Select All") {
                            localDraft.disabledCalendarIDs.removeAll()
                        }
                        Button("Select None") {
                            localDraft.disabledCalendarIDs = Set(calendars.map(\.id))
                        }
                        Spacer()
                        Button("Refresh") { refreshCalendars() }
                    }
                    ForEach(CalendarMapping.groupedBySource(calendars), id: \.source) { group in
                        Text(group.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(group.calendars) { cal in
                            Toggle(isOn: Binding(
                                get: { !localDraft.disabledCalendarIDs.contains(cal.id) },
                                set: { enabled in
                                    if enabled {
                                        localDraft.disabledCalendarIDs.remove(cal.id)
                                    } else {
                                        localDraft.disabledCalendarIDs.insert(cal.id)
                                    }
                                }
                            )) {
                                Text(cal.title)
                            }
                        }
                    }
                    if calendars.isEmpty {
                        Text("Grant Calendar Full Access to list calendars.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Rules (top wins — drag to reorder)") {
                    if localDraft.rules.isEmpty {
                        Text("No rules yet. Add a rule to start matching event titles.")
                            .foregroundStyle(.secondary)
                    }
                    List {
                        ForEach(localDraft.rules) { rule in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(rule.titleRegex.isEmpty ? "(empty pattern)" : rule.titleRegex)
                                        .font(.body)
                                    Text("\(rule.statusEmoji) \(rule.statusText)\(rule.enableDND ? " · DND" : "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Edit") {
                                    editingRule = rule
                                    showRuleEditor = true
                                }
                                Button(role: .destructive) {
                                    localDraft.rules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onMove(perform: moveRules)
                    }
                    .frame(minHeight: 120)
                    Button("Add Rule") {
                        editingRule = RuleDraft()
                        showRuleEditor = true
                    }
                }

                Section("General") {
                    Toggle("Launch at Login", isOn: $localDraft.launchAtLoginDesired)
                    Text(launchStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset App…", role: .destructive) {
                        showResetConfirm = true
                    }
                    Text("Reset deletes local settings, runtime state, and the Keychain token. It does not revoke Calendar access or the Slack token remotely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(saveMessage.contains("Saved") ? .green : .red)
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
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 680)
        .onAppear {
            localDraft = SettingsDraft.from(settings: model.settingsViewModel.saved)
            draftToken = ""
            refreshCalendars()
            model.start()
        }
        .sheet(isPresented: $showRuleEditor) {
            if let bindingRule = editingRule {
                RuleEditorSheet(
                    rule: bindingRule,
                    calendarsDisabled: localDraft.disabledCalendarIDs,
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
                        showRuleEditor = false
                    },
                    onCancel: { showRuleEditor = false }
                )
            }
        }
        .confirmationDialog("Reset App?", isPresented: $showResetConfirm) {
            Button("Reset App", role: .destructive) {
                try? model.settingsViewModel.resetApp()
                localDraft = SettingsDraft.from(settings: model.settingsViewModel.saved)
                draftToken = ""
                saveMessage = "App reset"
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes rules, calendar selections, runtime state, and the stored Slack token.")
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

    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Finish setup")
                .font(.headline)
            Text("Grant Calendar Full Access, paste a Slack user token (xoxp-), then Save. Rules are optional.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12))
    }

    private var isDirty: Bool {
        let compare = SettingsDraft.from(settings: model.settingsViewModel.saved)
        return localDraft.rules != compare.rules
            || localDraft.disabledCalendarIDs != compare.disabledCalendarIDs
            || localDraft.launchAtLoginDesired != compare.launchAtLoginDesired
            || !draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var launchStatusText: String {
        switch model.launchAtLogin.status() {
        case .enabled: return "Login item: enabled"
        case .requiresApproval: return "Login item: waiting for approval in System Settings"
        case .notRegistered: return "Login item: not registered"
        case .notFound: return "Login item: not found"
        case .unknown: return "Login item: unknown"
        }
    }

    private func moveRules(from: IndexSet, to: Int) {
        localDraft.rules.move(fromOffsets: from, toOffset: to)
    }

    private func refreshCalendars() {
        model.settingsViewModel.reloadCalendars()
        calendars = model.settingsViewModel.calendars
        let status = model.calendarService.authorizationStatus()
        calendarStatus = String(describing: status)
    }

    private func save() async {
        isSaving = true
        saveMessage = nil
        defer { isSaving = false }

        model.settingsViewModel.updateDraft { d in
            d = localDraft
            d.replacementToken = draftToken
        }
        // Push draft fields into view model explicitly
        let vm = model.settingsViewModel
        vm.updateDraft { d in
            d.rules = localDraft.rules
            d.disabledCalendarIDs = localDraft.disabledCalendarIDs
            d.launchAtLoginDesired = localDraft.launchAtLoginDesired
            d.replacementToken = draftToken
        }

        if let error = await vm.save() {
            saveMessage = String(describing: error)
            return
        }
        localDraft = SettingsDraft.from(settings: vm.saved)
        draftToken = ""
        saveMessage = "Saved"
        model.settingsDidSave()
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

struct RuleEditorSheet: View {
    @State var rule: RuleDraft
    var calendarsDisabled: Set<String>
    var previewProvider: (RuleDraft) -> [CalendarOccurrence]
    var sampleTester: (RuleDraft, String) -> Bool
    var onSave: (RuleDraft) -> Void
    var onCancel: () -> Void

    @State private var sampleTitle = "Focus block"
    @State private var validationMessage: String?
    @State private var previews: [CalendarOccurrence] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rule.titleRegex.isEmpty && rule.statusText.isEmpty ? "Add Rule" : "Edit Rule")
                .font(.title2)
            Form {
                TextField("Title regex", text: $rule.titleRegex)
                TextField("Status text", text: $rule.statusText)
                TextField("Emoji shortcode", text: $rule.statusEmoji)
                Toggle("Enable Slack Do Not Disturb", isOn: $rule.enableDND)

                Section("Test sample title") {
                    TextField("Sample event title", text: $sampleTitle)
                    Text(sampleTester(rule, sampleTitle) ? "Matches" : "No match")
                        .foregroundStyle(sampleTester(rule, sampleTitle) ? .green : .secondary)
                }

                Section("Upcoming matches (7 days)") {
                    if previews.isEmpty {
                        Text("No upcoming matches")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(previews.prefix(10), id: \.id) { occ in
                            Text("\(occ.start.formatted()) — \(occ.title)")
                                .lineLimit(1)
                        }
                    }
                    Button("Refresh Preview") {
                        previews = previewProvider(rule)
                    }
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save Rule") {
                    if let error = RuleValidator.validate(rule.asRule()) {
                        validationMessage = String(describing: error)
                    } else {
                        onSave(rule)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 560)
        .onAppear {
            previews = previewProvider(rule)
        }
    }
}
