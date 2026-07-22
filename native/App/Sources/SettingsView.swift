import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var eventKit: EventKitService
    @ObservedObject private var loginItem: LoginItemService
    @ObservedObject private var notifications: NotificationService
    @State private var draft: AppSettings
    @State private var tokenField: String = ""
    @State private var selectedCalendarNames: Set<String>
    @State private var shouldSelectAllCalendarsWhenLoaded: Bool
    @State private var didInitializeCalendarSelection = false
    @State private var draggedRuleID: UUID?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var saveSucceeded = false

    init(model: AppModel) {
        self.model = model
        _eventKit = ObservedObject(wrappedValue: model.eventKit)
        _loginItem = ObservedObject(wrappedValue: model.loginItem)
        _notifications = ObservedObject(wrappedValue: model.notifications)
        _draft = State(initialValue: model.settings)
        _selectedCalendarNames = State(initialValue: Set(model.settings.calendarNames ?? []))
        _shouldSelectAllCalendarsWhenLoaded = State(initialValue: model.settings.calendarNames == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isFirstRun || model.needsSetup {
                setupBanner
            }
            Form {
                Section("Setup") {
                    setupRow(
                        title: "Calendar access",
                        detail: eventKit.isRequestingAccess
                            ? "Requesting Full Access…"
                            : eventKit.statusLabel,
                        ok: eventKit.isAuthorized
                    ) {
                        Button(eventKit.isAuthorized ? "Recheck" : "Request Access") {
                            Task {
                                NSApp.keyWindow?.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                                _ = await eventKit.requestAccess()
                                eventKit.refreshStatus()
                                initializeCalendarSelectionIfNeeded()
                                model.markFirstRunCompleteIfReady()
                            }
                        }
                        .disabled(eventKit.isRequestingAccess)
                        if !eventKit.isAuthorized {
                            Button("Open System Settings") {
                                eventKit.openSystemCalendarSettings()
                            }
                        }
                    }
                    if let authorizationError = eventKit.authorizationError {
                        Text(authorizationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    setupRow(
                        title: "Slack token",
                        detail: model.hasToken ? "Stored in Keychain" : "Missing",
                        ok: model.hasToken
                    ) {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 6) {
                                SecureField(
                                    model.hasToken
                                        ? "Leave blank to keep existing token"
                                        : "Paste xoxp- user token",
                                    text: $tokenField
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)

                                Button("Paste") {
                                    if let clipboard = NSPasteboard.general.string(forType: .string)?
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                       !clipboard.isEmpty {
                                        tokenField = clipboard
                                        saveError = nil
                                    } else {
                                        saveError = "The clipboard does not contain a Slack token."
                                    }
                                }
                                .help("Paste the Slack token directly from the clipboard")
                            }
                            if !tokenField.isEmpty {
                                Text("Replacement token ready to save")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            if model.hasToken {
                                Text("Stored: \(AppPaths.tokenMask)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    setupRow(
                        title: "Error notifications",
                        detail: notifications.statusLabel,
                        ok: notifications.isAuthorized
                    ) {
                        if notifications.status == .notDetermined {
                            Button("Request Access") {
                                Task { await notifications.requestAccess() }
                            }
                        } else if !notifications.isAuthorized {
                            Button("Open System Settings") {
                                notifications.openSystemSettings()
                            }
                        }
                    }
                    if let notificationError = notifications.requestError {
                        Text(notificationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    setupRow(
                        title: "Launch at Login",
                        detail: loginItem.canRegister
                            ? loginItem.statusLabel
                            : "Install to /Applications to enable",
                        ok: loginItem.isEnabled
                    ) {
                        Toggle("Enabled", isOn: Binding(
                            get: { loginItem.isEnabled },
                            set: { newValue in
                                if !loginItem.setEnabled(newValue) {
                                    saveError = loginItem.canRegister
                                        ? "Could not update Launch at Login"
                                        : "Move the app to /Applications, then relaunch"
                                }
                            }
                        ))
                        .disabled(!loginItem.canRegister)
                        if loginItem.status == .requiresApproval {
                            Button("Open Login Items") {
                                loginItem.openLoginItemsSettings()
                            }
                        }
                    }
                }

                Section("Health") {
                    LabeledContent("Status") {
                        Text(
                            model.isPaused
                                ? "Paused"
                                : (model.isSyncing ? "Syncing…" : (model.lastError == nil ? "Running" : "Error"))
                        )
                    }
                    LabeledContent("Last Slack update") {
                        Text(model.formatMenuDate(model.lastSlackUpdateAt))
                    }
                    LabeledContent("Last poll") {
                        Text(model.formatMenuDate(model.lastPollAt))
                    }
                    if let lastError = model.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section("Polling") {
                    Stepper(value: $draft.pollIntervalSeconds, in: 5...3600, step: 5) {
                        Text("Poll interval: \(draft.pollIntervalSeconds)s")
                    }
                    Stepper(value: $draft.lookAheadMinutes, in: 1...240) {
                        Text("Look ahead: \(draft.lookAheadMinutes) min")
                    }
                    Stepper(value: $draft.lookBehindMinutes, in: 0...60) {
                        Text("Look behind: \(draft.lookBehindMinutes) min")
                    }
                }

                Section("Calendars") {
                    Text("Choose which calendars can update Slack. If none are checked, calendar syncing is disabled.")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    if !eventKit.isAuthorized {
                        Text("Grant Calendar Full Access to load calendars.")
                            .foregroundStyle(.secondary)
                    } else if eventKit.calendars.isEmpty {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("No calendars found.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(eventKit.calendars) { calendar in
                                Toggle(isOn: calendarSelectionBinding(for: calendar.title)) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(calendar.title)
                                        if let source = calendar.source, !source.isEmpty {
                                            Text(source)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }

                    HStack {
                        Button("Select All") {
                            selectedCalendarNames = Set(eventKit.calendars.map(\.title))
                            shouldSelectAllCalendarsWhenLoaded = false
                        }
                        Button("Select None") {
                            selectedCalendarNames.removeAll()
                            shouldSelectAllCalendarsWhenLoaded = false
                        }
                        Spacer()
                        Button("Refresh") {
                            eventKit.reloadCalendars()
                            initializeCalendarSelectionIfNeeded()
                        }
                    }
                }

                Section("Rules (drag to set priority — top wins)") {
                    VStack(spacing: 0) {
                        ForEach($draft.rules) { $rule in
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                    .help("Drag to reorder")
                                    .onDrag {
                                        draggedRuleID = rule.id
                                        return NSItemProvider(object: rule.id.uuidString as NSString)
                                    }

                                RuleEditorRow(rule: $rule)

                                Button {
                                    draft.rules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete rule")
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onDrop(
                                of: [UTType.text],
                                delegate: RuleDropDelegate(
                                    targetID: rule.id,
                                    rules: $draft.rules,
                                    draggedRuleID: $draggedRuleID
                                )
                            )

                            if rule.id != draft.rules.last?.id {
                                Divider()
                            }
                        }
                    }

                    Button("Add rule") {
                        draft.rules.append(
                            TitleRule(
                                eventNameContains: "",
                                status: "",
                                emoji: ":calendar:",
                                notifications: "snooze",
                                priority: (draft.rules.count + 1) * 10
                            )
                        )
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                } else if saveSucceeded {
                    Text("Saved — syncing now")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Button("Cancel") {
                    draft = model.settings
                    tokenField = ""
                    selectedCalendarNames = Set(model.settings.calendarNames ?? eventKit.calendars.map(\.title))
                    shouldSelectAllCalendarsWhenLoaded = model.settings.calendarNames == nil
                    saveError = nil
                    NSApp.keyWindow?.close()
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
        .frame(minWidth: 680, minHeight: 560)
        .onAppear {
            eventKit.refreshStatus()
            loginItem.refresh()
            Task { await notifications.refreshStatus() }
            eventKit.reloadCalendars()
            initializeCalendarSelectionIfNeeded()
        }
        .onChange(of: eventKit.calendars) { _, _ in
            initializeCalendarSelectionIfNeeded()
        }
    }

    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isFirstRun ? "Welcome — finish setup" : "Setup needs attention")
                .font(.headline)
            Text("Grant Calendar Full Access, paste your Slack user token, and Save. Launch at Login is enabled by default when installed in /Applications.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private func setupRow<Content: View>(
        title: String,
        detail: String,
        ok: Bool,
        @ViewBuilder actions: () -> Content
    ) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        saveSucceeded = false
        defer { isSaving = false }

        initializeCalendarSelectionIfNeeded()
        if shouldSelectAllCalendarsWhenLoaded && !didInitializeCalendarSelection {
            saveError = eventKit.isAuthorized
                ? "Wait for calendars to finish loading before saving."
                : "Grant Calendar Full Access before saving."
            return
        }

        draft.calendarNames = CalendarSelection.persistedNames(selectedCalendarNames)

        let replacement = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = await model.saveSettingsFromUI(
            draft: draft,
            replacementToken: replacement.isEmpty ? nil : replacement
        ) {
            saveError = error
            return
        }
        tokenField = ""
        saveSucceeded = true
        draft = model.settings
    }

    private func initializeCalendarSelectionIfNeeded() {
        guard !didInitializeCalendarSelection, !eventKit.calendars.isEmpty else {
            return
        }
        if shouldSelectAllCalendarsWhenLoaded {
            selectedCalendarNames = CalendarSelection.initialNames(
                configuredNames: nil,
                availableCalendars: eventKit.calendars
            )
        }
        didInitializeCalendarSelection = true
    }

    private func calendarSelectionBinding(for title: String) -> Binding<Bool> {
        Binding(
            get: { selectedCalendarNames.contains(title) },
            set: { isSelected in
                shouldSelectAllCalendarsWhenLoaded = false
                if isSelected {
                    selectedCalendarNames.insert(title)
                } else {
                    selectedCalendarNames.remove(title)
                }
            }
        )
    }
}

struct RuleEditorRow: View {
    @Binding var rule: TitleRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Event title contains")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Focus", text: $rule.eventNameContains)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slack status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Focusing", text: $rule.status)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Emoji")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(":dart:", text: $rule.emoji)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: 160)
                Picker("Notifications", selection: $rule.notifications) {
                    Text("Snooze").tag("snooze")
                    Text("Normal").tag("normal")
                }
                .frame(maxWidth: 180)
                Text("Priority \(rule.priority)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RuleDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var rules: [TitleRule]
    @Binding var draggedRuleID: UUID?

    func dropEntered(info: DropInfo) {
        guard
            let draggedRuleID,
            draggedRuleID != targetID,
            let sourceIndex = rules.firstIndex(where: { $0.id == draggedRuleID }),
            let targetIndex = rules.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        withAnimation {
            rules.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
            for index in rules.indices {
                rules[index].priority = (index + 1) * 10
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedRuleID = nil
        return true
    }
}
