import Foundation

struct TitleRule: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var eventNameContains: String
    var status: String
    var emoji: String
    var notifications: String
    var priority: Int

    enum CodingKeys: String, CodingKey {
        case eventNameContains, status, emoji, notifications, priority
    }

    init(
        id: UUID = UUID(),
        eventNameContains: String,
        status: String,
        emoji: String,
        notifications: String,
        priority: Int
    ) {
        self.id = id
        self.eventNameContains = eventNameContains
        self.status = status
        self.emoji = emoji
        self.notifications = notifications
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        eventNameContains = try c.decode(String.self, forKey: .eventNameContains)
        status = try c.decode(String.self, forKey: .status)
        emoji = try c.decode(String.self, forKey: .emoji)
        notifications = try c.decode(String.self, forKey: .notifications)
        priority = try c.decode(Int.self, forKey: .priority)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventNameContains, forKey: .eventNameContains)
        try c.encode(status, forKey: .status)
        try c.encode(emoji, forKey: .emoji)
        try c.encode(notifications, forKey: .notifications)
        try c.encode(priority, forKey: .priority)
    }

    func asWire() -> [String: Any] {
        [
            "eventNameContains": eventNameContains,
            "status": status,
            "emoji": emoji,
            "notifications": notifications,
            "priority": priority,
        ]
    }
}

struct AppSettings: Codable, Equatable {
    var pollIntervalSeconds: Int
    var lookAheadMinutes: Int
    var lookBehindMinutes: Int
    var calendarNames: [String]?
    var rules: [TitleRule]

    static let exampleRules: [TitleRule] = [
        TitleRule(
            eventNameContains: "Focus",
            status: "Focusing",
            emoji: ":dart:",
            notifications: "snooze",
            priority: 10
        ),
        TitleRule(
            eventNameContains: "1:1",
            status: "In a 1:1",
            emoji: ":speech_balloon:",
            notifications: "snooze",
            priority: 20
        ),
        TitleRule(
            eventNameContains: "Standup",
            status: "In standup",
            emoji: ":calendar:",
            notifications: "snooze",
            priority: 30
        ),
    ]

    static func freshDefaults() -> AppSettings {
        AppSettings(
            pollIntervalSeconds: 30,
            lookAheadMinutes: 15,
            lookBehindMinutes: 5,
            calendarNames: nil,
            rules: exampleRules
        )
    }

    /// Recompute priorities from list order (10, 20, 30…).
    mutating func applyDragPriorities() {
        for index in rules.indices {
            rules[index].priority = (index + 1) * 10
        }
    }

    func asWire() -> [String: Any] {
        var dict: [String: Any] = [
            "pollIntervalSeconds": pollIntervalSeconds,
            "lookAheadMinutes": lookAheadMinutes,
            "lookBehindMinutes": lookBehindMinutes,
            "rules": rules.map { $0.asWire() },
        ]
        if let calendarNames {
            dict["calendarNames"] = calendarNames
        }
        return dict
    }

    static func load() -> AppSettings? {
        let url = AppPaths.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            return nil
        }
    }

    func saveAtomically(to url: URL = AppPaths.settingsURL) throws {
        var copy = self
        copy.applyDragPriorities()
        try copy.write(to: url)
    }

    private func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("settings.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tmp.path
        )
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

extension AppSettings {
    mutating func applyDragPrioritiesInPlace() {
        applyDragPriorities()
    }
}

struct CalendarWireEvent: Codable {
    var id: String
    var iCalUId: String?
    var changeKey: String?
    var title: String
    var start: String
    var end: String
    var isAllDay: Bool
    var isCancelled: Bool
    var response: String?
    var showAs: String?
    var calendarName: String
    var calendarId: String

    func asDictionary() -> [String: Any] {
        [
            "id": id,
            "iCalUId": iCalUId as Any,
            "changeKey": changeKey as Any,
            "title": title,
            "start": start,
            "end": end,
            "isAllDay": isAllDay,
            "isCancelled": isCancelled,
            "response": response as Any,
            "showAs": showAs as Any,
            "calendarName": calendarName,
            "calendarId": calendarId,
        ]
    }
}

struct LocalCalendarInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var source: String?
}

enum CalendarSelection {
    static func initialNames(
        configuredNames: [String]?,
        availableCalendars: [LocalCalendarInfo]
    ) -> Set<String> {
        if let configuredNames {
            return Set(configuredNames)
        }
        return Set(availableCalendars.map(\.title))
    }

    static func persistedNames(_ selectedNames: Set<String>) -> [String] {
        selectedNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}
