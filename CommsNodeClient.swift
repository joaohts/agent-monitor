import Foundation
import Darwin

struct NodeStatus: Decodable {
    let version: String
    let apiVersion: Int
    let machineId: String
    let publicKey: String
    let name: String
    let brokerEnabled: Bool
    let brokerConnected: Bool
    let dataDir: String
}

struct NodeAgent: Decodable, Identifiable {
    let id: String
    let alias: String
    let persistent: Bool
    let online: Bool
    let scope: String
    let retiredAt: Int64?
}

struct NodeSession: Decodable, Identifiable {
    let id: String
    let agentId: String
    let harness: String
    let harnessSessionId: String
    let scope: String
    let deliveryTarget: String?
    let endedAt: Int64?
}

struct NodePeer: Decodable, Identifiable {
    let machineId: String
    let alias: String
    let publicKey: String
    var id: String { machineId }
}

struct NodeGrant: Decodable, Identifiable {
    let granteeMachineId: String
    let allowMessages: Bool
    let allowHistory: Bool
    let revision: Int64
    var id: String { granteeMachineId }
}

struct NodePresence: Decodable, Identifiable {
    let machineId: String
    let peerAlias: String?
    let agentId: String
    let alias: String
    let persistent: Bool
    let online: Bool
    var id: String { machineId + ":" + agentId }
    var address: String { (peerAlias?.isEmpty == false ? peerAlias! + ":" : "") + alias }
}

struct NodeMessage: Decodable {
    let id: String
    let senderMachineId: String
    let senderAgentId: String
    let recipientMachineId: String
    let recipientAgentId: String
    let body: String?
    let state: String
    let createdAt: Int64
    let failureCode: String?
    var stableID: String { senderMachineId + "/" + id }
    var date: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }
}

struct NodeHistoryPage: Decodable {
    let messages: [NodeMessage]?
    let nextCursor: String?
    var records: [NodeMessage] { messages ?? [] }
}

struct NodeInstallResult: Decodable {
    let command: String
    let skill: String
    let dataDir: String
}

struct NodeCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class BoundedCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var tooLarge = false
    func append(_ next: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + next.count > 4 * 1024 * 1024 { tooLarge = true; return }
        data.append(next)
    }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if tooLarge { throw NodeCommandError(message: "Node response exceeded the viewer's 4 MiB limit.") }
        return data
    }
}

/// Short CLI operations run off the GUI thread, with bounded concurrency,
/// output, and time. No command here holds a receiver or consumes agent mail.
enum CommsNodeClient {
    static let apiVersion = 1
    private static let slots = DispatchSemaphore(value: 4)
    static var resourceDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("CommsNode")
    }
    static var binary: URL {
        if let path = ProcessInfo.processInfo.environment["AGENT_MONITOR_COMMS_BIN"] {
            return URL(fileURLWithPath: path)
        }
        return resourceDirectory?.appendingPathComponent("comms")
            ?? URL(fileURLWithPath: "/missing-bundled-comms")
    }
    static var dataDirectory: String {
        if let path = ProcessInfo.processInfo.environment["COMMS_DATA_DIR"], !path.isEmpty { return path }
        let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/agent-monitor/comms-install.json")
        if let data = try? Data(contentsOf: config),
           let result = try? decode(NodeInstallResult.self, from: data) { return result.dataDir }
        return NSHomeDirectory() + "/.local/share/comms"
    }
    static var installedSkill: String {
        let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/agent-monitor/comms-install.json")
        if let data = try? Data(contentsOf: config),
           let result = try? decode(NodeInstallResult.self, from: data) { return result.skill }
        return "open-comms"
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // The viewer acts as the local OS owner. An environment inherited from
        // the terminal that launched it must not impersonate that agent.
        for key in ["COMMS_AGENT", "COMMS_SESSION_ID", "CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID"] { env.removeValue(forKey: key) }
        return env
    }
    static func command(_ arguments: [String], timeout: TimeInterval = 12) async throws -> Data {
        let executable = binary
        let args = ["--data-dir", dataDirectory, "--json"] + arguments
        return try await Task.detached(priority: .utility) {
            try run(executable: executable, arguments: args, timeout: timeout)
        }.value
    }
    static func query<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        try decode(type, from: await command(arguments))
    }
    static func install() async throws -> NodeInstallResult {
        guard let resources = Bundle.main.resourceURL, let node = resourceDirectory else {
            throw NodeCommandError(message: "The application is missing its bundled node release.")
        }
        let result = try await Task.detached(priority: .utility) {
            try run(executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: [resources.appendingPathComponent("install-local-comms.sh").path, node.path],
                    timeout: 45)
        }.value
        return try decode(NodeInstallResult.self, from: result)
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        guard slots.wait(timeout: .now() + timeout) == .success else {
            throw NodeCommandError(message: "The viewer is busy; try again shortly.")
        }
        defer { slots.signal() }
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        let output = BoundedCommandOutput(), diagnostic = BoundedCommandOutput()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment()
        process.standardOutput = stdout; process.standardError = stderr
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch {
            throw NodeCommandError(message: "Cannot run bundled comms: \(error.localizedDescription)")
        }
        let readers = DispatchGroup()
        for (pipe, collector) in [(stdout, output), (stderr, diagnostic)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    collector.append(chunk)
                }
            }
        }
        if ended.wait(timeout: .now() + timeout) != .success {
            process.terminate()
            if ended.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL); _ = ended.wait(timeout: .now() + 1) }
            _ = readers.wait(timeout: .now() + 1)
            throw NodeCommandError(message: "The local node request timed out. Agent delivery continues independently.")
        }
        guard readers.wait(timeout: .now() + 2) == .success else {
            throw NodeCommandError(message: "The node helper did not finish closing its output stream.")
        }
        let data = try output.result()
        if process.terminationStatus != 0 {
            let detail = try diagnostic.result()
            if let o = try? JSONSerialization.jsonObject(with: detail) as? [String: Any], let error = o["error"] as? String {
                throw NodeCommandError(message: error)
            }
            let message = String(data: detail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NodeCommandError(message: message?.isEmpty == false ? String(message!.prefix(1200)) : "Comms exited with status \(process.terminationStatus).")
        }
        return data
    }
}

/// Observes state changes only. Quitting this process never closes an agent
/// attachment and never stops the separately supervised node.
final class CommsNodeEventObserver {
    private var process: Process?
    private var output: Pipe?
    private var generation = UUID()
    private let gate = ObserverNotificationGate()
    func start(changed: @escaping () -> Void) {
        guard process == nil else { return }
        let current = UUID(); generation = current
        let child = Process(), pipe = Pipe()
        child.executableURL = CommsNodeClient.binary
        child.arguments = ["--data-dir", CommsNodeClient.dataDirectory, "events", "--json"]
        child.environment = CommsNodeClient.environment()
        child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.gate.notify(changed) }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let self, self.generation == current else { return }
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil; self.process = nil
                changed(); self.start(changed: changed)
            }
        }
        do { try child.run(); process = child; output = pipe } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }
    func stop() {
        generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; output = nil
    }
    deinit { stop() }
}

private final class ObserverNotificationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    func notify(_ changed: @escaping () -> Void) {
        lock.lock()
        if pending { lock.unlock(); return }
        pending = true; lock.unlock()
        DispatchQueue.main.async {
            self.lock.lock(); self.pending = false; self.lock.unlock()
            changed()
        }
    }
}
