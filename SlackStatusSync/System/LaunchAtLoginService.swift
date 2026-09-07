import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

public protocol LaunchAtLoginServiceProtocol: Sendable {
    func status() -> LaunchAtLoginStatus
    func setEnabled(_ enabled: Bool) throws
}

public struct LaunchAtLoginService: LaunchAtLoginServiceProtocol, Sendable {
    public init() {}

    public func status() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

public final class FakeLaunchAtLoginService: LaunchAtLoginServiceProtocol, @unchecked Sendable {
    public var current: LaunchAtLoginStatus = .notRegistered
    public var setError: Error?

    public init() {}

    public func status() -> LaunchAtLoginStatus { current }

    public func setEnabled(_ enabled: Bool) throws {
        if let setError { throw setError }
        current = enabled ? .enabled : .notRegistered
    }
}
