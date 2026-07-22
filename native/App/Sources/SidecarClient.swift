import Foundation

actor SidecarClient {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.slack-status-sync.sidecar")

    private let maxResponseBytes = 8 * 1024 * 1024
    private let maxRequestBytes = 8 * 1024 * 1024
    private let defaultTimeout: TimeInterval = 60

    func ensureStarted() throws {
        if let process, process.isRunning {
            return
        }
        try start()
    }

    private func start() throws {
        guard let url = AppPaths.sidecarURL, FileManager.default.fileExists(atPath: url.path) else {
            throw SidecarError.missingBinary
        }

        let process = Process()
        process.executableURL = url
        process.arguments = []
        process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            // Do not pass Slack tokens via environment.
            !key.uppercased().contains("TOKEN") && !key.uppercased().contains("SECRET")
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                // Redacted diagnostics only — never echo secrets.
                fputs("[sidecar] \(line)", stderr)
            }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutBuffer = Data()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let source = DispatchSource.makeReadSource(fileDescriptor: stdoutHandle.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            let data = stdoutHandle.availableData
            Task { await self?.handleStdout(data) }
        }
        source.setCancelHandler {
            try? stdoutHandle.close()
        }
        source.resume()
        self.readSource = source

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination(process) }
        }
    }

    private func handleStdout(_ data: Data) {
        if data.isEmpty {
            return
        }
        stdoutBuffer.append(data)
        if stdoutBuffer.count > maxResponseBytes {
            failAll(SidecarError.responseTooLarge)
            cleanup(terminate: true)
            return
        }

        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)
            guard !lineData.isEmpty else { continue }
            do {
                let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                guard let json, let id = json["id"] as? String else {
                    continue
                }
                if let cont = pending.removeValue(forKey: id) {
                    cont.resume(returning: json)
                }
            } catch {
                // Ignore unparseable lines.
            }
        }
    }

    private func handleTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else {
            return
        }
        failAll(SidecarError.crashed)
        cleanup()
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting {
            cont.resume(throwing: error)
        }
    }

    private func cleanup(terminate: Bool = false) {
        let oldProcess = process
        oldProcess?.terminationHandler = nil
        if terminate, oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }
        readSource?.cancel()
        readSource = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        stdoutBuffer.removeAll()
    }

    func shutdown() async {
        if process?.isRunning == true {
            _ = try? await request(method: "shutdown", params: [:], timeout: 5)
        }
        process?.terminate()
        cleanup()
    }

    func request(method: String, params: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        try ensureStarted()
        let id = UUID().uuidString
        var envelope: [String: Any] = [
            "v": 1,
            "id": id,
            "method": method,
        ]
        if !params.isEmpty {
            envelope["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard data.count <= maxRequestBytes else {
            throw SidecarError.requestTooLarge
        }
        guard var line = String(data: data, encoding: .utf8) else {
            throw SidecarError.encodeFailed
        }
        line.append("\n")

        let timeoutSeconds = timeout ?? defaultTimeout

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[id] = cont
            do {
                try stdinHandle?.write(contentsOf: Data(line.utf8))
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if let timedOut = self.takePending(id: id) {
                    timedOut.resume(throwing: SidecarError.timeout)
                }
            }
        }
    }

    private func takePending(id: String) -> CheckedContinuation<[String: Any], Error>? {
        pending.removeValue(forKey: id)
    }

    /// Call once; on crash, restart once and retry.
    func requestWithRestart(method: String, params: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        do {
            return try await request(method: method, params: params, timeout: timeout)
        } catch SidecarError.timeout {
            // The timed-out request may still be running. Terminate it and do
            // not retry automatically, which could duplicate a Slack update.
            cleanup(terminate: true)
            throw SidecarError.timeout
        } catch SidecarError.crashed, SidecarError.missingBinary {
            cleanup()
            try ensureStarted()
            return try await request(method: method, params: params, timeout: timeout)
        } catch {
            // If process died mid-flight, restart once.
            if process?.isRunning != true {
                cleanup()
                try ensureStarted()
                return try await request(method: method, params: params, timeout: timeout)
            }
            throw error
        }
    }
}

enum SidecarError: LocalizedError {
    case missingBinary
    case encodeFailed
    case timeout
    case crashed
    case requestTooLarge
    case responseTooLarge
    case remote(String, String)

    var errorDescription: String? {
        switch self {
        case .missingBinary:
            return "Sync core helper is missing from the app bundle"
        case .encodeFailed:
            return "Failed to encode sidecar request"
        case .timeout:
            return "Sync core timed out"
        case .crashed:
            return "Sync core crashed"
        case .requestTooLarge:
            return "Sync request exceeds the 8 MB limit"
        case .responseTooLarge:
            return "Sync core response too large"
        case .remote(let code, let message):
            return "\(code): \(message)"
        }
    }
}

extension SidecarClient {
    func unwrapResult(_ response: [String: Any]) throws -> [String: Any] {
        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }
        let error = response["error"] as? [String: Any]
        let code = error?["code"] as? String ?? "error"
        let message = error?["message"] as? String ?? "Unknown sidecar error"
        throw SidecarError.remote(code, message)
    }
}
