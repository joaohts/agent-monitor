#!/usr/bin/env swift
// Validates the incremental TranscriptReader optimization:
// 1. Correctness: incremental accumulation matches a full-file parse
// 2. Performance: simulates 1Hz polling with tiny appends on large transcripts

import Foundation

// MARK: - Shared parse model (mirrors AgentMonitor.swift)

struct ParseResult: Equatable {
    var initialTask: String?
    var latestSummary: String?
    var userMessageCount: Int
    var turnCount: Int
    var isToolPending: Bool
    var model: String?
    var titleExcerptHash: Int
    var liveExcerptHash: Int
}

struct ParseState {
    var offset: UInt64 = 0
    var initialTask: String?
    var latestSummary: String?
    var turns: [(role: String, text: String)] = []
    var pendingToolUseIds: Set<String> = []
    var lastModel: String?
}

let headTurns = 2
let tailTurns = 6
let liveUserMessages = 5
let perTurnCharCap = 600
let summaryCharCap = 1200

func extractText(_ message: Any?) -> String? {
    guard let msg = message as? [String: Any] else { return nil }
    let content = msg["content"]
    if let s = content as? String, !s.isEmpty { return s }
    if let arr = content as? [[String: Any]] {
        var pieces: [String] = []
        for item in arr {
            if let t = item["text"] as? String, !t.isEmpty { pieces.append(t) }
        }
        if !pieces.isEmpty { return pieces.joined(separator: "\n") }
    }
    return nil
}

func ingestLine(_ obj: [String: Any], into state: inout ParseState) {
    if let msg = obj["message"] as? [String: Any],
       let content = msg["content"] as? [[String: Any]] {
        for item in content {
            let typ = item["type"] as? String ?? ""
            if typ == "tool_use", let id = item["id"] as? String {
                state.pendingToolUseIds.insert(id)
            } else if typ == "tool_result", let id = item["tool_use_id"] as? String {
                state.pendingToolUseIds.remove(id)
            }
        }
    }
    switch obj["type"] as? String ?? "" {
    case "user":
        if (obj["isMeta"] as? Bool) == true { break }
        if let txt = extractText(obj["message"]) {
            state.turns.append((role: "User", text: txt))
            if state.initialTask == nil { state.initialTask = txt }
        }
    case "assistant":
        if let txt = extractText(obj["message"]) {
            state.turns.append((role: "Assistant", text: txt))
        }
        if let msg = obj["message"] as? [String: Any],
           let m = msg["model"] as? String, !m.isEmpty {
            state.lastModel = m
        }
    case "summary":
        if let s = obj["summary"] as? String, !s.isEmpty { state.latestSummary = s }
    default: break
    }
}

func trim(_ s: String, _ cap: Int) -> String {
    if s.count <= cap { return s }
    let idx = s.index(s.startIndex, offsetBy: cap)
    return String(s[..<idx]) + "…"
}

func buildExcerpt(turns: [(role: String, text: String)], latestSummary: String?) -> String {
    var lines: [String] = []
    if let s = latestSummary, !s.isEmpty {
        lines.append("Most recent auto-generated summary:")
        lines.append(trim(s, summaryCharCap))
        lines.append("")
    }
    let head = Array(turns.prefix(headTurns))
    let tail = Array(turns.suffix(tailTurns)).filter { t in
        !head.contains(where: { $0.role == t.role && $0.text == t.text })
    }
    for t in head { lines.append("\(t.role): \(trim(t.text, perTurnCharCap))") }
    let omitted = turns.count - head.count - tail.count
    if omitted > 0 { lines.append("[…\(omitted) turns omitted…]") }
    for t in tail { lines.append("\(t.role): \(trim(t.text, perTurnCharCap))") }
    return lines.joined(separator: "\n")
}

func buildLiveExcerpt(turns: [(role: String, text: String)], latestSummary: String?) -> String {
    let userIndices = turns.indices.filter { turns[$0].role == "User" }
    let selected = userIndices.suffix(liveUserMessages)
    guard let firstSelected = selected.first else { return "" }
    let relevant = Array(turns[firstSelected...])
    var lines: [String] = []
    if let s = latestSummary, !s.isEmpty {
        lines.append("Earlier summary of the session:")
        lines.append(trim(s, summaryCharCap))
        lines.append("")
    }
    for t in relevant {
        lines.append("\(t.role): \(trim(t.text, perTurnCharCap))")
    }
    return lines.joined(separator: "\n")
}

