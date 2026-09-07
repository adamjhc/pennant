import Foundation

#if canImport(SlackStatusSyncCore)
import SlackStatusSyncCore
#elseif canImport(SlackStatusSync)
@testable import SlackStatusSync
#endif

#if canImport(XCTest)
import XCTest
#endif

final class PersistenceTests: XCTestCase {
    func testSettingsRoundTripAndAtomicWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileSettingsStore(directory: dir)
        var settings = AppSettings.freshDefaults()
        settings.rules = [
            StatusRule(titleRegex: "Focus", statusText: "Focusing", statusEmoji: ":dart:", enableDND: true)
        ]
        settings.disabledCalendarIDs = ["cal-a"]
        settings.isPaused = true
        try store.save(settings)

        let loaded = try store.load()
        XCTAssertEqual(loaded.rules.count, 1)
        XCTAssertEqual(loaded.disabledCalendarIDs, ["cal-a"])
        XCTAssertTrue(loaded.isPaused)
    }

    func testMissingFileReturnsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSettingsStore(directory: dir)
        let loaded = try store.load()
        XCTAssertEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(loaded.rules.isEmpty)
    }

    func testCorruptDataThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(AppPaths.settingsFileName)
        try "not-json".write(to: url, atomically: true, encoding: .utf8)
        let store = FileSettingsStore(directory: dir)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PersistenceError, .corruptData)
        }
    }

    func testUnsupportedSchemaThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(AppPaths.settingsFileName)
        let json = """
        {"schemaVersion":999,"rules":[],"disabledCalendarIDs":[],"isPaused":false,"launchAtLoginDesired":true,"hasCompletedSetup":false}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = FileSettingsStore(directory: dir)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PersistenceError, .unsupportedSchema(found: 999, expected: 1))
        }
    }

    func testRuntimeStateRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileRuntimeStateStore(directory: dir)
        var state = RuntimeState.empty()
        state.ownedStatus = AppOwnedStatus(text: "Focusing", emoji: ":dart:", expiration: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(state)
        let loaded = try store.load()
        XCTAssertEqual(loaded.ownedStatus?.text, "Focusing")
    }

    func testInMemoryTokenAndReset() throws {
        let settings = InMemorySettingsStore()
        let runtime = InMemoryRuntimeStateStore()
        let tokens = InMemoryTokenStore()
        try tokens.saveToken("xoxp-test-token")
        var s = AppSettings.freshDefaults()
        s.rules = [StatusRule(titleRegex: "A", statusText: "B", statusEmoji: ":c:", enableDND: false)]
        try settings.save(s)
        try runtime.save(RuntimeState(lastError: "x"))

        try AppResetService().reset(settings: settings, runtime: runtime, tokens: tokens)
        XCTAssertFalse(try tokens.hasToken())
        XCTAssertTrue(try settings.load().rules.isEmpty)
        XCTAssertNil(try runtime.load().lastError)
    }

    func testTokenStoreErrors() throws {
        let tokens = InMemoryTokenStore()
        tokens.saveError = PersistenceError.keychainFailure("boom")
        XCTAssertThrowsError(try tokens.saveToken("xoxp-abc"))
    }
}
