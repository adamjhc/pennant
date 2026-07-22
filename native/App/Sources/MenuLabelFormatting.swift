import Foundation

enum MenuLabelFormatting {
    static func lastUpdate(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func errorFingerprint(code: String, message: String) -> String {
        "\(code)|\(message)"
    }
}

enum PriorityOrdering {
    static func priorities(forCount count: Int) -> [Int] {
        (0..<count).map { ($0 + 1) * 10 }
    }
}
