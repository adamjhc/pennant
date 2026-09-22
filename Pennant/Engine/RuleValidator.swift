import Foundation

public enum RuleValidationError: Error, Equatable, Sendable {
    case emptyRegex
    case invalidRegex(String)
    case emptyStatusText
    case statusTextTooLong
    case invalidEmoji
}

public enum RuleValidator {
    public static let maxStatusTextLength = 100

    /// Compiles a case-insensitive ICU regex that searches anywhere in the title.
    public static func compileRegex(_ pattern: String) throws -> NSRegularExpression {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RuleValidationError.emptyRegex
        }
        do {
            return try NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
        } catch {
            throw RuleValidationError.invalidRegex(error.localizedDescription)
        }
    }

    public static func validateEmoji(_ emoji: String) -> Bool {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slack shortcode: :name: or :name::skin-tone-2: style — require leading/trailing colons
        // and at least one non-colon character between them.
        let pattern = #"^:[^:\s][^:\s]*(?::[^:\s]+)*:$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    public static func validate(_ rule: StatusRule) -> RuleValidationError? {
        do {
            _ = try compileRegex(rule.titleRegex)
        } catch let error as RuleValidationError {
            return error
        } catch {
            return .invalidRegex(error.localizedDescription)
        }

        let status = rule.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.isEmpty {
            return .emptyStatusText
        }
        if status.count > maxStatusTextLength {
            return .statusTextTooLong
        }
        if !validateEmoji(rule.statusEmoji) {
            return .invalidEmoji
        }
        return nil
    }

    public static func matches(title: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }

    public static func matches(title: String, pattern: String) -> Bool {
        guard let regex = try? compileRegex(pattern) else { return false }
        return matches(title: title, regex: regex)
    }
}