func toResult(_ state: ParseState) -> ParseResult {
    let userCount = state.turns.filter { $0.role == "User" }.count
    let title = buildExcerpt(turns: state.turns, latestSummary: state.latestSummary)
    let live = buildLiveExcerpt(turns: state.turns, latestSummary: state.latestSummary)
    return ParseResult(
        initialTask: state.initialTask,
        latestSummary: state.latestSummary,
        userMessageCount: userCount,
        turnCount: state.turns.count,
        isToolPending: !state.pendingToolUseIds.isEmpty,
        model: state.lastModel,
        titleExcerptHash: title.hashValue,
        liveExcerptHash: live.hashValue
    )
}

// MARK: - Parsers

func parseFullFile(path: String) -> ParseState {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let text = String(data: data, encoding: .utf8) else {
        return ParseState()
    }
    var state = ParseState()
    state.offset = UInt64(data.count)
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
        ingestLine(obj, into: &state)
    }
    return state
}

func ingestNewBytes(path: String, into state: inout ParseState) {
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
    defer { try? handle.close() }
    let newData: Data
    do {
        try handle.seek(toOffset: state.offset)
        newData = try handle.readToEnd() ?? Data()
    } catch { return }
    guard !newData.isEmpty, let lastNL = newData.lastIndex(of: 0x0A) else { return }
    let completeCount = newData.distance(from: newData.startIndex, to: lastNL) + 1
    let completeData = newData.prefix(completeCount)
    state.offset += UInt64(completeCount)
    for lineData in completeData.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
        ingestLine(obj, into: &state)
    }
}

func parseIncremental(path: String) -> ParseState {
    var state = ParseState()
    ingestNewBytes(path: path, into: &state)
    return state
}

func parseIncrementalLineByLine(path: String) -> ParseState {
    guard var data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return ParseState() }
    var state = ParseState()
    while !data.isEmpty {
        if let nl = data.firstIndex(of: 0x0A) {
            let end = data.distance(from: data.startIndex, to: nl) + 1
            let chunk = data.prefix(end)
            state.offset += UInt64(end)
            for lineData in chunk.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                ingestLine(obj, into: &state)
            }
            data.removeFirst(end)
        } else {
            // partial line at end — should not be consumed
            break
        }
    }
    return state
}

// MARK: - Benchmark helpers

func bench(_ label: String, iterations: Int, _ block: () -> Void) -> Double {
    block()
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations { block() }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    let perTickMs = (elapsed / Double(iterations)) * 1000
    let labelPad = label.padding(toLength: 28, withPad: " ", startingAt: 0)
    print(String(format: "  %@ %6.2f ms/tick  (%d ticks, %.0f ms total)", labelPad, perTickMs, iterations, elapsed * 1000))
    return perTickMs
}

func humanSize(_ bytes: Int) -> String {
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
    return "\(bytes) B"
}

// MARK: - Main

let home = FileManager.default.homeDirectoryForCurrentUser.path
let projectsDir = "\(home)/.claude/projects"
var transcripts: [String] = []

if let env = ProcessInfo.processInfo.environment["TRANSCRIPT_PATHS"] {
    transcripts = env.split(separator: ":").map(String.init)
} else if let enumerator = FileManager.default.enumerator(atPath: projectsDir) {
    while let rel = enumerator.nextObject() as? String {
        if rel.hasSuffix(".jsonl") && !rel.contains("/subagents/") {
            transcripts.append("\(projectsDir)/\(rel)")
        }
    }
}

transcripts.sort { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int ?? 0)! > (try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int ?? 0)! }

if transcripts.isEmpty {
    fputs("No transcript files found under \(projectsDir)\n", stderr)
    exit(1)
}

print("=== Incremental transcript parse validation ===\n")
print("Found \(transcripts.count) transcript(s). Testing top \(min(5, transcripts.count)) by size.\n")

var allCorrect = true
let pollTicks = 60  // simulates 60s of 1Hz reload()

