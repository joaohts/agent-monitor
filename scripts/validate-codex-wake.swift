import Foundation

@main
struct ValidateCodexWake {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-wake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let reader = TranscriptReader()
        var revision = 0

        func write(_ text: String, append: Bool = true) throws {
            if !append || !FileManager.default.fileExists(atPath: file.path) {
                try Data(text.utf8).write(to: file)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
                try handle.close()
            }
            revision += 1
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_789_500_000 + Double(revision))], ofItemAtPath: file.path)
        }
        func lifecycle(_ type: String, _ id: String, _ time: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [
                "type": "event_msg", "timestamp": time,
                "payload": ["type": type, "turn_id": id],
            ])
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        func agent(_ status: AgentStatus = .inactive) -> Agent {
            var value = Agent(id: "session", cwd: "/project", status: status,
                              firstSeen: "2026-09-16T15:19:14Z", lastUpdate: "2026-09-16T15:24:31Z",
                              lastMessage: nil, transcriptPath: file.path)
            value.source = .codex
            value.codexTurnId = "first"
            return value
        }

        // The reported sequence: user turn completes, the session becomes
        // inactive, then a peer tool-output wake starts a turn without a user hook.
        try write(lifecycle("task_started", "first", "2026-09-16T15:19:14.245Z"))
        try write(lifecycle("task_complete", "first", "2026-09-16T15:19:30.287Z"))
        precondition(reader.read(path: file.path).codexTurn?.wakeEvent(for: agent()) == nil)
        try write(lifecycle("task_started", "peer-turn", "2026-09-16T15:25:50.107Z"))
        try write("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"comms_receive\",\"output\":\"peer content\"}}\n")
        let active = reader.read(path: file.path)
        let wake = active.codexTurn?.wakeEvent(for: agent())
        precondition(wake?.event == .started && wake?.source == .codex)
        precondition(wake?.turnId == "peer-turn" && wake?.ts == "2026-09-16T15:25:50Z")
        precondition(active.userMessageCount == 0, "peer tool output became a human message")

        for state in [AgentStatus.idle, .inactive, .apiError] {
            precondition(active.codexTurn?.wakeEvent(for: agent(state)) != nil)
        }
        for state in [AgentStatus.running, .away, .needsAttention] {
            precondition(active.codexTurn?.wakeEvent(for: agent(state)) == nil)
        }
        var alreadyObserved = agent(.idle)
        alreadyObserved.codexTurnId = "peer-turn"
        precondition(active.codexTurn?.wakeEvent(for: alreadyObserved) == nil, "Stop-before-task_complete race restarted the same turn")
        var sameSecond = agent(.idle)
        sameSecond.lastUpdate = "2026-09-16T15:25:50Z"
        precondition(active.codexTurn?.wakeEvent(for: sameSecond) != nil, "a new turn in the same second was lost")
        sameSecond.codexTurnId = nil
        precondition(active.codexTurn?.wakeEvent(for: sameSecond) == nil, "ambiguous legacy completion was treated as a wake")
        sameSecond.lastMessage = "session start"
        precondition(active.codexTurn?.wakeEvent(for: sameSecond) != nil, "first native turn after SessionStart was lost")
        var stale = agent()
        stale.lastUpdate = "2026-09-16T15:26:00Z"
        precondition(active.codexTurn?.wakeEvent(for: stale) == nil)
        var claude = agent(); claude.source = .claudeCode
        precondition(active.codexTurn?.wakeEvent(for: claude) == nil)
        var child = agent(); child.parentSessionId = "parent"
        precondition(active.codexTurn?.wakeEvent(for: child) == nil)

        try write(lifecycle("task_complete", "first", "2026-09-16T15:25:51Z"))
        precondition(reader.read(path: file.path).codexTurn?.isActive == true, "stale completion stopped a newer turn")
        try write(lifecycle("task_complete", "peer-turn", "2026-09-16T15:25:52.001Z"))
        precondition(reader.read(path: file.path).codexTurn?.wakeEvent(for: agent()) == nil)
        try write(lifecycle("task_started", "aborted", "2026-09-16T15:26:00Z"))
        try write(lifecycle("turn_aborted", "aborted", "2026-09-16T15:26:01Z"))
        precondition(reader.read(path: file.path).codexTurn?.isActive == false)

        let partial = lifecycle("task_started", "partial", "2026-09-16T15:27:00.123Z")
        let split = partial.index(partial.startIndex, offsetBy: partial.count / 2)
        try write(String(partial[..<split]))
        precondition(reader.read(path: file.path).codexTurn?.id == "aborted")
        try write(String(partial[split...]))
        precondition(reader.read(path: file.path).codexTurn?.id == "partial")
        try write("{}\n", append: false)
        precondition(reader.read(path: file.path).codexTurn == nil, "truncation retained a stale active turn")

        precondition(shouldWatchTranscript(agent(), hasCommsAttachment: true))
        precondition(!shouldWatchTranscript(agent(), hasCommsAttachment: false))
        precondition(!shouldWatchTranscript(claude, hasCommsAttachment: true))
        precondition(!shouldWatchTranscript(child, hasCommsAttachment: true))
        precondition(shouldWatchTranscript(agent(.idle), hasCommsAttachment: false))

        let eventJSON = Data(#"{"event":"stopped","session_id":"session","ts":"2026-09-16T15:25:52Z","source":"codex","turn_id":"peer-turn"}"#.utf8)
        let event = try JSONDecoder().decode(AgentEvent.self, from: eventJSON)
        precondition(event.turnId == "peer-turn")
        let legacy = try JSONDecoder().decode(AgentEvent.self, from: Data(#"{"event":"stopped","session_id":"old","ts":"2026-09-16T15:19:30Z"}"#.utf8))
        precondition(legacy.turnId == nil)

        if let path = CommandLine.arguments.dropFirst().first {
            let info = reader.read(path: path)
            print("Read-only live transcript: turn=\(info.codexTurn?.id ?? "none"), active=\(info.codexTurn?.isActive ?? false)")
        }
        print("Codex wake validation passed: native wake, inactive watchers, turn correlation, completion/abort, attention preservation, partial writes and legacy events.")
    }
}
