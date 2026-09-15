import SwiftUI
import AppKit
import Combine

enum PresenceTier: Int, Comparable {
    case gone = 0, present = 1, armed = 2
    static func < (l: PresenceTier, r: PresenceTier) -> Bool { l.rawValue < r.rawValue }
    var color: Color { self == .armed ? .green : self == .present ? .yellow : .secondary.opacity(0.35) }
    var label: String { self == .armed ? "listening" : self == .present ? "registered" : "offline" }
}

@MainActor
final class CommsNodeModel: ObservableObject {
    static let shared = CommsNodeModel()
    @Published private(set) var status: NodeStatus?
    @Published private(set) var agents: [NodeAgent] = []
    @Published private(set) var sessions: [NodeSession] = []
    @Published private(set) var peers: [NodePeer] = []
    @Published private(set) var grants: [NodeGrant] = []
    @Published private(set) var presence: [NodePresence] = []
    @Published private(set) var error = ""
    @Published private(set) var actionStatus = ""
    @Published private(set) var busy = false
    private var refreshing = false
    private var refreshingRemote = false
    private var started = false
    private var eventObserver = CommsNodeEventObserver()
    private var eventRefresh: DispatchWorkItem?

    func start() {
        guard !started else { return }; started = true
        Task {
            do {
                let node = try await CommsNodeClient.query(NodeStatus.self, ["status"])
                guard node.apiVersion == CommsNodeClient.apiVersion else {
                    error = "This viewer requires node API v1; installed node reports v\(node.apiVersion)."
                    return
                }
                status = node
                // Install the bundled CLI/skill once, even if a separately
                // installed compatible node was already reachable.
                let installed = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/agent-monitor/comms-install.json")
                if !FileManager.default.fileExists(atPath: installed.path) { install(); return }
                observe(); refresh()
            } catch { install() }
        }
    }
    func install() {
        guard !busy else { return }; busy = true; actionStatus = "Installing local comms…"
        Task {
            defer { busy = false }
            do {
                let result = try await CommsNodeClient.install()
                actionStatus = "Local comms ready. Use /\(result.skill) in Claude or a supported Codex session."
                error = ""; observe(); refresh()
            } catch { self.error = error.localizedDescription; actionStatus = "" }
        }
    }
    private func observe() {
        eventObserver.start { [weak self] in
            guard let self else { return }
            self.eventRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            self.eventRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
    func stopObserving() { eventObserver.stop() }
    func refresh(includeRemote: Bool = false) {
        if includeRemote { refreshRemotePresence() }
        guard !refreshing else { return }; refreshing = true
        Task {
            defer { refreshing = false }
            do {
                async let node = CommsNodeClient.query(NodeStatus.self, ["status"])
                async let localAgents = CommsNodeClient.query([NodeAgent]?.self, ["agents"])
                async let localSessions = CommsNodeClient.query([NodeSession]?.self, ["sessions"])
                let (newStatus, newAgents, newSessions) = try await (node, localAgents, localSessions)
                guard newStatus.apiVersion == CommsNodeClient.apiVersion else {
                    self.error = "Incompatible node API v\(newStatus.apiVersion). Existing node remains running."
                    self.status = nil; return
                }
                self.status = newStatus; agents = newAgents ?? []; sessions = newSessions ?? []; error = ""
                async let paired = CommsNodeClient.query([NodePeer]?.self, ["peers"])
                async let permissions = CommsNodeClient.query([NodeGrant]?.self, ["grants"])
                (peers, grants) = try await (paired ?? [], permissions ?? [])
            } catch { self.error = error.localizedDescription; self.status = nil }
        }
    }
    private func refreshRemotePresence() {
        guard !refreshingRemote else { return }; refreshingRemote = true
        Task {
            defer { refreshingRemote = false }
            // A broker outage doesn't discard healthy local-agent state.
            presence = (try? await CommsNodeClient.query([NodePresence]?.self, ["who"])) ?? []
        }
    }
    func alias(harnessID: String) -> String? {
        guard let session = sessions.first(where: { $0.harnessSessionId == harnessID && $0.endedAt == nil }) else { return nil }
        return agents.first(where: { $0.id == session.agentId })?.alias
    }
    func tier(harnessID: String) -> PresenceTier {
        guard status != nil,
              let session = sessions.first(where: { $0.harnessSessionId == harnessID && $0.endedAt == nil }),
              let agent = agents.first(where: { $0.id == session.agentId }) else { return .gone }
        return agent.online ? .armed : .present
    }
    func permission(for peer: NodePeer) -> NodeGrant? { grants.first(where: { $0.granteeMachineId == peer.id }) }
    func perform(_ arguments: [String], success: String) {
        guard !busy else { return }; busy = true; actionStatus = ""
        Task {
            defer { busy = false }
            do { _ = try await CommsNodeClient.command(arguments); actionStatus = success; error = ""; refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func setMessages(_ enabled: Bool, peer: NodePeer) {
        perform([enabled ? "grant" : "ungrant", peer.machineId], success: "Permissions updated for \(peer.alias).")
    }
    func setHistory(_ enabled: Bool, peer: NodePeer) {
        perform([enabled ? "grant" : "ungrant", peer.machineId, "--read-history"], success: "History permission updated for \(peer.alias).")
    }
}

struct CommsDashboardView: View {
    @EnvironmentObject var store: AgentStore
    @ObservedObject private var node = CommsNodeModel.shared
    @State private var selected: String?
    @State private var history: [NodeMessage] = []
    @State private var cursor: String?
    @State private var historyError = ""
    @State private var loadingHistory = false
    @State private var historyGeneration = UUID()
    @AppStorage("agentMonitor.commsFontScale") private var fontScale = 1.0
    private let remoteTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text("Comms").font(.headline)
                if let status = node.status {
                    Text("\(status.name.isEmpty ? "This machine" : status.name) · v\(status.version)").font(.caption).foregroundStyle(.secondary)
                    Label(status.brokerConnected ? "Broker connected" : "Local ready", systemImage: status.brokerConnected ? "network" : "desktopcomputer").font(.caption)
                }
                Spacer()
                Button { fontScale = max(0.8, fontScale - 0.1) } label: { Image(systemName: "textformat.size.smaller") }
                Button { fontScale = min(2.4, fontScale + 0.1) } label: { Image(systemName: "textformat.size.larger") }
                Button { node.refresh(includeRemote: true); loadHistory() } label: { Image(systemName: "arrow.clockwise") }
                Button { store.commsOverlayOpen = false } label: { Image(systemName: "xmark.circle.fill") }
            }.buttonStyle(.borderless).padding(12)
            Divider()
            if node.status == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text(node.busy ? "Setting up local comms…" : "Local node unavailable").font(.headline)
                    Text(node.error).font(.callout).textSelection(.enabled)
                    Button("Install / start bundled node") { node.install() }.disabled(node.busy)
                    Text("The node runs independently of this window. Closing Agent Monitor never closes agent communications.").foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HSplitView {
                    agentsPane.frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
                    historyPane.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { node.refresh(includeRemote: true) }
        .onReceive(remoteTimer) { _ in node.refresh(includeRemote: true) }
        .onChange(of: selected) { _ in loadHistory() }
    }
    private var agentsPane: some View {
        List(selection: $selected) {
            Section("Local agents") {
                ForEach(node.agents.filter { $0.retiredAt == nil }) { agent in
                    HStack(spacing: 8) {
                        Circle().fill(agent.online ? Color.green : .secondary.opacity(0.4)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.alias).fontWeight(.medium)
                            Text("\(agent.persistent ? "persistent" : "ephemeral") · \(agent.scope) · \(agent.online ? "listening" : "offline")").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(agent.id)
                    .contextMenu {
                        Button("Copy identity ID") { copy(agent.id) }
                        if agent.persistent { Button("Copy resume command") { copy("/\(CommsNodeClient.installedSkill) \(agent.alias) --persistent") } }
                    }
                }
            }
            Section("Remote agents") {
                ForEach(node.presence.filter { $0.machineId != node.status?.machineId }) { agent in
                    HStack(spacing: 8) {
                        Circle().fill(agent.online ? Color.green : .secondary.opacity(0.4)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.address)
                            Text(agent.online ? "listening" : "offline").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(agent.address)
                }
            }
        }.listStyle(.sidebar)
    }
    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selected.flatMap { id in node.agents.first(where: { $0.id == id })?.alias } ?? selected ?? "Message history").font(.headline)
                Spacer()
                if loadingHistory { ProgressView().controlSize(.small) }
            }.padding(12)
            Text("Read-only peer content. Reading never consumes mail; handoff does not mean the model acted on it.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if !historyError.isEmpty { Text(historyError).foregroundStyle(.red).padding(12).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if selected == nil { Text("Select an agent to read its comms history.").foregroundStyle(.secondary) }
                    ForEach(history, id: \.stableID) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(senderLabel(message)).font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Text(message.date, style: .time).font(.caption)
                                Text(message.state).font(.caption).foregroundStyle(message.state == "undeliverable" ? .red : .secondary)
                            }
                            Text(message.body ?? "").font(.system(size: 13 * fontScale)).textSelection(.enabled)
                            if let failure = message.failureCode { Text(failure).font(.caption).foregroundStyle(.secondary) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04)).cornerRadius(8)
                    }
                    if cursor != nil { Button("Load older messages") { loadHistory(older: true) }.disabled(loadingHistory) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func senderLabel(_ message: NodeMessage) -> String {
        let machine = message.senderMachineId == node.status?.machineId ? (node.status?.name ?? "local") : (node.peers.first(where: { $0.machineId == message.senderMachineId })?.alias ?? message.senderMachineId)
        let alias = node.agents.first(where: { $0.id == message.senderAgentId })?.alias
            ?? node.presence.first(where: { $0.agentId == message.senderAgentId && $0.machineId == message.senderMachineId })?.alias
            ?? message.senderAgentId
        return machine + ":" + alias
    }
    private func loadHistory(older: Bool = false) {
        guard let selected else { history = []; cursor = nil; return }
        if older && loadingHistory { return }
        let generation = UUID(); historyGeneration = generation
        loadingHistory = true; historyError = ""
        var args = ["log", selected, "--operator", "--limit", "50"]
        if older, let cursor { args += ["--cursor", cursor] }
        Task {
            do {
                let page = try await CommsNodeClient.query(NodeHistoryPage.self, args)
                guard historyGeneration == generation else { return }
                history = older ? history + page.records : page.records
                cursor = page.nextCursor; loadingHistory = false
            } catch {
                guard historyGeneration == generation else { return }
                historyError = error.localizedDescription; loadingHistory = false
            }
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

struct CommsNodeSettingsView: View {
    @ObservedObject private var node = CommsNodeModel.shared
    @State private var machineName = ""
    @State private var brokerURL = ""
    @State private var peerAlias = ""
    @State private var exportStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = node.status {
                Label("Local node v\(status.version)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status.machineId).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    TextField("Machine nickname", text: $machineName)
                    Button("Save name") { node.perform(["name", machineName], success: "Machine nickname saved.") }.disabled(machineName.isEmpty || node.busy)
                }
                HStack {
                    TextField("Broker URL (https://…)", text: $brokerURL)
                    Button("Connect") { node.perform(["broker", brokerURL], success: "Broker configured.") }.disabled(brokerURL.isEmpty || node.busy)
                    Button("Local only") { node.perform(["broker", "off"], success: "Broker disconnected. Local communication remains available.") }.disabled(node.busy)
                }
                Text(status.brokerConnected ? "Broker connected. Grants control remote access." : "Local comms is ready. Configure a broker only when enabling remote communication.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy public identity") { exportIdentity() }
                    TextField("Nickname for imported peer", text: $peerAlias)
                    Button("Import verified identity…") { importPeer() }.disabled(node.busy)
                }
                if !exportStatus.isEmpty { Text(exportStatus).font(.caption).foregroundStyle(.secondary) }
                Text("Exchange and verify public identity bundles outside the broker. Importing a key grants no access.").font(.caption).foregroundStyle(.secondary)
                ForEach(node.peers) { peer in peerRow(peer) }
                if !node.agents.filter({ $0.persistent }).isEmpty {
                    Divider()
                    Text("Saved identities").font(.subheadline.bold())
                    ForEach(node.agents.filter { $0.persistent && $0.retiredAt == nil }) { agent in
                        HStack {
                            Text(agent.alias)
                            Text(agent.online ? "attached" : "offline").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy resume command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("/\(CommsNodeClient.installedSkill) \(agent.alias) --persistent", forType: .string)
                            }
                        }
                    }
                }
            } else { Text("Local node is not ready.").font(.headline) }
            HStack {
                Button(node.busy ? "Working…" : "Install / repair bundled node") { node.install() }.disabled(node.busy)
                Button("Refresh") { node.refresh() }
            }
            if !node.actionStatus.isEmpty { Text(node.actionStatus).font(.caption).textSelection(.enabled) }
            if !node.error.isEmpty { Text(node.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("Claude receives through its own Monitor stream. Codex requires the supported app-server tool-output integration. Agent Monitor never types peer text as a user message.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { machineName = node.status?.name ?? ""; node.refresh() }
    }
    private func peerRow(_ peer: NodePeer) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(peer.alias).fontWeight(.medium)
                Spacer()
                Toggle("May discover and send", isOn: Binding(get: { node.permission(for: peer)?.allowMessages ?? false }, set: { node.setMessages($0, peer: peer) }))
                Toggle("May read global history", isOn: Binding(get: { node.permission(for: peer)?.allowHistory ?? false }, set: { node.setHistory($0, peer: peer) }))
            }.disabled(node.busy)
            Text(peer.machineId).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(.vertical, 4)
    }
    private func importPeer() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.prompt = "Import verified key"
        if panel.runModal() == .OK, let url = panel.url {
            var args = ["pair", "--file", url.path]
            if !peerAlias.isEmpty { args += ["--alias", peerAlias] }
            node.perform(args, success: "Peer identity pinned. Choose directional grants below.")
        }
    }
    private func exportIdentity() {
        Task {
            do {
                let data = try await CommsNodeClient.command(["export"])
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                exportStatus = "Public identity copied. Verify it with the other machine outside the broker."
            } catch { exportStatus = error.localizedDescription }
        }
    }
}