for (i, path) in transcripts.prefix(5).enumerated() {
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    let name = (path as NSString).lastPathComponent
    print("[\(i + 1)] \(name) (\(humanSize(size)))")

    let full = parseFullFile(path: path)
    let incr = parseIncremental(path: path)
    let incrLineByLine = parseIncrementalLineByLine(path: path)

    let rFull = toResult(full)
    let rIncr = toResult(incr)
    let rLineByLine = toResult(incrLineByLine)

    if rFull == rIncr && rFull == rLineByLine {
        print("  ✓ correctness: incremental == full parse")
        print("    turns=\(rFull.turnCount) users=\(rFull.userMessageCount) toolPending=\(rFull.isToolPending) model=\(rFull.model ?? "nil")")
    } else {
        allCorrect = false
        print("  ✗ MISMATCH")
        print("    full:         \(rFull)")
        print("    incremental:  \(rIncr)")
        print("    line-by-line: \(rLineByLine)")
    }

    // Benchmark: simulate 60 ticks where each tick appends one small assistant line
    let appendLine = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"bench tick\",\"model\":\"claude-sonnet-4-6\"}}\n"
    let appendData = appendLine.data(using: .utf8)!
    let tmpPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("am-bench-\(name)")
    try? FileManager.default.removeItem(atPath: tmpPath)
    try? FileManager.default.copyItem(atPath: path, toPath: tmpPath)

    var incrState = ParseState()
    ingestNewBytes(path: tmpPath, into: &incrState)

    let oldMs = bench("OLD (full re-read)", iterations: pollTicks) {
        _ = parseFullFile(path: tmpPath)
    }

    _ = bench("NEW (incremental)", iterations: pollTicks) {
        // touch mtime like the real app (append + remove last line to keep size stable-ish)
        ingestNewBytes(path: tmpPath, into: &incrState)
    }

    // Append a line before each incremental tick in a second pass for realistic growth
    var incrState2 = ParseState()
    ingestNewBytes(path: tmpPath, into: &incrState2)
    let newWithAppendMs = bench("NEW + tiny append/tick", iterations: pollTicks) {
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: tmpPath)) {
            try? h.seekToEnd()
            try? h.write(contentsOf: appendData)
            try? h.close()
        }
        ingestNewBytes(path: tmpPath, into: &incrState2)
    }

    let speedup = oldMs / max(newWithAppendMs, 0.001)
    print(String(format: "  → speedup (with appends): %.1fx\n", speedup))

    try? FileManager.default.removeItem(atPath: tmpPath)
}

// Partial-line edge case
print("--- Edge case: partial line (write caught mid-flush) ---")
let partialDir = NSTemporaryDirectory()
let partialPath = (partialDir as NSString).appendingPathComponent("am-partial-line.jsonl")
let fullLine = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}\n"
let partialTail = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"incompl"
try? fullLine.write(toFile: partialPath, atomically: true, encoding: .utf8)
if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: partialPath)) {
    try? h.seekToEnd()
    try? h.write(contentsOf: partialTail.data(using: .utf8)!)
    try? h.close()
}
var partialState = ParseState()
ingestNewBytes(path: partialPath, into: &partialState)
let beforeCompletion = toResult(partialState)
// complete the line
if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: partialPath)) {
    try? h.seekToEnd()
    try? h.write(contentsOf: "ete\"}}\n".data(using: .utf8)!)
    try? h.close()
}
ingestNewBytes(path: partialPath, into: &partialState)
let afterCompletion = toResult(partialState)
if beforeCompletion.userMessageCount == 1 && beforeCompletion.turnCount == 1 &&
   afterCompletion.turnCount == 2 {
    print("  ✓ partial line held back until complete")
} else {
    allCorrect = false
    print("  ✗ partial line handling failed: before=\(beforeCompletion) after=\(afterCompletion)")
}
try? FileManager.default.removeItem(atPath: partialPath)

print("\n=== Summary ===")
if allCorrect {
    print("All correctness checks passed.")
    print("\nTo validate in the live app:")
    print("  1. ./build.sh")
    print("  2. Open 3+ Claude Code sessions on large projects")
    print("  3. Watch Activity Monitor — AgentMonitor CPU should stay low while sessions run")
    print("  4. Confirm live subtitles + away detection still update in real time")
} else {
    print("FAILURES detected — incremental parse diverges from full parse.")
    exit(1)
}
