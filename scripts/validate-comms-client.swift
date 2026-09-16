import Foundation
import Darwin

@main
struct ValidateCommsClient {
    static func main() async throws {
        let statusData = Data(#"{"version":"0.1.0","api_version":1,"machine_id":"m_test","public_key":"public-only","name":"test","broker_enabled":false,"broker_connected":false,"data_dir":"/tmp/comms"}"#.utf8)
        let status = try CommsNodeClient.decode(NodeStatus.self, from: statusData)
        precondition(status.machineId == "m_test" && status.apiVersion == 1)
        precondition(status.brokerServiceKeyConfigured == nil && status.brokerServiceKeyDescription == "Status unavailable")
        var keyedStatus = try JSONSerialization.jsonObject(with: statusData) as! [String: Any]
        for configured in [false, true] {
            keyedStatus["broker_service_key_configured"] = configured
            let decoded = try CommsNodeClient.decode(NodeStatus.self, from: JSONSerialization.data(withJSONObject: keyedStatus))
            precondition(decoded.brokerServiceKeyConfigured == configured)
            precondition(decoded.brokerServiceKeyDescription == (configured ? "Configured" : "Not configured"))
        }
        try serviceKeyArguments()
        let agent = try CommsNodeClient.decode(NodeAgent.self, from: Data(#"{"id":"a_brain","alias":"brain","persistent":true,"online":false,"scope":"local"}"#.utf8))
        precondition(agent.persistent && !agent.online)
        let presence = try CommsNodeClient.decode(NodePresence.self, from: Data(#"{"machine_id":"m_test","peer_alias":"","agent_id":"a_brain","alias":"brain","persistent":true,"online":false}"#.utf8))
        precondition(presence.address == "brain")

        setenv("COMMS_AGENT", "do-not-impersonate", 1)
        precondition(CommsNodeClient.environment()["COMMS_AGENT"] == nil)
        unsetenv("COMMS_AGENT")

        // More output than a pipe's capacity catches wait-before-read deadlocks.
        let output = try CommsNodeClient.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "print('x'*262144)"], timeout: 5)
        precondition(output.count == 262145)
        do {
            _ = try CommsNodeClient.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "print('x'*(5*1024*1024))"], timeout: 5)
            preconditionFailure("oversized output should fail")
        } catch { precondition(error.localizedDescription.contains("4 MiB")) }
        do {
            _ = try CommsNodeClient.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys;sys.stderr.write('{\"code\":\"denied\",\"error\":\"History permission denied\"}');sys.exit(1)"], timeout: 5)
            preconditionFailure("nonzero command should fail")
        } catch { precondition(error.localizedDescription == "History permission denied") }
        let start = Date()
        do {
            _ = try CommsNodeClient.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1)
            preconditionFailure("command should time out")
        } catch { precondition(Date().timeIntervalSince(start) < 3) }
        if let binary = ProcessInfo.processInfo.environment["COMMS_TEST_BINARY"] { try await liveNode(binary) }
        print("Comms viewer client validation passed: schema decoding, sender isolation, bounded subprocess I/O, errors and timeout.")
    }

    static func serviceKeyArguments() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("comms-key-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("Resources")
        let node = resources.appendingPathComponent("CommsNode")
        let regular = try CommsNodeClient.installArguments(resources: resources, node: node)
        precondition(regular == [resources.appendingPathComponent("install-local-comms.sh").path, node.path])

        let keyFile = directory.appendingPathComponent("private key $(literal).txt")
        // The GUI must inspect only metadata: content validation belongs to the
        // node. Deliberately non-ASCII fixture bytes pass only this preflight.
        try Data(repeating: 0, count: 32).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let configured = try CommsNodeClient.installArguments(resources: resources, node: node, serviceKeyFile: keyFile.path)
        precondition(configured == regular + ["--broker-service-key-file", keyFile.path])

        func rejects(_ path: String) {
            do {
                _ = try CommsNodeClient.installArguments(resources: resources, node: node, serviceKeyFile: path)
                preconditionFailure("invalid service-key file metadata was accepted")
            } catch { precondition(error is NodeCommandError) }
        }
        rejects(directory.appendingPathComponent("missing").path)
        rejects(directory.path)
        rejects("")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.path)
        rejects(keyFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        try Data(repeating: 0, count: 31).write(to: keyFile)
        rejects(keyFile.path)
        try Data(repeating: 0, count: 4097).write(to: keyFile)
        rejects(keyFile.path)
        try Data(repeating: 0, count: 32).write(to: keyFile)
        let link = directory.appendingPathComponent("key-symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: keyFile)
        rejects(link.path)
        print("Service-key UI/client checks passed: safe status, file-path forwarding, metadata validation and unchanged ordinary-update arguments.")
    }

    static func liveNode(_ binary: String) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmv-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let node = Process(); node.executableURL = URL(fileURLWithPath: binary)
        node.arguments = ["serve", "--data-dir", directory.path]
        node.standardOutput = FileHandle.nullDevice; node.standardError = FileHandle.nullDevice
        try node.run()
        defer { if node.isRunning { node.terminate(); node.waitUntilExit() }; try? FileManager.default.removeItem(at: directory) }
        setenv("AGENT_MONITOR_COMMS_BIN", binary, 1); setenv("COMMS_DATA_DIR", directory.path, 1)
        defer { unsetenv("AGENT_MONITOR_COMMS_BIN"); unsetenv("COMMS_DATA_DIR") }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("node.sock").path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let status = try await CommsNodeClient.query(NodeStatus.self, ["status"])
        precondition(status.apiVersion == 1)
        _ = try await CommsNodeClient.command(["open", "sender", "--harness", "service"])
        _ = try await CommsNodeClient.command(["open", "brain", "--harness", "service", "--persistent"])
        _ = try await CommsNodeClient.command(["post", "--from", "sender", "--to", "brain", "Viewer integration message"])
        let agents = try await CommsNodeClient.query([NodeAgent].self, ["agents"])
        precondition(agents.contains { $0.alias == "brain" && $0.persistent })
        let page = try await CommsNodeClient.query(NodeHistoryPage.self, ["log", "brain", "--operator"])
        precondition(page.records.first?.body == "Viewer integration message")
        let pending = try await CommsNodeClient.query(NodeHistoryPage.self, ["inbox", "brain", "--operator"])
        precondition(pending.records.count == 1, "history inspection must not consume mail")
        _ = try await CommsNodeClient.command(["stream", "brain", "--once"])
        print("Live node viewer queries passed: status, identities, operator history and non-consuming inspection.")
    }
}
