import Foundation

public protocol SettingsStoreProtocol: Sendable {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
    func delete() throws
}

public protocol RuntimeStateStoreProtocol: Sendable {
    func load() throws -> RuntimeState
    func save(_ state: RuntimeState) throws
    func delete() throws
}

public protocol TokenStoreProtocol: Sendable {
    func saveToken(_ token: String) throws
    func readToken() throws -> String?
    func deleteToken() throws
    func hasToken() throws -> Bool
}

public enum PersistenceError: Error, Equatable, Sendable {
    case unsupportedSchema(found: Int, expected: Int)
    case corruptData
    case ioFailure(String)
    case keychainFailure(String)
}

public enum AppPaths {
    public static let appSupportFolderName = "Pennant"
    public static let settingsFileName = "settings.json"
    public static let runtimeStateFileName = "runtime-state.json"
    public static let keychainService = "dev.local.Pennant"
    public static let keychainAccount = "slack-user-token"

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(appSupportFolderName, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Atomically writes Codable JSON with schema version checks.
public final class JSONFileStore<T: Codable & Sendable>: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let expectedSchema: Int
    private let schemaKeyPath: (T) -> Int
    private let makeDefault: () -> T
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        expectedSchema: Int,
        schemaKeyPath: @escaping (T) -> Int,
        makeDefault: @escaping () -> T,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.expectedSchema = expectedSchema
        self.schemaKeyPath = schemaKeyPath
        self.makeDefault = makeDefault
        self.fileManager = fileManager
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func load() throws -> T {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return makeDefault()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let value = try decoder.decode(T.self, from: data)
            let version = schemaKeyPath(value)
            if version != expectedSchema {
                throw PersistenceError.unsupportedSchema(found: version, expected: expectedSchema)
            }
            return value
        } catch let error as PersistenceError {
            throw error
        } catch is DecodingError {
            throw PersistenceError.corruptData
        } catch {
            throw PersistenceError.ioFailure(error.localizedDescription)
        }
    }

    public func save(_ value: T) throws {
        do {
            let data = try encoder.encode(value)
            let dir = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try fileManager.moveItem(at: tmp, to: fileURL)
            }
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.ioFailure(error.localizedDescription)
        }
    }

    public func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw PersistenceError.ioFailure(error.localizedDescription)
        }
    }
}

public final class FileSettingsStore: SettingsStoreProtocol, @unchecked Sendable {
    private let store: JSONFileStore<AppSettings>

    public init(directory: URL, fileManager: FileManager = .default) {
        let url = directory.appendingPathComponent(AppPaths.settingsFileName)
        self.store = JSONFileStore(
            fileURL: url,
            expectedSchema: AppSettings.currentSchemaVersion,
            schemaKeyPath: \.schemaVersion,
            makeDefault: AppSettings.freshDefaults,
            fileManager: fileManager
        )
    }

    public convenience init(fileManager: FileManager = .default) throws {
        let dir = try AppPaths.applicationSupportDirectory(fileManager: fileManager)
        self.init(directory: dir, fileManager: fileManager)
    }

    public func load() throws -> AppSettings { try store.load() }
    public func save(_ settings: AppSettings) throws { try store.save(settings) }
    public func delete() throws { try store.delete() }
}

public final class FileRuntimeStateStore: RuntimeStateStoreProtocol, @unchecked Sendable {
    private let store: JSONFileStore<RuntimeState>

    public init(directory: URL, fileManager: FileManager = .default) {
        let url = directory.appendingPathComponent(AppPaths.runtimeStateFileName)
        self.store = JSONFileStore(
            fileURL: url,
            expectedSchema: RuntimeState.currentSchemaVersion,
            schemaKeyPath: \.schemaVersion,
            makeDefault: RuntimeState.empty,
            fileManager: fileManager
        )
    }

    public convenience init(fileManager: FileManager = .default) throws {
        let dir = try AppPaths.applicationSupportDirectory(fileManager: fileManager)
        self.init(directory: dir, fileManager: fileManager)
    }

    public func load() throws -> RuntimeState { try store.load() }
    public func save(_ state: RuntimeState) throws { try store.save(state) }
    public func delete() throws { try store.delete() }
}

public final class InMemorySettingsStore: SettingsStoreProtocol, @unchecked Sendable {
    private var settings: AppSettings
    private let lock = NSLock()

    public init(_ settings: AppSettings = .freshDefaults()) {
        self.settings = settings
    }

    public func load() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        settings = .freshDefaults()
    }
}

public final class InMemoryRuntimeStateStore: RuntimeStateStoreProtocol, @unchecked Sendable {
    private var state: RuntimeState
    private let lock = NSLock()

    public init(_ state: RuntimeState = .empty()) {
        self.state = state
    }

    public func load() throws -> RuntimeState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func save(_ state: RuntimeState) throws {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        state = .empty()
    }
}

public final class InMemoryTokenStore: TokenStoreProtocol, @unchecked Sendable {
    private var token: String?
    private let lock = NSLock()
    public var saveError: Error?
    public var readError: Error?

    public init(token: String? = nil) {
        self.token = token
    }

    public func saveToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let saveError { throw saveError }
        self.token = token
    }

    public func readToken() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let readError { throw readError }
        return token
    }

    public func deleteToken() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }

    public func hasToken() throws -> Bool {
        try readToken() != nil
    }
}

public struct AppResetService: Sendable {
    public init() {}

    public func reset(
        settings: SettingsStoreProtocol,
        runtime: RuntimeStateStoreProtocol,
        tokens: TokenStoreProtocol
    ) throws {
        try settings.delete()
        try runtime.delete()
        try tokens.deleteToken()
    }
}
