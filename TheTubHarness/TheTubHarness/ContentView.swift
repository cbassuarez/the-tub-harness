import SwiftUI
import Combine

final class ModelServerProcess: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusMessage: String = "stopped"

    private var process: Process?
    private let tubMlRoot = "/Users/seb/the-tub-ml"
    private let configRelPath = "configs/stub_policy_v1.yaml"

    func start() {
        guard process == nil else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let venvBin = "\(tubMlRoot)/.venv/bin/tub-ml"
        let fallback = "source \(tubMlRoot)/.venv/bin/activate && tub-ml"
        let cmd = [
            "cd \(tubMlRoot)",
            "if [ -x \(venvBin) ]; then \(venvBin) serve --config \(configRelPath); else \(fallback) serve --config \(configRelPath); fi"
        ].joined(separator: " && ")
        proc.arguments = ["-lc", cmd]
        proc.currentDirectoryURL = URL(fileURLWithPath: tubMlRoot)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.statusMessage = p.terminationStatus == 0 ? "exited" : "exited(\(p.terminationStatus))"
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            statusMessage = "running (pid \(proc.processIdentifier))"
        } catch {
            statusMessage = "launch failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.interrupt()  // SIGINT — clean shutdown like Ctrl-C
        statusMessage = "stopping..."
    }

    deinit {
        process?.interrupt()
    }
}

enum HarnessRunMode: String, Identifiable, CaseIterable {
    case training
    case performance

    var id: String { rawValue }
    var title: String { self == .training ? "Training" : "Performance" }
    var subtitle: String {
        self == .training
            ? "Full logging, rubric, replay, human feedback"
            : "Live DSP only — no logging, no training UI"
    }
}

enum HarnessRunModeStorage {
    private static let key = "lastHarnessRunMode"
    static var last: HarnessRunMode? {
        UserDefaults.standard.string(forKey: key).flatMap(HarnessRunMode.init(rawValue:))
    }
    static func save(_ mode: HarnessRunMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

enum HarnessRunProfile: String, Identifiable {
    case audioAndFeatures

    var id: String { rawValue }

    var title: String {
        "Audio + Real Features"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

enum ControlRoomSeverity: String {
    case info
    case warning
    case error

    var color: Color {
        switch self {
        case .info: return Color(red: 0.47, green: 0.86, blue: 0.94)
        case .warning: return Color(red: 0.98, green: 0.78, blue: 0.34)
        case .error: return Color(red: 0.94, green: 0.39, blue: 0.37)
        }
    }
}

struct ControlRoomEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let severity: ControlRoomSeverity
}

struct ModelSlotProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var notes: String

    var resolvedPort: UInt16 {
        UInt16(max(1, min(port, Int(UInt16.max))))
    }

    static func defaultSlots() -> [ModelSlotProfile] {
        [
            ModelSlotProfile(id: UUID(), name: "Local Stub", host: "127.0.0.1", port: 9910, notes: "Default local model server"),
            ModelSlotProfile(id: UUID(), name: "Local Variant", host: "127.0.0.1", port: 9911, notes: "Alternate local profile"),
            ModelSlotProfile(id: UUID(), name: "Stage A", host: "127.0.0.1", port: 9920, notes: "Staging pipeline A"),
            ModelSlotProfile(id: UUID(), name: "Stage B", host: "127.0.0.1", port: 9921, notes: "Staging pipeline B")
        ]
    }
}

enum ModelSlotPersistence {
    static func load(appName: String = "TheTubHarness") -> [ModelSlotProfile] {
        guard let url = url(appName: appName),
              let data = try? Data(contentsOf: url),
              let slots = try? JSONDecoder().decode([ModelSlotProfile].self, from: data),
              !slots.isEmpty else {
            return ModelSlotProfile.defaultSlots()
        }
        return slots
    }

    static func save(slots: [ModelSlotProfile], appName: String = "TheTubHarness") {
        guard let url = url(appName: appName) else { return }
        let enc = JSONEncoder()
        if #available(macOS 13.0, *) {
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            enc.outputFormatting = [.prettyPrinted]
        }
        guard let data = try? enc.encode(slots) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func url(appName: String) -> URL? {
        guard let base = try? SessionPaths.appSupportBaseDirectory(appName: appName) else { return nil }
        return base.appendingPathComponent("ui", isDirectory: true).appendingPathComponent("model_slots.json")
    }
}

struct RubricScores: Codable, Equatable, Sendable {
    var stability: Double = 3
    var responsiveness: Double = 3
    var timbreQuality: Double = 3
    var modeFidelity: Double = 3
    var performanceConfidence: Double = 3

    var average: Double {
        (stability + responsiveness + timbreQuality + modeFidelity + performanceConfidence) / 5.0
    }
}

private struct RubricEntry: Codable, Sendable {
    let tsMs: Int
    let sessionId: String?
    let bundleId: String?
    let mode: Int
    let runProfile: String
    let scores: RubricScores
    let notes: String
    let endpointHost: String
    let endpointPort: UInt16
}

private final class RubricEntryWriter {
    private let queue = DispatchQueue(label: "tub.rubric.writer", qos: .utility)

    func append(_ entry: RubricEntry, appName: String = "TheTubHarness") {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        guard var payload = try? enc.encode(entry) else { return }
        payload.append(0x0A)

        queue.async {
            guard let base = try? SessionPaths.appSupportBaseDirectory(appName: appName) else { return }
            let fileURL = base
                .appendingPathComponent("rubrics", isDirectory: true)
                .appendingPathComponent("rubric_entries.jsonl")

            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                handle.write(payload)
                try handle.close()
            } catch {
                // Best effort only.
            }
        }
    }
}

struct TelemetrySample: Identifiable {
    let id = UUID()
    let ts: Date
    let latencyMs: Double
    let tickMs: Double
    let timeoutCount: Double
    let sentCount: Double
    let recvCount: Double
    let interventions: [String]
    let replayAudioTimeS: Double
    let replayTargetTimeS: Double
    let replayAlignmentDeltaS: Double
}

// MARK: - Throttled Telemetry Subviews
// These structs take ObservableObject references as plain `let` (NOT @ObservedObject),
// so their body only re-evaluates when their @State changes via timer — not on every
// parent re-evaluation. This prevents 10Hz+ layout churn from breaking ScrollView gestures.

private struct TelemetryDisplaySnap: Equatable {
    var sent = "0"
    var recv = "0"
    var timeout = "0"
    var latency = "na"
    var tick = "na"
    var audioIn = "—"
    var fallbackReason: String?
    var lastError: String?
    var roundTrip: String?
    var features = ""
    var diag = ""
}

struct TelemetryReadoutView: View {
    let client: TubMLClient
    let analyzer: AudioInputAnalyzer
    let audio: AudioEngineController

    @State private var snap = TelemetryDisplaySnap()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                metricCard("Sent", value: snap.sent)
                metricCard("Recv", value: snap.recv)
                metricCard("Timeout", value: snap.timeout)
                metricCard("Latency", value: snap.latency)
                metricCard("Tick", value: snap.tick)
                metricCard("AudioIn", value: snap.audioIn)
            }

            if let reason = snap.fallbackReason {
                Text("Feature fallback: \(reason)")
                    .foregroundStyle(Color.orange)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }

            if let err = snap.lastError {
                Text("Error: \(err)")
                    .foregroundStyle(Color(red: 0.94, green: 0.39, blue: 0.37))
            }

            if let rt = snap.roundTrip {
                Text(rt)
                    .foregroundStyle(Color.black.opacity(0.82))
                    .lineLimit(2)
            }

            Text(snap.features)
                .foregroundStyle(Color.black.opacity(0.72))
                .lineLimit(2)

            if !snap.diag.isEmpty {
                Text(snap.diag)
                    .foregroundStyle(Color.orange.opacity(0.92))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .lineLimit(3)
            }
        }
        .onReceive(Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        var next = TelemetryDisplaySnap()
        next.sent = "\(client.sentCount)"
        next.recv = "\(client.recvCount)"
        next.timeout = "\(client.timeoutCount)"
        next.latency = client.lastLatencyMs.map { "\($0)ms" } ?? "na"
        next.tick = client.lastTickIntervalMs.map { String(format: "%.1fms", $0) } ?? "na"
        next.audioIn = analyzer.inputStatus.label
        next.fallbackReason = analyzer.fallbackReason
        next.lastError = client.lastError
        if let out = client.lastOut {
            next.roundTrip = Self.formatRoundTrip(out)
        }
        next.features = Self.formatFeatures(analyzer.latestFeatures)
        if let out = client.lastOut, out.mode == 5 || out.mode == 6 {
            next.diag = Self.formatDiag(mode: out.mode, interventions: audio.snapshotSafetyInterventions())
        }
        if next != snap { snap = next }
    }

    private func metricCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(ShellChromePalette.inkSoft)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(ShellChromePalette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(ShellChromePalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ShellChromePalette.border, lineWidth: 1)
        }
    }

    private static func formatRoundTrip(_ out: ModelOut) -> String {
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "na" }
        let preset = out.picks.presetId ?? "nil"
        let spatial = out.picks.spatialPatternId ?? "nil"
        return "RoundTrip mode=\(out.mode) preset=\(preset) level=\(fmt(out.params["level"])) bright=\(fmt(out.params["brightness"])) dens=\(fmt(out.params["density"])) spatial=\(spatial) proto=\(out.protocolVersion)"
    }

    private static func formatFeatures(_ f: Features) -> String {
        let pitchPart: String
        if let hz = f.pitchHz, f.pitchConf > 0.2 {
            pitchPart = String(format: " pitch=%.1fHz(%.2f)", hz, f.pitchConf)
        } else {
            pitchPart = " pitch=na"
        }
        let keyPart = " key=\(f.keyEstimate ?? "unknown")(\(String(format: "%.2f", f.keyConf)))"
        return String(
            format: "Features loud=%.1f onset=%.2f cent=%.0f bands=[%.2f %.2f %.2f] noise=%.2f%@",
            f.loudnessLufs, f.onsetRateHz, f.specCentroidHz,
            f.bandLow, f.bandMid, f.bandHigh, f.noisiness,
            pitchPart + keyPart
        )
    }

    private static func formatDiag(mode: Int, interventions: [String]) -> String {
        let modePrefix = "mode\(mode)_"
        let relevant = interventions.filter { $0.hasPrefix(modePrefix) || $0.hasPrefix("mode56_") || $0.hasPrefix("render_mode:") }
        guard !relevant.isEmpty else { return "" }
        return "AudioDiag " + relevant.suffix(8).joined(separator: " | ")
    }
}

struct ChannelMetersView: View {
    let analyzer: AudioInputAnalyzer
    let channelCount: Int

    @State private var levels: [Float] = []
    @State private var gains: [Double] = []

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(0..<min(channelCount, 4), id: \.self) { idx in
                let meter = levels[safe: idx] ?? 0
                let gain = gains[safe: idx] ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    Text(idx == 0 ? "Input 1 • Primary" : "Input \(idx + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(meter > 0.015 ? Color(red: 0.16, green: 0.70, blue: 0.34) : Color.black.opacity(0.14))
                            .frame(width: 10, height: 10)
                            .overlay {
                                Circle().stroke(Color.black.opacity(0.18), lineWidth: 1)
                            }
                        Text(String(format: "%.3f", meter))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                        Text(String(format: "%+.1f dB", gain))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                    }
                    .foregroundStyle(Color.black.opacity(0.70))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                }
            }
        }
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
            refreshMeters()
        }
        .onAppear { refreshMeters() }
    }

    private func refreshMeters() {
        levels = Array(analyzer.inputChannelLevels.prefix(4))
        gains = Array(analyzer.inputRouteProfile.channelGainDb.prefix(4))
    }
}

private enum ShellVisibilityPanel: String, Hashable {
    case left
    case right
    case timeline
}

private enum JoltHoldSource: Hashable {
    case mouse
    case keyboard
}

private enum TimelineMetricToggle: String, Hashable {
    case latency
    case tick
    case timeout
    case interventions
    case alignment
}

struct ShellLayoutViewModel {
    var showLeftRail: Bool = true
    var showRightRail: Bool = true
    var showBottomTimeline: Bool = true
    var showCommandPalette: Bool = false
    var showShortcutLegend: Bool = false
}

struct TransportPanelViewModel {
    var isReady: Bool = false
    var isRunning: Bool = false
    var isReplayRunning: Bool = false
    var bundlePath: String = ""
    var sessionId: String = ""
    var endpointHost: String = "127.0.0.1"
    var endpointPort: UInt16 = 9910
    var lastError: String?
}

struct ModelSlotsPanelViewModel {
    var slots: [ModelSlotProfile] = []
    var activeSlotId: UUID?
    var armedSlotId: UUID?
    var armedAt: Date?
    var lastSwitchAt: Date?
}

struct TelemetryPanelViewModel {
    var samples: [TelemetrySample] = []
    var maxSamples: Int = 360
    var showLatency: Bool = true
    var showTick: Bool = true
    var showTimeouts: Bool = true
    var showInterventions: Bool = true
    var showAlignment: Bool = true
}

struct ReplayPanelViewModel {
    var statusMessage: String?
    var isRunning: Bool = false
    var lastSessionId: String?
}

struct RubricPanelViewModel {
    var scores = RubricScores()
    var notes: String = ""
    var lastSavedAt: Date?
}

@MainActor
final class ControlRoomState: ObservableObject {
    @Published var shell = ShellLayoutViewModel()
    @Published var transport = TransportPanelViewModel()
    @Published var modelSlots = ModelSlotsPanelViewModel(slots: ModelSlotPersistence.load())
    @Published var telemetry = TelemetryPanelViewModel()
    @Published var replay = ReplayPanelViewModel()
    @Published var rubric = RubricPanelViewModel()
    @Published var events: [ControlRoomEvent] = []

    private let rubricWriter = RubricEntryWriter()
    private var cancellables: Set<AnyCancellable> = []
    private var telemetryCancellable: AnyCancellable?
    private weak var client: TubMLClient?
    private weak var audio: AudioEngineController?
    private weak var analyzer: AudioInputAnalyzer?

    private var replayTargetTimeS: Double = 0
    private var isBound: Bool = false

    func bind(client: TubMLClient, audio: AudioEngineController, analyzer: AudioInputAnalyzer) {
        guard !isBound else { return }
        isBound = true
        self.client = client
        self.audio = audio
        self.analyzer = analyzer

        client.$isReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTransport() }
            .store(in: &cancellables)

        client.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTransport() }
            .store(in: &cancellables)

        client.$bundlePath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTransport() }
            .store(in: &cancellables)

        client.$activeSessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sid in
                guard let self else { return }
                self.transport.sessionId = sid ?? ""
                if let sid {
                    self.replay.lastSessionId = sid
                }
            }
            .store(in: &cancellables)

        client.$endpointHost
            .receive(on: DispatchQueue.main)
            .sink { [weak self] host in
                self?.transport.endpointHost = host
            }
            .store(in: &cancellables)

        client.$endpointPort
            .receive(on: DispatchQueue.main)
            .sink { [weak self] port in
                self?.transport.endpointPort = port
            }
            .store(in: &cancellables)

        client.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                self?.transport.lastError = err
            }
            .store(in: &cancellables)

        telemetryCancellable = Timer.publish(every: 0.20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.sampleTelemetry()
            }

        refreshTransport()
        if let first = modelSlots.slots.first {
            modelSlots.activeSlotId = first.id
        }
        appendEvent("Control room initialized.", severity: .info)
    }

    func refreshTransport() {
        guard let client else { return }
        transport.isReady = client.isReady
        transport.isRunning = client.isRunning
        transport.bundlePath = client.bundlePath ?? ""
        transport.sessionId = client.activeSessionId ?? ""
        transport.endpointHost = client.endpointHost
        transport.endpointPort = client.endpointPort
        transport.lastError = client.lastError
    }

    func setReplayRunning(_ running: Bool) {
        replay.isRunning = running
        transport.isReplayRunning = running
    }

    func setReplayStatus(_ status: String?) {
        replay.statusMessage = status
    }

    func appendEvent(_ message: String, severity: ControlRoomSeverity) {
        events.insert(ControlRoomEvent(timestamp: Date(), message: message, severity: severity), at: 0)
        if events.count > 80 {
            events.removeLast(events.count - 80)
        }
    }

    func armOrSwitchSlot(_ slot: ModelSlotProfile) {
        let now = Date()
        if modelSlots.armedSlotId == slot.id,
           let armedAt = modelSlots.armedAt,
           now.timeIntervalSince(armedAt) <= 8 {
            applySlot(slot)
            modelSlots.armedSlotId = nil
            modelSlots.armedAt = nil
            return
        }

        modelSlots.armedSlotId = slot.id
        modelSlots.armedAt = now
        appendEvent("Armed model slot \"\(slot.name)\". Confirm to switch.", severity: .warning)
    }

    private func applySlot(_ slot: ModelSlotProfile) {
        guard let client else { return }
        client.reconfigureEndpoint(host: slot.host, port: slot.resolvedPort)
        modelSlots.activeSlotId = slot.id
        modelSlots.lastSwitchAt = Date()
        appendEvent("Model endpoint switched to \(slot.name) (\(slot.host):\(slot.resolvedPort)).", severity: .info)
    }

    func updateSlot(_ slotId: UUID, mutate: (inout ModelSlotProfile) -> Void) {
        guard let idx = modelSlots.slots.firstIndex(where: { $0.id == slotId }) else { return }
        mutate(&modelSlots.slots[idx])
        ModelSlotPersistence.save(slots: modelSlots.slots)
    }

    func addModelSlot() {
        modelSlots.slots.append(
            ModelSlotProfile(id: UUID(), name: "New Slot", host: "127.0.0.1", port: 9910, notes: "")
        )
        ModelSlotPersistence.save(slots: modelSlots.slots)
    }

    func removeSlot(_ slotId: UUID) {
        guard modelSlots.slots.count > 1 else { return }
        modelSlots.slots.removeAll { $0.id == slotId }
        if modelSlots.activeSlotId == slotId {
            modelSlots.activeSlotId = modelSlots.slots.first?.id
        }
        ModelSlotPersistence.save(slots: modelSlots.slots)
    }

    func saveRubric(mode: Int, runProfile: HarnessRunProfile) {
        guard let client else { return }
        guard let targetSessionId = client.feedbackTargetSessionId else {
            appendEvent("Rubric not saved: no feedback target session.", severity: .warning)
            return
        }

        let entry = RubricEntry(
            tsMs: Int(Date().timeIntervalSince1970 * 1000),
            sessionId: targetSessionId,
            bundleId: client.feedbackTargetBundleId,
            mode: mode,
            runProfile: runProfile.rawValue,
            scores: rubric.scores,
            notes: rubric.notes,
            endpointHost: client.endpointHost,
            endpointPort: client.endpointPort
        )
        rubricWriter.append(entry)
        rubric.lastSavedAt = Date()
        appendEvent(String(format: "Rubric saved (avg %.2f).", rubric.scores.average), severity: .info)
    }

    func noteReplayAlignment(targetTimeS: Double, audioTimeS: Double) {
        replayTargetTimeS = targetTimeS
        let delta = audioTimeS - targetTimeS
        if abs(delta) > 0.120 {
            appendEvent(String(format: "Replay alignment drift %.3fs", delta), severity: .warning)
        }
    }

    func resetReplayAlignment() {
        replayTargetTimeS = 0
    }

    private func sampleTelemetry() {
        guard let client else { return }

        let interventions = audio?.snapshotSafetyInterventions() ?? []
        let replayAudioTime = audio?.replayCurrentTimeSeconds() ?? 0
        let alignmentDelta = replayAudioTime - replayTargetTimeS

        let sample = TelemetrySample(
            ts: Date(),
            latencyMs: Double(client.lastLatencyMs ?? 0),
            tickMs: client.lastTickIntervalMs ?? 0,
            timeoutCount: Double(client.timeoutCount),
            sentCount: Double(client.sentCount),
            recvCount: Double(client.recvCount),
            interventions: interventions,
            replayAudioTimeS: replayAudioTime,
            replayTargetTimeS: replayTargetTimeS,
            replayAlignmentDeltaS: alignmentDelta
        )

        telemetry.samples.append(sample)
        if telemetry.samples.count > telemetry.maxSamples {
            telemetry.samples.removeFirst(telemetry.samples.count - telemetry.maxSamples)
        }

        if interventions.contains(where: { $0 == "audio_record_drop" }) {
            appendEvent("Audio recorder queue overflow detected (dropped buffers).", severity: .warning)
        }
    }
}

private final class ReplayCancellationToken {
    private let lock = NSLock()
    private var cancelled: Bool = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct CommandPaletteAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let keywords: [String]
}

private struct TelemetryTimelineView: View {
    let telemetry: TelemetryPanelViewModel

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .local)
            Canvas { context, size in
                guard telemetry.samples.count >= 2 else { return }

                let width = size.width
                let height = size.height
                let valuesLatency = telemetry.samples.map { $0.latencyMs }
                let valuesTick = telemetry.samples.map { $0.tickMs }
                let valuesTimeout = telemetry.samples.map { $0.timeoutCount }
                let valuesAlignment = telemetry.samples.map { abs($0.replayAlignmentDeltaS) * 1000.0 }

                if telemetry.showLatency {
                    drawLine(values: valuesLatency, color: Color(red: 0.26, green: 0.78, blue: 0.98), width: width, height: height * 0.60, context: &context)
                }
                if telemetry.showTick {
                    drawLine(values: valuesTick, color: Color(red: 0.33, green: 0.91, blue: 0.61), width: width, height: height * 0.60, context: &context)
                }
                if telemetry.showTimeouts {
                    drawLine(values: valuesTimeout, color: Color(red: 0.99, green: 0.61, blue: 0.22), width: width, height: height * 0.45, context: &context)
                }
                if telemetry.showAlignment {
                    drawLine(values: valuesAlignment, color: Color(red: 0.94, green: 0.39, blue: 0.37), width: width, height: height * 0.35, context: &context)
                }

                if telemetry.showInterventions {
                    let interventionIndices = telemetry.samples.enumerated().filter { !$0.element.interventions.isEmpty }.map(\.offset)
                    for idx in interventionIndices {
                        let x = CGFloat(idx) / CGFloat(max(1, telemetry.samples.count - 1)) * width
                        let marker = Path(CGRect(x: x, y: height * 0.72, width: 1.5, height: height * 0.25))
                        context.stroke(marker, with: .color(Color(red: 0.98, green: 0.78, blue: 0.34).opacity(0.7)), lineWidth: 1.0)
                    }
                }

                var border = Path()
                border.addRoundedRect(in: CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1), cornerSize: CGSize(width: 6, height: 6))
                context.stroke(border, with: .color(Color.black.opacity(0.16)), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                Text("Latency / Tick / Timeout / Alignment")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.76))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.90), in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1)
                    }
                    .padding(.top, 6)
                    .padding(.leading, 6)
            }
            .frame(width: frame.width, height: frame.height)
        }
    }

    private func drawLine(values: [Double], color: Color, width: CGFloat, height: CGFloat, context: inout GraphicsContext) {
        guard values.count >= 2 else { return }
        let maxValue = max(values.max() ?? 1.0, 1.0)
        var path = Path()
        for (idx, value) in values.enumerated() {
            let x = CGFloat(idx) / CGFloat(max(1, values.count - 1)) * width
            let norm = CGFloat(value / maxValue)
            let y = height - (norm * height)
            if idx == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.8)
    }
}

struct MLMonitorKnob: Identifiable, Equatable {
    let id: String
    let canonicalKey: String
    let title: String
    let displayValue: String
    let normalizedValue: Double
    let rawNormalizedValue: Double?
    let rawDisplayValue: String?
    let changedByHarness: Bool
    let recentlyUpdated: Bool
    let debugCaption: String?
}

struct MLMonitorPick: Identifiable, Equatable {
    let id: String
    let pickKey: String
    let title: String
    let resolvedValue: String
    let rawValue: String?
    let changedByHarness: Bool
    let required: Bool
    let recentlyUpdated: Bool
}

struct MLMonitorSnapshot: Equatable {
    let mode: Int
    let modeTitle: String
    let waitingReason: String?
    let updatedAt: Date?
    let latencyMs: Int?
    let mismatchCount: Int
    let contractViolations: [String]
    let pickNotes: [String]
    let resolvedKnobs: [MLMonitorKnob]
    let commonKnobs: [MLMonitorKnob]
    let picks: [MLMonitorPick]

    var isWaiting: Bool { waitingReason != nil }

    var hasAdjustments: Bool {
        mismatchCount > 0 || !contractViolations.isEmpty || !pickNotes.isEmpty
    }

    var summaryNote: String? {
        if !contractViolations.isEmpty {
            return "Harness corrected one or more controls to fit the active mode."
        }
        if !pickNotes.isEmpty {
            return "Harness resolved one or more categorical picks for the active mode."
        }
        if mismatchCount > 0 {
            return "Harness normalized \(mismatchCount) live control\(mismatchCount == 1 ? "" : "s")."
        }
        return nil
    }

    static func waiting(for mode: Int, reason: String? = nil) -> MLMonitorSnapshot {
        MLMonitorSnapshot(
            mode: mode,
            modeTitle: "Mode \(mode)",
            waitingReason: reason ?? "Awaiting the next packet for Mode \(mode).",
            updatedAt: nil,
            latencyMs: nil,
            mismatchCount: 0,
            contractViolations: [],
            pickNotes: [],
            resolvedKnobs: [],
            commonKnobs: [],
            picks: []
        )
    }
}

enum MLMonitorMapper {
    private static let orderedParamsByMode: [Int: [String]] = [
        0: ["dry_level", "reverb_mix", "reverb_decay_s", "pre_delay_ms", "tone_db"],
        1: ["fracture", "mutation", "pitch_lock", "hold_len_s", "tail_fade_ms", "scene_rate_hz", "motion_speed", "spread"],
        2: ["grain_size_ms", "grain_density", "scan_rate", "freeze_prob", "freeze_len_s", "pitch_spread_cents"],
        3: ["drive", "bit_depth_bits", "downsample_amt", "res_shift", "tone_db"],
        4: ["density", "gesture_rate_hz", "sample_mix", "dry_level", "stability"],
        5: ["note_rate_notes_per_s", "voice_cap", "pitch_follow", "velocity_bias", "level", "stability"],
        6: ["note_rate_notes_per_s", "voice_cap", "pitch_follow", "velocity_bias", "level", "stability", "dry_level"],
        7: ["swap_rate_hz", "crossfade_ms", "bucket_sharpness", "mapping_entropy", "mix"],
        8: ["reverb_rand_amt", "reverb_decay_base_s", "reverb_decay_range_s", "reverb_color", "twitchiness", "motion_speed", "spread"],
        9: ["particle_density", "particle_voice_cap", "particle_decay_s", "particle_brightness", "motion_speed", "spread"],
        10: ["scene_len_s", "chaos", "blend", "stability"],
    ]

    private static let paramTitles: [String: String] = [
        "dry_level": "Dry",
        "reverb_mix": "Reverb Mix",
        "reverb_decay_s": "Decay",
        "pre_delay_ms": "Pre-Delay",
        "tone_db": "Tone",
        "fracture": "Fracture",
        "mutation": "Mutation",
        "pitch_lock": "Pitch Lock",
        "hold_len_s": "Hold",
        "tail_fade_ms": "Fade",
        "scene_rate_hz": "Scene Rate",
        "motion_speed": "Motion",
        "spread": "Spread",
        "grain_size_ms": "Grain Size",
        "grain_density": "Density",
        "scan_rate": "Scan",
        "freeze_prob": "Freeze",
        "freeze_len_s": "Freeze Len",
        "pitch_spread_cents": "Pitch Spread",
        "drive": "Drive",
        "bit_depth_bits": "Bit Depth",
        "downsample_amt": "Downsample",
        "res_shift": "Res Shift",
        "density": "Density",
        "gesture_rate_hz": "Gesture Rate",
        "sample_mix": "Sample Mix",
        "stability": "Stability",
        "note_rate_notes_per_s": "Note Rate",
        "voice_cap": "Voices",
        "pitch_follow": "Pitch Follow",
        "velocity_bias": "Velocity",
        "level": "Level",
        "swap_rate_hz": "Swap Rate",
        "crossfade_ms": "Crossfade",
        "bucket_sharpness": "Sharpness",
        "mapping_entropy": "Entropy",
        "mix": "Mix",
        "reverb_rand_amt": "Reverb Rand",
        "reverb_decay_base_s": "Base Decay",
        "reverb_decay_range_s": "Decay Range",
        "reverb_color": "Color",
        "twitchiness": "Twitch",
        "particle_density": "Particles",
        "particle_voice_cap": "Particle Voices",
        "particle_decay_s": "Particle Decay",
        "particle_brightness": "Brightness",
        "scene_len_s": "Scene Len",
        "chaos": "Chaos",
        "blend": "Blend",
    ]

    private static let pickTitles: [String: String] = [
        "preset_id": "Preset",
        "bank_id": "Bank",
        "sample_id": "Sample",
        "midi_inst_id": "Instrument",
        "chord_set_id": "Chord Set",
        "motif_id": "Motif",
        "articulation_id": "Articulation",
        "spatial_pattern_id": "Spatial Pattern",
        "scene_id": "Scene",
        "grid_div": "Grid",
        "repeat_style_id": "Repeat Style",
        "category_id": "Category",
        "gesture_type_id": "Gesture Type",
        "mapping_id": "Mapping",
        "variance_amt": "Variance",
        "variant_seed": "Variant Seed",
        "mapping_family": "Mapping Family",
    ]

    private static let pickOrder: [String] = [
        "preset_id", "bank_id", "sample_id", "midi_inst_id", "chord_set_id", "motif_id",
        "articulation_id", "spatial_pattern_id", "scene_id", "grid_div", "repeat_style_id",
        "category_id", "gesture_type_id", "mapping_id", "variance_amt", "variant_seed", "mapping_family"
    ]

    static func buildSnapshot(
        currentMode: Int,
        context: ModelMonitorContext?,
        modeEngine: ModeEngine,
        previous: MLMonitorSnapshot?
    ) -> MLMonitorSnapshot {
        guard let context else {
            return MLMonitorSnapshot.waiting(for: currentMode)
        }

        guard context.resolvedPacket.mode == currentMode else {
            return MLMonitorSnapshot.waiting(
                for: currentMode,
                reason: "Last packet was Mode \(context.resolvedPacket.mode). Waiting for Mode \(currentMode)."
            )
        }

        let resolvedPacket = context.resolvedPacket
        let rawPacket = context.rawPacket
        let rawProjected = rawPacket.map { ModeContract.clamp(params: $0.params, mode: currentMode).clamped } ?? [:]
        let rawSourceKeys = rawPacket.map { rawCanonicalSourceKeys(params: $0.params, mode: currentMode) } ?? [:]
        let resolvedKeys = orderedParams(for: currentMode).filter { resolvedPacket.params[$0] != nil }

        var resolvedKnobs = resolvedKeys.map { key in
            makeResolvedKnob(
                key: key,
                resolvedValue: resolvedPacket.params[key] ?? 0,
                rawValue: rawProjected[key],
                rawSourceKey: rawSourceKeys[key],
                currentMode: currentMode,
                rawPacketAvailable: rawPacket != nil
            )
        }

        let resolvedControl = modeEngine.makeControl(out: resolvedPacket, sentButtons: Buttons())
        var commonKnobs = commonOutputKnobs(control: resolvedControl, mode: currentMode)
        var picks = visiblePickKeys(mode: currentMode, resolved: resolvedPacket.picks, raw: rawPacket?.picks).map { key in
            makePick(
                key: key,
                resolved: resolvedPacket.picks,
                raw: rawPacket?.picks,
                required: ModeContract.requiredPicks(for: currentMode).contains(key)
            )
        }

        let previousKnobs = Dictionary(uniqueKeysWithValues: previous?.resolvedKnobs.map { ($0.id, $0) } ?? [])
        resolvedKnobs = resolvedKnobs.map { knob in
            var updated = knob
            if let prior = previousKnobs[knob.id] {
                updated = MLMonitorKnob(
                    id: knob.id,
                    canonicalKey: knob.canonicalKey,
                    title: knob.title,
                    displayValue: knob.displayValue,
                    normalizedValue: knob.normalizedValue,
                    rawNormalizedValue: knob.rawNormalizedValue,
                    rawDisplayValue: knob.rawDisplayValue,
                    changedByHarness: knob.changedByHarness,
                    recentlyUpdated: prior.displayValue != knob.displayValue || prior.rawDisplayValue != knob.rawDisplayValue,
                    debugCaption: knob.debugCaption
                )
            }
            return updated
        }

        let previousCommonKnobs = Dictionary(uniqueKeysWithValues: previous?.commonKnobs.map { ($0.id, $0) } ?? [])
        commonKnobs = commonKnobs.map { knob in
            var updated = knob
            if let prior = previousCommonKnobs[knob.id] {
                updated = MLMonitorKnob(
                    id: knob.id,
                    canonicalKey: knob.canonicalKey,
                    title: knob.title,
                    displayValue: knob.displayValue,
                    normalizedValue: knob.normalizedValue,
                    rawNormalizedValue: knob.rawNormalizedValue,
                    rawDisplayValue: knob.rawDisplayValue,
                    changedByHarness: knob.changedByHarness,
                    recentlyUpdated: prior.displayValue != knob.displayValue,
                    debugCaption: knob.debugCaption
                )
            }
            return updated
        }

        let previousPicks = Dictionary(uniqueKeysWithValues: previous?.picks.map { ($0.id, $0) } ?? [])
        picks = picks.map { pick in
            var updated = pick
            if let prior = previousPicks[pick.id] {
                updated = MLMonitorPick(
                    id: pick.id,
                    pickKey: pick.pickKey,
                    title: pick.title,
                    resolvedValue: pick.resolvedValue,
                    rawValue: pick.rawValue,
                    changedByHarness: pick.changedByHarness,
                    required: pick.required,
                    recentlyUpdated: prior.resolvedValue != pick.resolvedValue || prior.rawValue != pick.rawValue
                )
            }
            return updated
        }

        let mismatchCount = resolvedKnobs.filter(\.changedByHarness).count + picks.filter(\.changedByHarness).count

        return MLMonitorSnapshot(
            mode: currentMode,
            modeTitle: "Mode \(currentMode)",
            waitingReason: nil,
            updatedAt: context.receivedAt,
            latencyMs: context.latencyMs,
            mismatchCount: mismatchCount,
            contractViolations: context.contractViolations,
            pickNotes: context.pickNotes,
            resolvedKnobs: resolvedKnobs,
            commonKnobs: commonKnobs,
            picks: picks
        )
    }

    static func orderedParams(for mode: Int) -> [String] {
        orderedParamsByMode[mode] ?? Array(ModeContract.canonicalAllowedParams(for: mode)).sorted()
    }

    private static func visiblePickKeys(mode: Int, resolved: Picks, raw: Picks?) -> [String] {
        let required = ModeContract.requiredPicks(for: mode)
        return pickOrder.filter { key in
            required.contains(key) || pickValue(for: key, picks: resolved) != nil || (raw.flatMap { pickValue(for: key, picks: $0) } != nil)
        }
    }

    private static func rawCanonicalSourceKeys(params: [String: Double], mode: Int) -> [String: String] {
        let allowed = ModeContract.canonicalAllowedParams(for: mode)
        var sources: [String: String] = [:]
        for key in params.keys.sorted() {
            let canonical = ModeContract.canonicalParamKey(mode: mode, key: key)
            guard allowed.contains(canonical), sources[canonical] == nil else { continue }
            sources[canonical] = key
        }
        return sources
    }

    private static func makeResolvedKnob(
        key: String,
        resolvedValue: Double,
        rawValue: Double?,
        rawSourceKey: String?,
        currentMode: Int,
        rawPacketAvailable: Bool
    ) -> MLMonitorKnob {
        let bounds = ModeContract.bounds(for: currentMode, param: key) ?? (0.0, 1.0)
        let normalized = normalize(resolvedValue, bounds: bounds)
        let rawNormalized = rawValue.map { normalize($0, bounds: bounds) }
        let changedByHarness: Bool = {
            guard rawPacketAvailable else { return false }
            guard let rawSourceKey else { return true }
            if rawSourceKey != key { return true }
            guard let rawValue else { return false }
            return abs(rawValue - resolvedValue) > diffTolerance(bounds: bounds)
        }()
        let debugCaption: String? = {
            guard rawPacketAvailable, changedByHarness else { return nil }
            guard let rawSourceKey else { return "Defaulted by harness" }
            if rawSourceKey != key {
                return "\(humanizeIdentifier(rawSourceKey)) -> \(humanizeIdentifier(key))"
            }
            return humanizeIdentifier(key)
        }()

        return MLMonitorKnob(
            id: key,
            canonicalKey: key,
            title: paramTitles[key] ?? humanizeIdentifier(key),
            displayValue: formatValue(key: key, value: resolvedValue, bounds: bounds),
            normalizedValue: normalized,
            rawNormalizedValue: rawSourceKey == nil ? nil : rawNormalized,
            rawDisplayValue: rawSourceKey == nil ? nil : rawValue.map { formatValue(key: key, value: $0, bounds: bounds) },
            changedByHarness: changedByHarness,
            recentlyUpdated: false,
            debugCaption: debugCaption
        )
    }

    private static func commonOutputKnobs(control: AudioControl, mode: Int) -> [MLMonitorKnob] {
        [
            MLMonitorKnob(
                id: "common_level",
                canonicalKey: "level",
                title: "Level",
                displayValue: formatPercent(control.level),
                normalizedValue: clampToUnit(control.level),
                rawNormalizedValue: nil,
                rawDisplayValue: nil,
                changedByHarness: false,
                recentlyUpdated: false,
                debugCaption: nil
            ),
            MLMonitorKnob(
                id: "common_dry",
                canonicalKey: "dry_level",
                title: "Dry",
                displayValue: formatPercent(control.dryLevel),
                normalizedValue: clampToUnit(control.dryLevel),
                rawNormalizedValue: nil,
                rawDisplayValue: nil,
                changedByHarness: false,
                recentlyUpdated: false,
                debugCaption: nil
            ),
            MLMonitorKnob(
                id: "common_wet",
                canonicalKey: "wet_level",
                title: "Wet",
                displayValue: formatPercent(control.wetLevel),
                normalizedValue: clampToUnit(control.wetLevel),
                rawNormalizedValue: nil,
                rawDisplayValue: nil,
                changedByHarness: false,
                recentlyUpdated: false,
                debugCaption: nil
            ),
            MLMonitorKnob(
                id: "common_spread",
                canonicalKey: "spread",
                title: "Spread",
                displayValue: formatPercent(control.spread),
                normalizedValue: clampToUnit(control.spread),
                rawNormalizedValue: nil,
                rawDisplayValue: nil,
                changedByHarness: false,
                recentlyUpdated: false,
                debugCaption: nil
            ),
            MLMonitorKnob(
                id: "common_motion",
                canonicalKey: "motion_speed",
                title: "Motion",
                displayValue: formatPercent(control.motionSpeed),
                normalizedValue: clampToUnit(control.motionSpeed),
                rawNormalizedValue: nil,
                rawDisplayValue: nil,
                changedByHarness: false,
                recentlyUpdated: false,
                debugCaption: nil
            ),
            MLMonitorKnob(
                id: "common_reverb",
                canonicalKey: "reverb_mix",
                title: "Reverb",
                displayValue: formatPercent(min(max(control.reverb.wet / 0.5, 0.0), 1.0)),
                normalizedValue: min(max(control.reverb.wet / 0.5, 0.0), 1.0),
                rawNormalizedValue: nil,
                rawDisplayValue: nil,
                changedByHarness: false,
                recentlyUpdated: false,
                debugCaption: nil
            ),
        ].filter { knob in
            mode != 0 || knob.canonicalKey != "wet_level"
        }
    }

    private static func makePick(key: String, resolved: Picks, raw: Picks?, required: Bool) -> MLMonitorPick {
        let resolvedRaw = pickValue(for: key, picks: resolved)
        let rawRaw = raw.flatMap { pickValue(for: key, picks: $0) }
        let changed = raw != nil && normalizePick(rawRaw) != normalizePick(resolvedRaw)

        return MLMonitorPick(
            id: key,
            pickKey: key,
            title: pickTitles[key] ?? humanizeIdentifier(key),
            resolvedValue: humanizeIdentifier(resolvedRaw ?? "Not set"),
            rawValue: changed ? rawRaw : nil,
            changedByHarness: changed,
            required: required,
            recentlyUpdated: false
        )
    }

    private static func normalize(_ value: Double, bounds: ModeContract.Bounds) -> Double {
        let span = bounds.1 - bounds.0
        guard span > 0.000_001 else { return 0.0 }
        return min(max((value - bounds.0) / span, 0.0), 1.0)
    }

    private static func diffTolerance(bounds: ModeContract.Bounds) -> Double {
        max(0.005, (bounds.1 - bounds.0) * 0.01)
    }

    private static func formatValue(key: String, value: Double, bounds: ModeContract.Bounds) -> String {
        switch key {
        case _ where key.hasSuffix("_hz"):
            return String(format: "%.1f Hz", value)
        case _ where key.hasSuffix("_ms"):
            return String(format: "%.0f ms", value)
        case _ where key.hasSuffix("_s"):
            return String(format: "%.1f s", value)
        case _ where key.hasSuffix("_db"):
            return String(format: "%+.1f dB", value)
        case _ where key.hasSuffix("_cents"):
            return String(format: "%.0f ct", value)
        case _ where key.hasSuffix("_bits"):
            return String(format: "%.0f bit", value)
        case "voice_cap", "particle_voice_cap", "variant_seed":
            return String(format: "%.0f", value)
        default:
            if bounds.0 >= 0.0 && bounds.1 <= 1.0 {
                return formatPercent(value)
            }
            return String(format: "%.2f", value)
        }
    }

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0.0), 1.0) * 100.0)
    }

    private static func normalizePick(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private static func clampToUnit(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    static func humanizeIdentifier(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                if part.count <= 3 {
                    return part.uppercased()
                }
                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    static func pickValue(for key: String, picks: Picks) -> String? {
        switch key {
        case "preset_id": return picks.presetId
        case "bank_id": return picks.bankId
        case "sample_id": return picks.sampleId
        case "midi_inst_id": return picks.midiInstId
        case "chord_set_id": return picks.chordSetId
        case "motif_id": return picks.motifId
        case "articulation_id": return picks.articulationId
        case "spatial_pattern_id": return picks.spatialPatternId
        case "scene_id": return picks.sceneId
        case "grid_div": return picks.gridDiv
        case "repeat_style_id": return picks.repeatStyleId
        case "category_id": return picks.categoryId
        case "gesture_type_id": return picks.gestureTypeId
        case "mapping_id": return picks.mappingId
        case "variance_amt":
            guard let value = picks.varianceAmt else { return nil }
            return String(format: "%.2f", value)
        case "variant_seed":
            guard let value = picks.variantSeed else { return nil }
            return String(value)
        case "mapping_family": return picks.mappingFamily
        default: return nil
        }
    }
}

@MainActor
final class MLMonitorStore: ObservableObject {
    @Published private(set) var snapshot: MLMonitorSnapshot = .waiting(for: 0)

    private var currentMode: Int = 0
    private var context: ModelMonitorContext?
    private let modeEngine = ModeEngine()
    private var contextCancellable: AnyCancellable?
    private var boundClientID: ObjectIdentifier?

    func bind(client: TubMLClient) {
        let objectID = ObjectIdentifier(client)
        guard objectID != boundClientID else { return }
        boundClientID = objectID
        context = client.lastMonitorContext
        contextCancellable = client.$lastMonitorContext
            .removeDuplicates()
            .sink { [weak self] context in
                self?.context = context
                self?.rebuildSnapshot()
            }
        rebuildSnapshot()
    }

    func setMode(_ mode: Int) {
        currentMode = max(0, min(10, mode))
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        let next = MLMonitorMapper.buildSnapshot(
            currentMode: currentMode,
            context: context,
            modeEngine: modeEngine,
            previous: snapshot
        )
        if next != snapshot {
            snapshot = next
        } else if next.updatedAt != snapshot.updatedAt || next.latencyMs != snapshot.latencyMs {
            snapshot = next
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        switch self?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case .some(let value) where !value.isEmpty:
            return value
        default:
            return nil
        }
    }
}

private struct MLMonitorSummaryView: View {
    let snapshot: MLMonitorSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let ageSeconds = snapshot.updatedAt.map { max(0, context.date.timeIntervalSince($0)) }
            let live = ageSeconds.map { $0 < 1.2 } ?? false

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(live ? ShellChromePalette.startGreen : Color.black.opacity(0.18))
                        .frame(width: 10, height: 10)
                    Text(live ? "Packet Live" : "Waiting")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(ShellChromePalette.ink)
                    Spacer()
                    if snapshot.hasAdjustments {
                        Text(snapshot.mismatchCount > 0 ? "Adjusted \(snapshot.mismatchCount)" : "Adjusted")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.45, green: 0.28, blue: 0.03))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(ShellChromePalette.warmAmberSoft, in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    summaryMetric(title: "Mode", value: snapshot.modeTitle)
                    summaryMetric(title: "Latency", value: snapshot.latencyMs.map { "\($0) ms" } ?? "—")
                    summaryMetric(title: "Age", value: ageLabel(ageSeconds))
                }

                if let note = snapshot.summaryNote {
                    Text(note)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                }
                if let waitingReason = snapshot.waitingReason {
                    Text(waitingReason)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                }
            }
            .padding(10)
            .background(ShellChromePalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(ShellChromePalette.border, lineWidth: 1)
            }
        }
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(ShellChromePalette.inkSoft)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(ShellChromePalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ageLabel(_ ageSeconds: Double?) -> String {
        guard let ageSeconds else { return "No packet" }
        if ageSeconds < 0.5 { return "Just now" }
        if ageSeconds < 10 { return String(format: "%.1f s", ageSeconds) }
        return String(format: "%.0f s", ageSeconds)
    }
}

private struct MLMonitorKnobView: View {
    let knob: MLMonitorKnob
    let compact: Bool

    private var diameter: CGFloat { compact ? 58 : 82 }
    private var cardFill: Color {
        if knob.changedByHarness {
            return ShellChromePalette.warmAmberSoft
        }
        if knob.recentlyUpdated {
            return ShellChromePalette.accentBlueSoft
        }
        return Color.white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(knob.title)
                        .font(.system(size: compact ? 11 : 12, weight: .bold, design: .rounded))
                        .foregroundStyle(ShellChromePalette.ink)
                        .lineLimit(2)
                    if let debugCaption = knob.debugCaption {
                        Text(debugCaption)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if knob.changedByHarness {
                    Circle()
                        .fill(ShellChromePalette.warmAmber)
                        .frame(width: 8, height: 8)
                } else if knob.recentlyUpdated {
                    Circle()
                        .fill(ShellChromePalette.accentBlue)
                        .frame(width: 8, height: 8)
                }
            }

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.black.opacity(0.08), lineWidth: compact ? 7 : 8)
                    if let rawNormalizedValue = knob.rawNormalizedValue {
                        Circle()
                            .trim(from: rawTickStart(rawNormalizedValue), to: rawTickEnd(rawNormalizedValue))
                            .stroke(
                                ShellChromePalette.warmAmber,
                                style: StrokeStyle(lineWidth: compact ? 7 : 8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    Circle()
                        .trim(from: 0, to: max(0.02, knob.normalizedValue))
                        .stroke(
                            ShellChromePalette.accentBlue,
                            style: StrokeStyle(lineWidth: compact ? 7 : 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.18), value: knob.normalizedValue)
                    Circle()
                        .fill(Color.white.opacity(0.94))
                        .padding(compact ? 10 : 12)
                    VStack(spacing: 2) {
                        Text(knob.displayValue)
                            .font(.system(size: compact ? 11 : 12, weight: .bold, design: .rounded))
                            .foregroundStyle(ShellChromePalette.ink)
                        if let rawDisplayValue = knob.rawDisplayValue, knob.changedByHarness {
                            Text("ML \(rawDisplayValue)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.45, green: 0.28, blue: 0.03))
                                .lineLimit(1)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                }
                .frame(width: diameter, height: diameter)

                if !compact {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(knob.changedByHarness ? "Resolved" : "Current")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                        Text(knob.displayValue)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(ShellChromePalette.ink)
                        if let rawDisplayValue = knob.rawDisplayValue, knob.changedByHarness {
                            Text("ML suggested \(rawDisplayValue)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.45, green: 0.28, blue: 0.03))
                                .lineLimit(2)
                        } else {
                            Text(" ")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(knob.changedByHarness ? ShellChromePalette.warmAmber.opacity(0.55) : ShellChromePalette.border, lineWidth: 1)
        }
    }

    private func rawTickStart(_ value: Double) -> Double {
        max(0.0, min(value - 0.018, 0.98))
    }

    private func rawTickEnd(_ value: Double) -> Double {
        min(1.0, max(value + 0.018, 0.02))
    }
}

private struct MLMonitorPickCardView: View {
    let pick: MLMonitorPick

    private var fill: Color {
        if pick.changedByHarness {
            return ShellChromePalette.warmAmberSoft
        }
        if pick.recentlyUpdated {
            return ShellChromePalette.accentBlueSoft
        }
        return Color.white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(pick.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(ShellChromePalette.ink)
                if pick.required {
                    Text("Required")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(ShellChromePalette.accentBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ShellChromePalette.accentBlueSoft, in: Capsule())
                }
                Spacer()
            }

            Text(pick.resolvedValue)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(ShellChromePalette.ink)
                .lineLimit(1)
                .truncationMode(.middle)

            if let rawValue = pick.rawValue, pick.changedByHarness {
                Text("ML \(MLMonitorMapper.humanizeIdentifier(rawValue)) -> Harness \(pick.resolvedValue)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.45, green: 0.28, blue: 0.03))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(pick.changedByHarness ? ShellChromePalette.warmAmber.opacity(0.55) : ShellChromePalette.border, lineWidth: 1)
        }
    }
}

// MARK: - Mode Chooser

struct ModeChooserView: View {
    let onChoose: (HarnessRunMode) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.96, blue: 0.99),
                    Color(red: 0.89, green: 0.93, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 6) {
                    Text("THE TUB")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(ShellChromePalette.ink)
                        .tracking(6)
                    Text("CONTROL ROOM")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                        .tracking(2)
                }

                HStack(spacing: 20) {
                    modeCard(
                        mode: .training,
                        icon: "brain",
                        accent: ShellChromePalette.startGreen
                    )
                    modeCard(
                        mode: .performance,
                        icon: "waveform.path",
                        accent: ShellChromePalette.accentBlue
                    )
                }

                Text("Mode is locked for the session. Use the Harness menu to switch.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(ShellChromePalette.inkSoft)
            }
            .padding(40)
        }
        .frame(minWidth: 600, minHeight: 340)
    }

    private func modeCard(mode: HarnessRunMode, icon: String, accent: Color) -> some View {
        let isLast = HarnessRunModeStorage.last == mode
        return Button {
            onChoose(mode)
        } label: {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(accent)
                Text(mode.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(ShellChromePalette.ink)
                Text(mode.subtitle)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(ShellChromePalette.inkSoft)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if isLast {
                    Text("LAST USED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.12), in: Capsule())
                }
            }
            .frame(width: 240, height: 200)
            .background(ShellChromePalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isLast ? accent.opacity(0.4) : ShellChromePalette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content View

struct ContentView: View {
    let runMode: HarnessRunMode
    @EnvironmentObject private var audienceServer: AudienceSessionServer

    @StateObject private var modelServer = ModelServerProcess()
    @StateObject private var client = TubMLClient(host: "127.0.0.1", port: 9910)
    @StateObject private var audio = AudioEngineController()
    @StateObject private var analyzer = AudioInputAnalyzer()
    @StateObject private var controlRoom = ControlRoomState()
    @StateObject private var mlMonitor = MLMonitorStore()
    @StateObject private var videoStage = VideoStageStore()
    @StateObject private var videoOutput = VideoOutputController()
    @StateObject private var softLink = SoftLinkCoordinator()
    private let webcamPool = USGSWebcamPool()
    private let videoClipPool = JoltVideoClipPool()
    @StateObject private var speechTranscriber = SpeechTranscriber()

    private let modeEngine = ModeEngine()

    @State private var mode: Int = 0
    private let runProfile: HarnessRunProfile = .audioAndFeatures
    @State private var recordInputAudio: Bool

    @State private var replayPath: String = ""
    @State private var replaySessionId: String = ""
    @State private var replaySeekSeconds: String = ""
    @State private var replayStatus: String?
    @State private var isReplayRunning: Bool = false
    @State private var replayCancelToken: ReplayCancellationToken?
    @State private var evalDatasetPath: String = "/Users/seb/the-tub-ml/datasets/phase1/bootstrap_golden.jsonl"
    @State private var evalBaselinePath: String = "/Users/seb/the-tub-ml/models/policy_v1.pt"
    @State private var evalCandidatePath: String = "/Users/seb/the-tub-ml/models/policy_v1_mode4.pt"
    @State private var evalModesCSV: String = ""
    @State private var evalStatus: String?
    @State private var evalReportText: String = ""
    @State private var isEvalRunning: Bool = false
    @State private var commandQuery: String = ""
    @State private var showInputRoutingModal: Bool = false
    @State private var showOutputRoutingModal: Bool = false
    @State private var showManualReplayEntry: Bool = false
    @State private var joltHoldSources: Set<JoltHoldSource> = []
    @State private var isTransportTransitioning: Bool = false

    init(runMode: HarnessRunMode = .training, defaultRecordInputAudio: Bool = false) {
        self.runMode = runMode
        _recordInputAudio = State(initialValue: defaultRecordInputAudio)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.96, blue: 0.99),
                    Color(red: 0.89, green: 0.93, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar

                if runMode == .training && controlRoom.shell.showBottomTimeline {
                    VSplitView {
                        workspaceDeck
                            .frame(minHeight: 420, maxHeight: .infinity, alignment: .top)
                        bottomTimeline
                            .frame(minHeight: 170, idealHeight: 220, maxHeight: 260)
                    }
                } else {
                    workspaceDeck
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(12)
            .foregroundStyle(Color.black.opacity(0.88))
            .font(.system(size: 13, weight: .medium, design: .rounded))

            CommandKeyHoldMonitor(key: "j", modifiers: [.command]) { active in
                setJoltHold(.keyboard, active: active && !isReplayRunning)
            }
            .frame(width: 0, height: 0)

            // Direct pairing mode toggle — bypasses tap+hold gesture entirely.
            Button("") {
                print("[SoftLink-CV] ★ Cmd+Shift+P → activatePairing()")
                softLink.activatePairing()
            }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .sheet(isPresented: Binding(
            get: { controlRoom.shell.showCommandPalette },
            set: { controlRoom.shell.showCommandPalette = $0 }
        )) {
            commandPalette
        }
        .sheet(isPresented: Binding(
            get: { controlRoom.shell.showShortcutLegend },
            set: { controlRoom.shell.showShortcutLegend = $0 }
        )) {
            shortcutLegend
        }
        .sheet(isPresented: $showInputRoutingModal) {
            inputRoutingModal
        }
        .sheet(isPresented: $showOutputRoutingModal) {
            outputRoutingModal
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            modelServer.start()
            client.setMode(mode)
            mlMonitor.bind(client: client)
            mlMonitor.setMode(mode)
            videoStage.bind(client: client)
            videoStage.bind(analyzer: analyzer)
            videoStage.setMode(mode)
            webcamPool.startFilling()
            videoOutput.bind(webcamPool: webcamPool)
            videoOutput.bind(videoClipPool: videoClipPool)
            videoOutput.bind(store: videoStage)
            videoStage.bind(speechTranscriber: speechTranscriber)
            videoStage.ingestAudienceInfluenceTelemetry(audienceServer.lastInfluenceTelemetry)
            audienceServer.publishStageSnapshot(StageSnapshotPayload.fromVideoStageSnapshot(videoStage.snapshot))
            analyzer.onLiveInputBuffer = { [weak audio] buffer, time in
                audio?.ingestLiveInputBuffer(buffer, time: time)
            }
            speechTranscriber.requestAuthorization()
            analyzer.onLiveInputRawBuffers = { [weak audio, weak speechTranscriber] audioBufferList, frameCount, sampleRate in
                audio?.ingestLiveInputAudioBuffers(audioBufferList, frameCount: frameCount, sampleRate: sampleRate)
                speechTranscriber?.appendRawAudio(audioBufferList, frameCount: frameCount, sampleRate: sampleRate)
            }
            analyzer.onLiveStageAudioSnapshot = { snapshot in
                DispatchQueue.main.async {
                    videoStage.ingestStageAudioSnapshot(snapshot)
                }
            }
            analyzer.onSoftLinkTick = { [weak softLink] rawLevels, channelCount in
                DispatchQueue.main.async {
                    guard let softLink else { return }
                    softLink.tick(rawChannelLevels: rawLevels, channelCount: channelCount)
                }
            }
            if ProcessInfo.processInfo.environment["TUB_PRELOAD_JOLT_CLIPS"] == "1" {
                let clipDirectory = URL(fileURLWithPath: "/Users/seb/Desktop/video-for-modes4-7")
                videoClipPool.loadInBackground(from: clipDirectory)
            }
            analyzer.refreshInputDevices()
            audio.refreshInputRouting()
            audio.refreshOutputDevices()
            controlRoom.bind(client: client, audio: audio, analyzer: analyzer)
            syncLiveInputCaptureInfo()
            syncSessionInputRouteMetadata()
            syncSessionOutputRouteMetadata()

            audio.onInputRecordingAlignment = { alignment in
                client.noteSessionAudioAlignment(hostTime: alignment.hostTime, sampleIndex: alignment.sampleIndex)
            }
        }
        .onChange(of: analyzer.inputRouteProfile) { _, _ in
            syncLiveInputCaptureInfo()
            syncSessionInputRouteMetadata()
        }
        .onChange(of: analyzer.inputRouteWarning) { _, _ in
            syncLiveInputCaptureInfo()
            syncSessionInputRouteMetadata()
        }
        .onChange(of: audio.outputProfile) { _, _ in
            syncSessionOutputRouteMetadata()
        }
        .onChange(of: audio.outputRouteMode) { _, _ in
            syncSessionOutputRouteMetadata()
        }
        .onChange(of: mode) { _, newMode in
            mlMonitor.setMode(newMode)
            videoStage.setMode(newMode)
        }
        .onReceive(audienceServer.$lastInfluenceTelemetry.receive(on: RunLoop.main)) { telemetry in
            videoStage.ingestAudienceInfluenceTelemetry(telemetry)
        }
        .onReceive(videoStage.$snapshot.removeDuplicates().receive(on: RunLoop.main)) { snapshot in
            audienceServer.publishStageSnapshot(StageSnapshotPayload.fromVideoStageSnapshot(snapshot))
        }
        .onReceive(softLink.$pendingEvents.receive(on: RunLoop.main)) { events in
            guard !events.isEmpty else { return }
            processSoftLinkEvents(events)
            // Clear after processing — will re-fire with [] but guard catches it.
            softLink.clearEvents()
        }
        .onChange(of: isReplayRunning) { _, running in
            if running {
                releaseAllJoltHolds()
            }
        }
        .onDisappear {
            releaseAllJoltHolds()
            modelServer.stop()
        }
    }

    private var workspaceDeck: some View {
        HStack(alignment: .top, spacing: 10) {
            if controlRoom.shell.showLeftRail {
                leftRail
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            centerStage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if runMode == .training && controlRoom.shell.showRightRail {
                rightRail
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    headerBrandBlock
                        .frame(maxWidth: .infinity, alignment: .leading)
                    headerStateRail
                    headerActionRail
                }

                VStack(alignment: .leading, spacing: 10) {
                    headerBrandBlock
                    HStack(alignment: .center, spacing: 12) {
                        headerStateRail
                        Spacer(minLength: 0)
                        headerActionRail
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    headerBrandBlock
                    headerStateRail
                    headerActionRail
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    headerMetaTiles
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                    headerMetaTiles
                }
            }
        }
        .shellPanelCard(fill: ShellChromePalette.surfaceElevated, borderOpacity: 0.18, shadowOpacity: 0.08, contentPadding: 8)
    }

    @ViewBuilder
    private var headerBrandBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("The Tub Control Room")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(ShellChromePalette.ink)
            Text("Live DSP harness \u{00B7} \(runMode.title)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(ShellChromePalette.inkSoft)
        }
    }

    @ViewBuilder
    private var headerStateRail: some View {
        HStack(spacing: 8) {
            headerStatePills
        }
    }

    @ViewBuilder
    private var headerStatePills: some View {
        ShellStatusPill(
            title: "Model",
            value: controlRoom.transport.isReady ? "Ready" : "Offline",
            tone: controlRoom.transport.isReady ? .positive : .idle
        )
        ShellStatusPill(
            title: "Run",
            value: client.isRunning ? "Live Audio" : "Idle",
            tone: client.isRunning ? .active : .idle
        )
        ShellStatusPill(
            title: "Replay",
            value: isReplayRunning ? "Active" : "Idle",
            tone: isReplayRunning ? .warning : .idle
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var headerActionRail: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                headerTransportButton
                headerSecondaryButtons
                headerVisibilityToggleGroup
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    headerTransportButton
                    headerSecondaryButtons
                }
                headerVisibilityToggleGroup
            }
        }
    }

    @ViewBuilder
    private var headerTransportButton: some View {
        Button {
            if client.isRunning {
                stopAll()
            } else {
                startSelectedProfile()
            }
        } label: {
            if isTransportTransitioning {
                Label("Working", systemImage: "hourglass")
            } else {
                Label(client.isRunning ? "Stop" : "Start", systemImage: client.isRunning ? "stop.fill" : "play.fill")
            }
        }
        .shellActionButton(
            role: .primaryTransport,
            accent: isTransportTransitioning ? ShellChromePalette.accentBlue : (client.isRunning ? ShellChromePalette.dangerRed : ShellChromePalette.startGreen)
        )
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityIdentifier("control_room.start_stop")
        .disabled(isReplayRunning || isTransportTransitioning)
    }

    @ViewBuilder
    private var headerSecondaryButtons: some View {
        Button {
            controlRoom.shell.showCommandPalette = true
        } label: {
            Label("Palette", systemImage: "command")
        }
        .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.accentBlue, size: .compact)
        .keyboardShortcut("k", modifiers: [.command])
        .accessibilityIdentifier("control_room.command_palette")

        Button {
            controlRoom.shell.showShortcutLegend = true
        } label: {
            Label("Shortcuts", systemImage: "keyboard")
        }
        .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.accentBlue, size: .compact)
    }

    private var headerVisibilityToggleGroup: some View {
        let items: [ShellSegmentedToggleItem<ShellVisibilityPanel>] = {
            var list = [ShellSegmentedToggleItem(value: ShellVisibilityPanel.left, title: "Left Panel", systemImage: nil)]
            if runMode == .training {
                list.append(ShellSegmentedToggleItem(value: ShellVisibilityPanel.right, title: "Right Panel", systemImage: nil))
                list.append(ShellSegmentedToggleItem(value: ShellVisibilityPanel.timeline, title: "Timeline", systemImage: nil))
            }
            return list
        }()
        return ShellSegmentedToggleGroup(
            items: items,
            isActive: isHeaderPanelVisible,
            toggle: toggleHeaderPanel,
            size: .compact
        )
    }

    @ViewBuilder
    private var headerMetaTiles: some View {
        ShellMetaTile(label: "Session", value: sessionDisplayValue)
        ShellMetaTile(label: "Endpoint", value: "\(controlRoom.transport.endpointHost):\(controlRoom.transport.endpointPort)")
        ShellMetaTile(label: "Bundle", value: bundleDisplayName)
        ShellMetaTile(label: "Input", value: analyzer.activeInputName)
        ShellMetaTile(label: "Output", value: outputRouteSummary)
    }

    private var leftRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                modeRailSection
                Divider()
                    .background(Color.black.opacity(0.10))
                mlMonitorRailSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .shellPanelCard(fill: ShellChromePalette.surface, borderOpacity: 0.18)
    }

    private var modeRailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                panelTitle("Modes")
                Spacer()
                Text("Mode \(mode) Active")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ShellChromePalette.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ShellChromePalette.accentBlueSoft, in: Capsule())
            }

            Text("Switch the live model mode directly. The DSP path stays on; only the active mode changes.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(ShellChromePalette.inkSoft)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(0...10, id: \.self) { m in
                    modeSelectorButton(m)
                }
            }
        }
    }

    private var mlMonitorRailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                panelTitle("ML Monitor")
                Spacer()
                Text(mlMonitor.snapshot.modeTitle)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(mlMonitor.snapshot.hasAdjustments ? ShellChromePalette.warmAmber : ShellChromePalette.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (mlMonitor.snapshot.hasAdjustments ? ShellChromePalette.warmAmberSoft : ShellChromePalette.accentBlueSoft),
                        in: Capsule()
                    )
            }

            Text("Read-only view of what the model is asking for now, with harness-resolved controls shown as the primary surface.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(ShellChromePalette.inkSoft)

            MLMonitorSummaryView(snapshot: mlMonitor.snapshot)

            if mlMonitor.snapshot.isWaiting {
                Text(mlMonitor.snapshot.waitingReason ?? "Awaiting the next control packet.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(ShellChromePalette.inkSoft)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ShellChromePalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ShellChromePalette.border, lineWidth: 1)
                    }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resolved Controls")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(ShellChromePalette.inkSoft)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(mlMonitor.snapshot.resolvedKnobs) { knob in
                            MLMonitorKnobView(knob: knob, compact: false)
                        }
                    }
                }

                if !mlMonitor.snapshot.commonKnobs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Output Shape")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ShellChromePalette.inkSoft)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(mlMonitor.snapshot.commonKnobs) { knob in
                                MLMonitorKnobView(knob: knob, compact: true)
                            }
                        }
                    }
                }

                if !mlMonitor.snapshot.picks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Active Picks")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ShellChromePalette.inkSoft)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(mlMonitor.snapshot.picks) { pick in
                                MLMonitorPickCardView(pick: pick)
                            }
                        }
                    }
                }
            }
        }
    }

    private func modeSelectorButton(_ candidate: Int) -> some View {
        let isActive = candidate == mode
        return Button {
            mode = candidate
            client.setMode(candidate)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mode \(candidate)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(isActive ? "Active now" : "Switch live mode")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? ShellChromePalette.accentBlue : ShellChromePalette.inkSoft)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .shellActionButton(
            role: isActive ? .secondaryAction : .utilityAction,
            accent: isActive ? ShellChromePalette.accentBlue : nil
        )
    }

    private func slotCard(_ slot: ModelSlotProfile) -> some View {
        let isActive = controlRoom.modelSlots.activeSlotId == slot.id
        let isArmed = controlRoom.modelSlots.armedSlotId == slot.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Slot name", text: Binding(
                    get: { slot.name },
                    set: { newValue in
                        controlRoom.updateSlot(slot.id) { $0.name = newValue }
                    }
                ))
                .textFieldStyle(.roundedBorder)

                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.22), in: Capsule())
                }
            }

            HStack(spacing: 6) {
                TextField("Host", text: Binding(
                    get: { slot.host },
                    set: { newValue in controlRoom.updateSlot(slot.id) { $0.host = newValue } }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Port", value: Binding(
                    get: { slot.port },
                    set: { newValue in controlRoom.updateSlot(slot.id) { $0.port = newValue } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
            }

            TextField("Notes", text: Binding(
                get: { slot.notes },
                set: { newValue in controlRoom.updateSlot(slot.id) { $0.notes = newValue } }
            ))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Button(isArmed ? "Confirm Switch" : "Arm Switch") {
                    controlRoom.armOrSwitchSlot(slot)
                }
                .shellActionButton(
                    role: .secondaryAction,
                    accent: isArmed ? ShellChromePalette.warmAmber : ShellChromePalette.accentBlue,
                    size: .compact
                )
                .accessibilityIdentifier("control_room.slot_switch_\(slot.id.uuidString)")

                if controlRoom.modelSlots.slots.count > 1 {
                    Button("Remove") {
                        controlRoom.removeSlot(slot.id)
                    }
                    .shellActionButton(role: .destructiveAction, size: .compact)
                }
            }
        }
        .padding(8)
        .background((isActive ? Color.green.opacity(0.14) : Color(red: 0.97, green: 0.98, blue: 1.0)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isArmed ? Color.orange.opacity(0.9) : Color.black.opacity(0.14), lineWidth: 1)
        }
    }

    private var centerStage: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    panelTitle("Live Operations")

                    HStack(spacing: 10) {
                        ShellStatusPill(
                            title: "Path",
                            value: runProfile.title,
                            tone: .active
                        )
                        .frame(maxWidth: 240, alignment: .leading)

                        Text("This harness always runs the real audio + DSP path.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(ShellChromePalette.inkSoft)

                        Spacer()

                        if runMode == .training {
                            Toggle("Record Input Audio", isOn: $recordInputAudio)
                                .toggleStyle(.switch)
                                .accessibilityIdentifier("control_room.record_toggle")
                        }
                    }
                    .padding(.horizontal, 2)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            liveOpsInputCard
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            liveOpsOutputCard
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            liveOpsInputCard
                            liveOpsOutputCard
                        }
                    }

                    HStack(spacing: 8) {
                        let feedbackDisabled = isReplayRunning || client.feedbackTargetState == .none
                        let feedbackTargetText: String = {
                            switch client.feedbackTargetState {
                            case .active:
                                return "active: \(client.feedbackTargetSessionId ?? "none")"
                            case .lastFinished:
                                return "last finished: \(client.feedbackTargetSessionId ?? "none")"
                            case .none:
                                return "none"
                            }
                        }()

                        ShellPressAndHoldButton(
                            role: .secondaryAction,
                            accent: ShellChromePalette.warmAmber,
                            size: .compact,
                            isActive: client.isJoltHeld,
                            onPressChanged: { isPressed in
                                setJoltHold(.mouse, active: isPressed && !isReplayRunning)
                            }
                        ) {
                            Label(client.isJoltHeld ? "Jolt Held" : "Hold Jolt", systemImage: client.isJoltHeld ? "bolt.fill" : "bolt")
                        }
                            .disabled(isReplayRunning)
                            .overlay(alignment: .topTrailing) {
                                softLinkBadge
                            }

                        Button("Clear") { client.pulseClear() }
                            .shellActionButton(role: .utilityAction, size: .compact)
                            .keyboardShortcut("l", modifiers: [.command])
                            .disabled(isReplayRunning)

                        Button("Send once") { client.sendOnce(mode: mode) }
                            .shellActionButton(role: .utilityAction, size: .compact)
                            .disabled(isReplayRunning)

                        if runMode == .training {
                            Divider().frame(height: 18)

                            Button("Good") { client.setHumanLabel(.good) }
                                .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.startGreen, size: .compact)
                                .keyboardShortcut("1", modifiers: [])
                                .disabled(feedbackDisabled)
                            Button("Too Much") { client.setHumanLabel(.tooMuch) }
                                .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.dangerRed, size: .compact)
                                .keyboardShortcut("2", modifiers: [])
                                .disabled(feedbackDisabled)
                            Button("Too Flat") { client.setHumanLabel(.tooFlat) }
                                .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.warmAmber, size: .compact)
                                .keyboardShortcut("3", modifiers: [])
                                .disabled(feedbackDisabled)
                            Button("Clear Label") { client.setHumanLabel(nil) }
                                .shellActionButton(role: .utilityAction, size: .compact)
                                .keyboardShortcut("0", modifiers: [])
                                .disabled(feedbackDisabled)

                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Label: \(client.currentLabel?.rawValue ?? "none")")
                                    .foregroundStyle(Color.black.opacity(0.74))
                                Text("Feedback target: \(feedbackTargetText)")
                                    .foregroundStyle(client.feedbackTargetState == .none ? Color.orange : Color.black.opacity(0.74))
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                            }
                        }
                    }

                    if runMode == .training {
                        Divider().background(Color.black.opacity(0.16))
                        replayOperationsCard
                    }

                    Divider().background(Color.black.opacity(0.16))

                    TelemetryReadoutView(client: client, analyzer: analyzer, audio: audio)

                    if runMode == .training {
                        Divider().background(Color.black.opacity(0.16))
                    }

                    if runMode == .training {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Control Room Event Log")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(controlRoom.events.prefix(12)) { event in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(timeString(event.timestamp))
                                            .foregroundStyle(Color.black.opacity(0.60))
                                            .frame(width: 72, alignment: .leading)
                                        Circle()
                                            .fill(event.severity.color)
                                            .frame(width: 6, height: 6)
                                            .padding(.top, 5)
                                        Text(event.message)
                                            .foregroundStyle(Color.black.opacity(0.86))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(proxy.size.height - 24, 1), alignment: .topLeading)
            }
            .contentMargins(.vertical, 0, for: .scrollContent)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .shellPanelCard(fill: ShellChromePalette.surface, borderOpacity: 0.18)
    }

    private var liveOpsInputCard: some View {
        let activeInput = analyzer.inputDevices.first(where: { $0.uid == analyzer.selectedInputUID })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("Live ingest and always-hot active paths.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                }
                Spacer()
                Text("Active Input: \(analyzer.activeInputName)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(ShellChromePalette.inkSoft)
            }

            HStack(spacing: 8) {
                inputDeviceMenu
                Button("Refresh Inputs") {
                    analyzer.refreshInputDevices()
                    audio.refreshInputRouting()
                    syncLiveInputCaptureInfo()
                    syncSessionInputRouteMetadata()
                }
                .shellActionButton(role: .utilityAction, size: .compact)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Input Paths + Manual Trim")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Text("Primary input stays hot. Additional inputs are opt-in. Trims affect live DSP + features only.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                    }
                    Spacer()
                    Button("Open Input Paths & Trim") {
                        showInputRoutingModal = true
                    }
                    .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.accentBlue, size: .compact)
                }

                HStack(spacing: 12) {
                    Text("Active: \(analyzer.inputRouteProfile.activeCount)/\(activeInput?.inputChannels ?? 0)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text("Map: \(analyzer.inputRouteProfile.activeSummary())")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                    if let warning = analyzer.inputRouteWarning, !warning.isEmpty {
                        Text(warning)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.86))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.84), in: Capsule())
                    } else {
                        Text("Capture stays aligned with output.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                    }
                }
                .foregroundStyle(Color.black.opacity(0.72))

                ChannelMetersView(analyzer: analyzer, channelCount: activeInput?.inputChannels ?? 0)
            }
            .padding(10)
            .background(Color(red: 0.96, green: 0.98, blue: 1.0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.14), lineWidth: 1)
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
    }

    private var liveOpsOutputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("Routing, safety fallback, and gallery calibration.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                }
                Spacer()
                Text("Output: \(audio.activeOutputName) • \(audio.activeOutputChannels)ch")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(ShellChromePalette.inkSoft)
            }

            HStack(spacing: 8) {
                outputDeviceMenu
                Button("Refresh Outputs") {
                    audio.refreshOutputDevices()
                }
                .shellActionButton(role: .utilityAction, size: .compact)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Output Route Mode")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.72))
                ShellSegmentedToggleGroup(
                    items: [
                        ShellSegmentedToggleItem(value: OutputRouteMode.gallery6Locked, title: "Gallery 6ch Locked", systemImage: nil),
                        ShellSegmentedToggleItem(value: OutputRouteMode.stereoFallback, title: "Stereo Safety Fallback", systemImage: nil)
                    ],
                    isActive: { $0 == audio.outputProfile.preferredMode },
                    toggle: { audio.setOutputRouteMode($0) },
                    size: .compact
                )

                HStack(spacing: 8) {
                    Text(audio.outputRouteLocked ? "Gallery Route Locked" : "Stereo Fallback Active")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.black.opacity(0.88))
                        .background((audio.outputRouteLocked ? Color.green.opacity(0.86) : Color.yellow.opacity(0.9)), in: Capsule())
                        .overlay {
                            Capsule().stroke(audio.outputRouteLocked ? Color.green.opacity(0.95) : Color.yellow.opacity(0.95), lineWidth: 1)
                        }
                    Text("Route mode: \(audio.outputRouteMode.rawValue)")
                        .foregroundStyle(Color.black.opacity(0.72))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                    if let warning = audio.outputRouteWarning, !warning.isEmpty {
                        Text(warning)
                            .foregroundStyle(Color.black.opacity(0.88))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.9), in: Capsule())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gallery 6-Channel Routing + Calibration")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Text("Open the dedicated setup modal for mapping, trim, delay, and speaker tests.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                    }
                    Spacer()
                    Button("Open Routing & Calibration") {
                        showOutputRoutingModal = true
                    }
                    .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.accentBlue, size: .compact)
                }

                HStack(spacing: 12) {
                    Text("Output Master Gain")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Slider(
                        value: Binding(
                            get: { audio.outputProfile.masterGainDb },
                            set: { newValue in
                                audio.updateOutputProfile { $0.masterGainDb = newValue }
                            }
                        ),
                        in: OutputRoutingProfile.minMasterGainDb...OutputRoutingProfile.maxMasterGainDb,
                        step: 0.5
                    )
                    .tint(Color(red: 0.15, green: 0.48, blue: 0.90))
                    .frame(width: 180)
                    Text(String(format: "%.1f dB", audio.outputProfile.masterGainDb))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text("Pink: \(String(format: "%.1f", audio.outputProfile.testLevelDb)) dB")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text("Map \(audio.outputProfile.mappingSummary())")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.black.opacity(0.72))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Hardware Output Monitor")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.72))
                        Spacer()
                        Text("First hardware output channels, up to 6")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                    }

                    outputRenderDiagnosticsStrip

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(0..<min(OutputRoutingProfile.virtualChannelCount, max(1, audio.activeOutputChannels)), id: \.self) { idx in
                            outputMonitorTile(hardwareIndex: idx)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(red: 0.96, green: 0.98, blue: 1.0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.14), lineWidth: 1)
            }

            videoOutputOperatorBlock
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
    }

    private var inputDeviceMenu: some View {
        Group {
            if analyzer.inputDevices.isEmpty {
                Text("No input device")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    }
            } else {
                Menu {
                    ForEach(analyzer.inputDevices) { device in
                        Button {
                            setInputDevice(uid: device.uid)
                        } label: {
                            if device.uid == analyzer.selectedInputUID {
                                Label("\(device.name) (\(device.inputChannels)ch)", systemImage: "checkmark")
                            } else {
                                Text("\(device.name) (\(device.inputChannels)ch)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input Device")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(ShellChromePalette.inkSoft)
                            Text(selectedInputDeviceTitle)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(ShellChromePalette.ink)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(ShellChromePalette.inkSoft)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .shellActionButton(role: .utilityAction)
            }
        }
    }

    private var outputDeviceMenu: some View {
        Group {
            if audio.outputDevices.isEmpty {
                Text("No output device")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    }
            } else {
                Menu {
                    ForEach(audio.outputDevices) { device in
                        Button {
                            setOutputDevice(uid: device.uid)
                        } label: {
                            if device.uid == audio.selectedOutputUID {
                                Label("\(device.name) (\(device.outputChannels)ch)", systemImage: "checkmark")
                            } else {
                                Text("\(device.name) (\(device.outputChannels)ch)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output Device")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(ShellChromePalette.inkSoft)
                            Text(selectedOutputDeviceTitle)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(ShellChromePalette.ink)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(ShellChromePalette.inkSoft)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .shellActionButton(role: .utilityAction)
            }
        }
    }

    private var rightRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                panelTitle("Rubric + Annotation")

            rubricSlider(label: "Stability", value: Binding(
                get: { controlRoom.rubric.scores.stability },
                set: { controlRoom.rubric.scores.stability = $0 }
            ))
            rubricSlider(label: "Responsiveness", value: Binding(
                get: { controlRoom.rubric.scores.responsiveness },
                set: { controlRoom.rubric.scores.responsiveness = $0 }
            ))
            rubricSlider(label: "Timbre Quality", value: Binding(
                get: { controlRoom.rubric.scores.timbreQuality },
                set: { controlRoom.rubric.scores.timbreQuality = $0 }
            ))
            rubricSlider(label: "Mode Fidelity", value: Binding(
                get: { controlRoom.rubric.scores.modeFidelity },
                set: { controlRoom.rubric.scores.modeFidelity = $0 }
            ))
            rubricSlider(label: "Performance Confidence", value: Binding(
                get: { controlRoom.rubric.scores.performanceConfidence },
                set: { controlRoom.rubric.scores.performanceConfidence = $0 }
            ))

            HStack {
                Text(String(format: "Average: %.2f", controlRoom.rubric.scores.average))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                if let saved = controlRoom.rubric.lastSavedAt {
                    Text("Saved \(timeString(saved))")
                        .foregroundStyle(Color.black.opacity(0.62))
                }
            }

            TextEditor(text: Binding(
                get: { controlRoom.rubric.notes },
                set: { controlRoom.rubric.notes = $0 }
            ))
            .frame(minHeight: 180)
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.97, green: 0.98, blue: 1.0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.16), lineWidth: 1)
            }

            Button("Save Rubric Entry") {
                controlRoom.saveRubric(mode: mode, runProfile: runProfile)
            }
            .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.startGreen)
            .accessibilityIdentifier("control_room.rubric_save")

            Divider().background(Color.black.opacity(0.16))

            VStack(alignment: .leading, spacing: 6) {
                Text("Phase1 A/B Eval")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                TextField("Dataset JSONL path", text: $evalDatasetPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEvalRunning)
                TextField("Baseline checkpoint path", text: $evalBaselinePath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEvalRunning)
                TextField("Candidate checkpoint path", text: $evalCandidatePath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEvalRunning)
                TextField("Modes (optional, csv)", text: $evalModesCSV)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEvalRunning)

                HStack(spacing: 8) {
                    Button(isEvalRunning ? "Evaluating..." : "Run Phase1 A/B Eval") {
                        runPhase1EvalAB()
                    }
                    .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.accentBlue)
                    .disabled(
                        isEvalRunning
                            || evalDatasetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || evalBaselinePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || evalCandidatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("control_room.eval_phase1_run")

                    Button("Clear") {
                        evalStatus = nil
                        evalReportText = ""
                    }
                    .shellActionButton(role: .utilityAction, size: .compact)
                    .disabled(isEvalRunning)
                }

                if let evalStatus {
                    Text(evalStatus)
                        .foregroundStyle(Color.black.opacity(0.78))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                }

                if !evalReportText.isEmpty {
                    ScrollView {
                        Text(evalReportText)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.76))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 90, maxHeight: 160)
                    .background(Color(red: 0.97, green: 0.98, blue: 1.0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.16), lineWidth: 1)
                    }
                }
            }

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .shellPanelCard(fill: ShellChromePalette.surface, borderOpacity: 0.18)
    }

    private var bottomTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                panelTitle("Telemetry Timeline")
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    ShellSegmentedToggleGroup(
                        items: [
                            ShellSegmentedToggleItem(value: TimelineMetricToggle.latency, title: "Latency", systemImage: nil),
                            ShellSegmentedToggleItem(value: TimelineMetricToggle.tick, title: "Tick", systemImage: nil),
                            ShellSegmentedToggleItem(value: TimelineMetricToggle.timeout, title: "Timeout", systemImage: nil),
                            ShellSegmentedToggleItem(value: TimelineMetricToggle.interventions, title: "Interventions", systemImage: nil),
                            ShellSegmentedToggleItem(value: TimelineMetricToggle.alignment, title: "Alignment", systemImage: nil)
                        ],
                        isActive: isTimelineMetricVisible,
                        toggle: toggleTimelineMetric,
                        size: .compact
                    )
                    .fixedSize(horizontal: true, vertical: true)
                }
                .frame(maxWidth: 520)
            }

            TelemetryTimelineView(telemetry: controlRoom.telemetry)

            HStack(spacing: 12) {
                Text("Samples: \(controlRoom.telemetry.samples.count)")
                if let last = controlRoom.telemetry.samples.last {
                    Text(String(format: "Replay alignment Δ: %.3fs", last.replayAlignmentDeltaS))
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(Color.black.opacity(0.70))
        }
        .shellPanelCard(fill: ShellChromePalette.surface, borderOpacity: 0.18, contentPadding: 10)
    }

    private var inputRoutingModal: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Input Paths + Manual Trim")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Choose which interface inputs stay hot for live DSP, then trim each path manually. Channel 1 stays on. Input recording remains raw multichannel.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.66))
                }
                Spacer()
                Button("Close Input Setup") {
                    showInputRoutingModal = false
                }
                .shellActionButton(role: .utilityAction)
            }

            if let activeInput = analyzer.inputDevices.first(where: { $0.uid == analyzer.selectedInputUID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Button("Reset Input Paths & Trim") {
                                analyzer.resetInputRouteProfileToDefault()
                                audio.resetInputRouteProfileToDefault()
                                syncLiveInputCaptureInfo()
                                syncSessionInputRouteMetadata()
                            }
                            .shellActionButton(role: .utilityAction)

                            Spacer()

                            Text("Active: \(analyzer.inputRouteProfile.activeCount)/\(activeInput.inputChannels)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.76))
                            Text("Map: \(analyzer.inputRouteProfile.activeSummary())")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.70))
                            if let warning = analyzer.inputRouteWarning, !warning.isEmpty {
                                Text(warning)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.88))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.9), in: Capsule())
                            }
                        }

                        Text("Use these trims to shape the live DSP/feature feed only. They do not rewrite the raw recorded multichannel input.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.70))

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                            ForEach(0..<activeInput.inputChannels, id: \.self) { idx in
                                let meter = analyzer.inputChannelLevels[safe: idx] ?? 0
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(idx == 0 ? "Input \(idx + 1) • Primary" : "Input \(idx + 1)")
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                            Text(idx == 0 ? "Always on for live capture." : "Opt in to keep this path hot.")
                                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                                .foregroundStyle(Color.black.opacity(0.64))
                                        }
                                        Spacer()
                                        Circle()
                                            .fill(
                                                meter > 0.015
                                                ? Color(red: 0.16, green: 0.70, blue: 0.34)
                                                : Color.black.opacity(0.14)
                                            )
                                            .frame(width: 11, height: 11)
                                            .overlay {
                                                Circle().stroke(Color.black.opacity(0.18), lineWidth: 1)
                                            }
                                        Text(String(format: "%.3f", meter))
                                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                                            .foregroundStyle(Color.black.opacity(0.70))
                                    }

                                    Toggle(
                                        idx == 0 ? "Primary Input Active" : "Enable This Input For Live DSP",
                                        isOn: Binding(
                                            get: { analyzer.inputRouteProfile.activeChannels[safe: idx] ?? false },
                                            set: { newValue in
                                                setInputChannelActive(index: idx, active: newValue)
                                            }
                                        )
                                    )
                                    .toggleStyle(.switch)
                                    .disabled(idx == 0)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Input Trim \(String(format: "%+.1f", analyzer.inputRouteProfile.channelGainDb[safe: idx] ?? 0)) dB")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.black.opacity(0.76))
                                        Slider(
                                            value: Binding(
                                                get: { analyzer.inputRouteProfile.channelGainDb[safe: idx] ?? 0 },
                                                set: { newValue in
                                                    setInputChannelGain(index: idx, gainDb: newValue)
                                                }
                                            ),
                                            in: InputRoutingProfile.minChannelGainDb...InputRoutingProfile.maxChannelGainDb,
                                            step: 0.5
                                        )
                                        .tint(Color(red: 0.12, green: 0.52, blue: 0.90))
                                    }
                                }
                                .padding(10)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .background(
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No input interface is currently selected.")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("Connect or choose an input device first, then reopen this setup panel.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.68))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 1040, minHeight: 720)
        .background(Color(red: 0.94, green: 0.97, blue: 1.0))
        .environment(\.colorScheme, .light)
    }

    private var outputRoutingModal: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gallery 6-Channel Routing + Calibration")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Route virtual channels V1–V6 to hardware outputs, calibrate alignment, and validate with pink-noise bursts.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.66))
                }
                Spacer()
                Button("Close Setup") {
                    showOutputRoutingModal = false
                }
                .shellActionButton(role: .utilityAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Reset Mapping to 1→6") { audio.resetOutputProfileToDefault() }
                            .shellActionButton(role: .utilityAction)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Master Output Trim")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.70))
                            HStack(spacing: 8) {
                                Slider(
                                    value: Binding(
                                        get: { audio.outputProfile.masterGainDb },
                                        set: { newValue in
                                            audio.updateOutputProfile { $0.masterGainDb = newValue }
                                        }
                                    ),
                                    in: OutputRoutingProfile.minMasterGainDb...OutputRoutingProfile.maxMasterGainDb,
                                    step: 0.5
                                )
                                .tint(Color(red: 0.20, green: 0.45, blue: 0.90))
                                .frame(width: 220)
                                Text(String(format: "%.1f dB", audio.outputProfile.masterGainDb))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.85))
                                    .frame(width: 76, alignment: .trailing)
                            }
                        }
                    }

                    Text("Assign each virtual channel (V1–V6) to a physical interface output. Use per-channel trim, delay, polarity, mute, and solo for alignment and troubleshooting.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.70))

                    ForEach(0..<OutputRoutingProfile.virtualChannelCount, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Text("Virtual Channel V\(idx + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.black.opacity(0.86))
                                Spacer()
                                Button("Test V\(idx + 1) Speaker") {
                                    audio.startOutputPinkNoiseTest(channel: idx, scanAll: false)
                                }
                                .shellActionButton(role: .secondaryAction, accent: ShellChromePalette.accentBlue, size: .compact)
                            }

                            HStack(alignment: .top, spacing: 14) {
                                Stepper(
                                    "Physical Output \(audio.outputProfile.channels[safe: idx]?.hardwareOutput ?? 1)",
                                    value: Binding(
                                        get: { audio.outputProfile.channels[safe: idx]?.hardwareOutput ?? 1 },
                                        set: { newValue in
                                            audio.updateOutputProfile {
                                                guard idx < $0.channels.count else { return }
                                                $0.channels[idx].hardwareOutput = newValue
                                            }
                                        }
                                    ),
                                    in: 1...max(1, audio.activeOutputChannels)
                                )
                                .frame(minWidth: 200, maxWidth: 260, alignment: .leading)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Channel Gain \(String(format: "%.1f", audio.outputProfile.channels[safe: idx]?.gainDb ?? 0)) dB")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.black.opacity(0.76))
                                    Slider(
                                        value: Binding(
                                            get: { audio.outputProfile.channels[safe: idx]?.gainDb ?? 0 },
                                            set: { newValue in
                                                audio.updateOutputProfile {
                                                    guard idx < $0.channels.count else { return }
                                                    $0.channels[idx].gainDb = newValue
                                                }
                                            }
                                        ),
                                        in: OutputRoutingProfile.minGainDb...OutputRoutingProfile.maxGainDb,
                                        step: 0.5
                                    )
                                    .tint(Color(red: 0.08, green: 0.55, blue: 0.89))
                                }
                                .frame(minWidth: 220)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Channel Delay \(String(format: "%.1f", audio.outputProfile.channels[safe: idx]?.delayMs ?? 0)) ms")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.black.opacity(0.76))
                                    Slider(
                                        value: Binding(
                                            get: { audio.outputProfile.channels[safe: idx]?.delayMs ?? 0 },
                                            set: { newValue in
                                                audio.updateOutputProfile {
                                                    guard idx < $0.channels.count else { return }
                                                    $0.channels[idx].delayMs = newValue
                                                }
                                            }
                                        ),
                                        in: OutputRoutingProfile.minDelayMs...OutputRoutingProfile.maxDelayMs,
                                        step: 0.5
                                    )
                                    .tint(Color(red: 0.88, green: 0.46, blue: 0.18))
                                }
                                .frame(minWidth: 220)
                            }

                            HStack(spacing: 18) {
                                Toggle("Invert Polarity", isOn: Binding(
                                    get: { audio.outputProfile.channels[safe: idx]?.polarityInverted ?? false },
                                    set: { newValue in
                                        audio.updateOutputProfile {
                                            guard idx < $0.channels.count else { return }
                                            $0.channels[idx].polarityInverted = newValue
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)

                                Toggle("Mute Channel", isOn: Binding(
                                    get: { audio.outputProfile.channels[safe: idx]?.muted ?? false },
                                    set: { newValue in
                                        audio.updateOutputProfile {
                                            guard idx < $0.channels.count else { return }
                                            $0.channels[idx].muted = newValue
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)

                                Toggle("Solo Channel", isOn: Binding(
                                    get: { audio.outputProfile.channels[safe: idx]?.solo ?? false },
                                    set: { newValue in
                                        audio.updateOutputProfile {
                                            guard idx < $0.channels.count else { return }
                                            $0.channels[idx].solo = newValue
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)
                            }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.82))
                        }
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.black.opacity(0.18), lineWidth: 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speaker Test (Pink-Noise Bursts)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.84))
                        Text("Use the speaker test toggle to verify channel order through outputs 1–6, then stop once routing is confirmed.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.68))

                        HStack(spacing: 8) {
                            outputScanSpeakerTestButton
                            Spacer()
                            Text("Pink Test Level")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.70))
                            Slider(
                                value: Binding(
                                    get: { audio.outputProfile.testLevelDb },
                                    set: { newValue in
                                        audio.updateOutputProfile { $0.testLevelDb = newValue }
                                    }
                                ),
                                in: OutputRoutingProfile.minTestLevelDb...OutputRoutingProfile.maxTestLevelDb,
                                step: 0.5
                            )
                            .tint(Color(red: 0.16, green: 0.49, blue: 0.90))
                            .frame(width: 200)
                            Text(String(format: "%.1f dB", audio.outputProfile.testLevelDb))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.85))
                                .frame(width: 78, alignment: .trailing)
                        }
                    }
                }
                .padding(12)
            }
            .background(
                Color(red: 0.95, green: 0.97, blue: 1.0),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
            }
        }
        .padding(16)
        .frame(minWidth: 1100, minHeight: 760)
        .background(Color(red: 0.94, green: 0.97, blue: 1.0))
        .environment(\.colorScheme, .light)
    }

    private var commandPalette: some View {
        let actions = paletteActions.filter {
            commandQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            $0.title.localizedCaseInsensitiveContains(commandQuery) ||
            $0.subtitle.localizedCaseInsensitiveContains(commandQuery) ||
            $0.keywords.contains(where: { $0.localizedCaseInsensitiveContains(commandQuery) })
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Command Palette")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            TextField("Type a command", text: $commandQuery)
                .textFieldStyle(.roundedBorder)
            List(actions) { action in
                Button {
                    runPaletteAction(action.id)
                    controlRoom.shell.showCommandPalette = false
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text(action.subtitle)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(red: 0.96, green: 0.98, blue: 1.0))
    }

    private var shortcutLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("Space: Start/Stop")
            Text("Cmd+K: Command palette")
            Text("1/2/3/0: Label controls")
            Text("Hold Cmd+J: Hold Jolt")
            Text("Cmd+L: Clear")
            Spacer()
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 260)
        .background(Color(red: 0.96, green: 0.98, blue: 1.0))
    }

    private var paletteActions: [CommandPaletteAction] {
        [
            CommandPaletteAction(id: "start_stop", title: client.isRunning ? "Stop Run" : "Start Run", subtitle: "Toggle live transport", keywords: ["transport", "run", "start", "stop"]),
            CommandPaletteAction(id: "jolt", title: "Pulse Jolt", subtitle: "Send momentary jolt control", keywords: ["jolt", "button"]),
            CommandPaletteAction(id: "clear", title: "Pulse Clear", subtitle: "Send momentary clear control", keywords: ["clear", "button"]),
            CommandPaletteAction(id: "replay_start", title: "Start Replay", subtitle: "Start replay for current session_id", keywords: ["replay", "start"]),
            CommandPaletteAction(id: "replay_stop", title: "Stop Replay", subtitle: "Cancel active replay", keywords: ["replay", "stop"]),
            CommandPaletteAction(id: "toggle_left", title: "Toggle Left Rail", subtitle: "Show/hide mode selector", keywords: ["panel", "left", "mode"]),
            CommandPaletteAction(id: "toggle_right", title: "Toggle Right Rail", subtitle: "Show/hide rubric workspace", keywords: ["panel", "right"]),
            CommandPaletteAction(id: "toggle_timeline", title: "Toggle Timeline", subtitle: "Show/hide telemetry timeline", keywords: ["panel", "timeline"])
        ]
    }

    private var sessionDisplayValue: String {
        if !controlRoom.transport.sessionId.isEmpty {
            return controlRoom.transport.sessionId
        }
        if let lastSessionId = controlRoom.replay.lastSessionId, !lastSessionId.isEmpty {
            return "Last \(lastSessionId)"
        }
        return "Created on Start"
    }

    private var bundleDisplayName: String {
        guard !controlRoom.transport.bundlePath.isEmpty else { return "Created on Start" }
        return URL(fileURLWithPath: controlRoom.transport.bundlePath).lastPathComponent
    }

    private var outputRouteSummary: String {
        "\(audio.activeOutputName) • \(audio.activeOutputChannels)ch"
    }

    private var videoOutputOperatorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video Output")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text("Windowed preview, fullscreen presentation, and the live brain-view field.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                }
                Spacer()
                videoOutputStatusChip
            }

            HStack(spacing: 8) {
                videoDisplayMenu
                Button(videoOutput.isPreviewEnabled ? "Hide Preview" : "Show Preview") {
                    videoOutput.setPreviewEnabled(!videoOutput.isPreviewEnabled)
                }
                .shellActionButton(
                    role: videoOutput.isPreviewEnabled ? .destructiveAction : .secondaryAction,
                    accent: videoOutput.isPreviewEnabled ? nil : ShellChromePalette.accentBlue,
                    size: .compact
                )

                Button("Reveal Preview") {
                    videoOutput.revealPreviewWindow()
                }
                .shellActionButton(role: .utilityAction, size: .compact)
                .disabled(videoOutput.displays.isEmpty || !videoOutput.isPreviewEnabled)

                Button(videoOutput.isPresenting ? "Exit Presentation" : "Present Fullscreen") {
                    videoOutput.setPresentationEnabled(!videoOutput.isPresenting)
                }
                .shellActionButton(
                    role: videoOutput.isPresenting ? .destructiveAction : .secondaryAction,
                    accent: videoOutput.isPresenting ? nil : ShellChromePalette.startGreen,
                    size: .compact
                )
                .disabled(videoOutput.displays.isEmpty)
            }

            if let warning = videoOutput.warningText, !warning.isEmpty {
                Text(warning)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.46, green: 0.27, blue: 0.04))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ShellChromePalette.warmAmberSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("Preview and presentation target: \(videoOutput.selectedDisplayTitle)")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(ShellChromePalette.inkSoft)
            }
        }
        .padding(10)
        .background(Color(red: 0.96, green: 0.98, blue: 1.0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.14), lineWidth: 1)
        }
    }

    private var videoDisplayMenu: some View {
        Group {
            if videoOutput.displays.isEmpty {
                Text("No display available")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    }
            } else {
                Menu {
                    ForEach(videoOutput.displays) { display in
                        Button {
                            videoOutput.selectDisplay(display.id)
                        } label: {
                            if display.id == videoOutput.selectedDisplayID {
                                Label(display.title, systemImage: "checkmark")
                            } else {
                                Text(display.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Video Display")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(ShellChromePalette.inkSoft)
                            Text(videoOutput.selectedDisplayTitle)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(ShellChromePalette.ink)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(ShellChromePalette.inkSoft)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .shellActionButton(role: .utilityAction)
            }
        }
    }

    private var videoOutputStatusChip: some View {
        let tone: ShellStatusTone = {
            switch videoOutput.status {
            case .hidden:
                return .idle
            case .previewing, .presenting:
                return .positive
            case .fallback, .missingDisplay:
                return .warning
            }
        }()

        return ShellStatusPill(
            title: "Video",
            value: videoOutput.status.label,
            tone: tone
        )
    }

    private var currentReplayCandidateId: String? {
        let trimmed = controlRoom.transport.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var lastReplayCandidateId: String? {
        guard let last = controlRoom.replay.lastSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty else {
            return nil
        }
        return last
    }

    private var replayResolvedSessionId: String? {
        let manual = replaySessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            return manual
        }
        if let currentReplayCandidateId {
            return currentReplayCandidateId
        }
        return lastReplayCandidateId
    }

    private var replaySourceSummary: String {
        let manual = replaySessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            if manual == currentReplayCandidateId {
                return "Current run selected"
            }
            if manual == lastReplayCandidateId {
                return "Last captured selected"
            }
            return "Manual session override"
        }
        if currentReplayCandidateId != nil {
            return "Defaults to current run"
        }
        if lastReplayCandidateId != nil {
            return "Defaults to last captured"
        }
        return "No replay source available"
    }

    private var replayStatusMessage: String {
        replayStatus ?? controlRoom.replay.statusMessage ?? "Choose a recorded session source, then start replay when you want to drive the harness from that capture."
    }

    private var selectedInputDeviceTitle: String {
        analyzer.inputDevices.first(where: { $0.uid == analyzer.selectedInputUID }).map {
            "\($0.name) (\($0.inputChannels)ch)"
        } ?? "Select input"
    }

    private var selectedOutputDeviceTitle: String {
        audio.outputDevices.first(where: { $0.uid == audio.selectedOutputUID }).map {
            "\($0.name) (\($0.outputChannels)ch)"
        } ?? "Select output"
    }

    private var outputScanSpeakerTestButton: some View {
        let isRunning = audio.isOutputTestRunning
        let title = isRunning ? "Stop Speaker Test" : "Start Speaker Test"
        let role: ShellActionRole = isRunning ? .destructiveAction : .secondaryAction
        let accent = isRunning ? ShellChromePalette.dangerRed : ShellChromePalette.accentBlue

        return Button(title) {
            if isRunning {
                audio.stopOutputTest()
            } else {
                audio.startOutputPinkNoiseTest(channel: nil, scanAll: true)
            }
        }
        .shellActionButton(role: role, accent: accent)
    }

    private var replayOperationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replay Recorded Session")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("Choose a captured session, then run its recorded trace and input audio back through the harness.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                }
                Spacer()
                ShellStatusPill(
                    title: "Replay",
                    value: isReplayRunning ? "Running" : "Ready",
                    tone: isReplayRunning ? .warning : .idle
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    replaySourceOptionCard(
                        title: "Current Run",
                        description: "Replay the live session that is active right now.",
                        sessionId: currentReplayCandidateId,
                        actionTitle: "Use Current Session",
                        isSelected: replayResolvedSessionId == currentReplayCandidateId && currentReplayCandidateId != nil
                    ) {
                        selectReplaySource(currentReplayCandidateId)
                    }

                    replaySourceOptionCard(
                        title: "Last Captured",
                        description: "Replay the most recent captured session after a stop.",
                        sessionId: lastReplayCandidateId,
                        actionTitle: "Use Last Captured",
                        isSelected: replayResolvedSessionId == lastReplayCandidateId && lastReplayCandidateId != nil
                    ) {
                        selectReplaySource(lastReplayCandidateId)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    replaySourceOptionCard(
                        title: "Current Run",
                        description: "Replay the live session that is active right now.",
                        sessionId: currentReplayCandidateId,
                        actionTitle: "Use Current Session",
                        isSelected: replayResolvedSessionId == currentReplayCandidateId && currentReplayCandidateId != nil
                    ) {
                        selectReplaySource(currentReplayCandidateId)
                    }

                    replaySourceOptionCard(
                        title: "Last Captured",
                        description: "Replay the most recent captured session after a stop.",
                        sessionId: lastReplayCandidateId,
                        actionTitle: "Use Last Captured",
                        isSelected: replayResolvedSessionId == lastReplayCandidateId && lastReplayCandidateId != nil
                    ) {
                        selectReplaySource(lastReplayCandidateId)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected Replay Source")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                        Text(replayResolvedSessionId ?? "No session selected yet")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(ShellChromePalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(replaySourceSummary)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(ShellChromePalette.inkSoft)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white, in: Capsule())
                        .overlay {
                            Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1)
                        }
                }

                HStack(spacing: 8) {
                    Button {
                        if isReplayRunning {
                            stopReplay()
                        } else {
                            startReplaySession()
                        }
                    } label: {
                        Label(isReplayRunning ? "Stop Replay" : "Start Replay", systemImage: isReplayRunning ? "stop.fill" : "play.fill")
                    }
                    .shellActionButton(
                        role: isReplayRunning ? .destructiveAction : .secondaryAction,
                        accent: isReplayRunning ? ShellChromePalette.dangerRed : ShellChromePalette.accentBlue
                    )
                    .disabled(!isReplayRunning && replayResolvedSessionId == nil)
                    .accessibilityIdentifier(isReplayRunning ? "control_room.replay_stop" : "control_room.replay_start")

                    Button(showManualReplayEntry ? "Hide Manual Session ID" : "Use a Different Session ID") {
                        showManualReplayEntry.toggle()
                    }
                    .shellActionButton(role: .utilityAction, size: .compact)

                    if showManualReplayEntry, !replaySessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear Manual Override") {
                            replaySessionId = ""
                        }
                        .shellActionButton(role: .utilityAction, size: .compact)
                    }
                }

                if showManualReplayEntry {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Manual Session ID")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                        TextField("Paste a recorded session ID if you want to replay something other than Current or Last Captured.", text: $replaySessionId)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("control_room.replay_session")
                    }
                }

                Text(replayStatusMessage)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.74))
            }
            .padding(10)
            .background(Color(red: 0.96, green: 0.98, blue: 1.0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.14), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jump During Replay")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Text("Move to a new time in the replay. Quick jumps are absolute positions from the session start.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                    }
                    Spacer()
                    Text(isReplayRunning ? "Replay transport is live." : "Start replay to enable jumping.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isReplayRunning ? ShellChromePalette.startGreen : ShellChromePalette.inkSoft)
                }

                HStack(spacing: 8) {
                    replayJumpButton("Start", seconds: 0)
                    replayJumpButton("30s", seconds: 30)
                    replayJumpButton("60s", seconds: 60)
                    replayJumpButton("120s", seconds: 120)
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Exact Time (Seconds)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(ShellChromePalette.inkSoft)
                        TextField("e.g. 42.5", text: $replaySeekSeconds)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180, alignment: .leading)
                            .accessibilityIdentifier("control_room.replay_seek")
                    }

                    Button("Jump to Time") { seekReplay() }
                        .shellActionButton(role: .utilityAction)
                        .disabled(!isReplayRunning || replaySeekSeconds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func replaySourceOptionCard(
        title: String,
        description: String,
        sessionId: String?,
        actionTitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(ShellChromePalette.ink)
                Text(description)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(ShellChromePalette.inkSoft)
            }

            Text(sessionId ?? "No session available yet")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(sessionId == nil ? Color.black.opacity(0.42) : Color.black.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button(actionTitle, action: action)
                    .shellActionButton(role: isSelected ? .secondaryAction : .utilityAction, accent: ShellChromePalette.accentBlue, size: .compact)
                    .disabled(sessionId == nil)
                if isSelected {
                    Text("Selected")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(ShellChromePalette.accentBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ShellChromePalette.accentBlueSoft, in: Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? ShellChromePalette.accentBlue.opacity(0.45) : Color.black.opacity(0.12), lineWidth: 1)
        }
    }

    private func replayJumpButton(_ title: String, seconds: Double) -> some View {
        Button(title) {
            seekReplay(to: seconds)
        }
        .shellActionButton(role: .utilityAction, size: .compact)
        .disabled(!isReplayRunning)
    }

    private var outputRenderDiagnosticsStrip: some View {
        let diag = audio.outputRenderDiagnostics
        let expectedText = "\(max(1, audio.activeOutputChannels))ch expected"
        let actualText = diag.slotCount > 0 ? "\(diag.slotCount)ch actual" : "no callback"
        let layoutText = diag.bufferCount > 0 ? "\(diag.bufferCount) buffer\(diag.bufferCount == 1 ? "" : "s")" : "no buffers"
        let preDb = levelText(diag.preRoutePeak)
        let postDb = levelText(diag.postRoutePeak)
        let mismatch = diag.slotCount > 0 && diag.configuredHardwareChannels > 0 && diag.slotCount != diag.configuredHardwareChannels
        let audioError = audio.audioError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let driverValue = diag.driverCallbackActive ? "Live" : (diag.driverCallbackCount > 0 ? "Seen" : "Idle")

        return HStack(spacing: 8) {
            outputRenderBadge(
                title: "Driver",
                value: driverValue,
                tint: diag.driverCallbackActive ? ShellChromePalette.startGreen : (diag.driverCallbackCount > 0 ? ShellChromePalette.warmAmber : Color.black.opacity(0.12))
            )
            outputRenderBadge(
                title: "Render",
                value: diag.callbackActive ? "Live" : "Idle",
                tint: diag.callbackActive ? ShellChromePalette.startGreen : Color.black.opacity(0.12)
            )
            outputRenderBadge(
                title: "Layout",
                value: "\(actualText) • \(layoutText)",
                tint: mismatch ? ShellChromePalette.warmAmber : ShellChromePalette.accentBlue.opacity(0.16),
                emphasize: mismatch
            )
            outputRenderBadge(
                title: "Signal",
                value: "pre \(preDb) • post \(postDb)",
                tint: diag.postRoutePeak > 0.0006 ? ShellChromePalette.accentBlue.opacity(0.16) : Color.black.opacity(0.08)
            )
            Text(expectedText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.60))
            if let audioError, !audioError.isEmpty {
                Text(audioError)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.22), in: Capsule())
            }
            Spacer()
        }
    }

    private func outputRenderBadge(title: String, value: String, tint: Color, emphasize: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.55))
            Text(value)
                .font(.system(size: 11, weight: emphasize ? .bold : .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
    }

    private func outputMonitorTile(hardwareIndex idx: Int) -> some View {
        let level = audio.outputHardwareLevels[safe: idx] ?? 0
        let normalized = min(1.0, max(0.0, sqrt(Double(level)) * 1.18))
        let dbText = levelText(level)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Out \(idx + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(ShellChromePalette.ink)
                Spacer()
                Circle()
                    .fill(level > 0.015 ? ShellChromePalette.startGreen : Color.black.opacity(0.12))
                    .frame(width: 8, height: 8)
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.16), lineWidth: 1)
                    }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.08))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(level > 0.20 ? ShellChromePalette.warmAmber : ShellChromePalette.accentBlue)
                        .frame(width: max(6, proxy.size.width * normalized))
                }
            }
            .frame(height: 9)

            HStack {
                Text(dbText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.76))
                Spacer()
                Text(level > 0.20 ? "hot" : level > 0.015 ? "live" : "idle")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.64))
            }
        }
        .padding(8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
    }

    private func levelText(_ level: Float) -> String {
        level > 0.0006 ? String(format: "%.0f dB", 20.0 * log10(Double(level))) : "−inf dB"
    }

    private func selectReplaySource(_ sessionId: String?) {
        guard let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        replaySessionId = sessionId
        showManualReplayEntry = false
    }

    private func runPaletteAction(_ id: String) {
        switch id {
        case "start_stop":
            if client.isRunning {
                stopAll()
            } else {
                startSelectedProfile()
            }
        case "jolt":
            client.pulseJolt()
            softLink.handleJoltPulse()
        case "clear":
            client.pulseClear()
        case "replay_start":
            startReplaySession()
        case "replay_stop":
            stopReplay()
        case "toggle_left":
            controlRoom.shell.showLeftRail.toggle()
        case "toggle_right":
            controlRoom.shell.showRightRail.toggle()
        case "toggle_timeline":
            controlRoom.shell.showBottomTimeline.toggle()
        default:
            break
        }
    }

    private func setJoltHold(_ source: JoltHoldSource, active: Bool) {
        if active {
            joltHoldSources.insert(source)
        } else {
            joltHoldSources.remove(source)
        }
        let isHeld = !joltHoldSources.isEmpty
        client.setJoltHeld(isHeld)
        softLink.handleJoltHoldChanged(isHeld: isHeld)
        print("[SoftLink-CV] setJoltHold source=\(source) active=\(active) isHeld=\(isHeld)")
    }

    private func releaseAllJoltHolds() {
        guard !joltHoldSources.isEmpty || client.isJoltHeld else {
            client.setJoltHeld(false)
            return
        }
        joltHoldSources.removeAll()
        client.setJoltHeld(false)
    }

    private func processSoftLinkEvents(_ events: [SoftLinkEvent]) {
        print("[SoftLink-CV] processing \(events.count) events → video stage + audience broadcast")
        videoStage.ingestSoftLinkEvents(events)
        for event in events {
            let message: String
            switch event.action {
            case .pairingStarted:
                message = "LINK:PAIRING"
            case .pairingCancelled:
                message = "LINK:CANCELLED"
            case .pairingTimedOut:
                message = "LINK:TIMEOUT"
            case .channelLinked:
                message = "LINK:CH\(event.channelIndex + 1):LINKED"
            case .channelUnlinked:
                message = "LINK:CH\(event.channelIndex + 1):UNLINKED"
            }
            audienceServer.broadcastAck(message: message)
        }
    }

    @ViewBuilder
    private var softLinkBadge: some View {
        switch softLink.globalState {
        case .idle:
            EmptyView()
        case .listening:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .offset(x: 4, y: -4)
                .transition(.scale)
        case .linked:
            Circle()
                .fill(Color.cyan)
                .frame(width: 8, height: 8)
                .offset(x: 4, y: -4)
        }
    }

    private func isHeaderPanelVisible(_ panel: ShellVisibilityPanel) -> Bool {
        switch panel {
        case .left:
            return controlRoom.shell.showLeftRail
        case .right:
            return controlRoom.shell.showRightRail
        case .timeline:
            return controlRoom.shell.showBottomTimeline
        }
    }

    private func toggleHeaderPanel(_ panel: ShellVisibilityPanel) {
        switch panel {
        case .left:
            controlRoom.shell.showLeftRail.toggle()
        case .right:
            controlRoom.shell.showRightRail.toggle()
        case .timeline:
            controlRoom.shell.showBottomTimeline.toggle()
        }
    }

    private func isTimelineMetricVisible(_ item: TimelineMetricToggle) -> Bool {
        switch item {
        case .latency:
            return controlRoom.telemetry.showLatency
        case .tick:
            return controlRoom.telemetry.showTick
        case .timeout:
            return controlRoom.telemetry.showTimeouts
        case .interventions:
            return controlRoom.telemetry.showInterventions
        case .alignment:
            return controlRoom.telemetry.showAlignment
        }
    }

    private func toggleTimelineMetric(_ item: TimelineMetricToggle) {
        switch item {
        case .latency:
            controlRoom.telemetry.showLatency.toggle()
        case .tick:
            controlRoom.telemetry.showTick.toggle()
        case .timeout:
            controlRoom.telemetry.showTimeouts.toggle()
        case .interventions:
            controlRoom.telemetry.showInterventions.toggle()
        case .alignment:
            controlRoom.telemetry.showAlignment.toggle()
        }
    }

    private func panelTitle(_ title: String) -> some View {
        ShellSectionTitle(title: title)
    }

    private func metricCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(ShellChromePalette.inkSoft)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(ShellChromePalette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(ShellChromePalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ShellChromePalette.border, lineWidth: 1)
        }
    }

    private func rubricSlider(label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f", value.wrappedValue))
            }
            Slider(value: value, in: 0...5, step: 0.5)
                .tint(Color(red: 0.36, green: 0.82, blue: 0.58))
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func setInputDevice(uid: String) {
        DispatchQueue.main.async {
            analyzer.selectInputDevice(uid: uid)
            audio.selectInputDevice(uid: uid)
            syncLiveInputCaptureInfo()
            syncSessionInputRouteMetadata()
        }
    }

    private func setInputChannelActive(index: Int, active: Bool) {
        analyzer.setInputChannelActive(channelIndex: index, active: active)
        audio.setInputChannelActive(channelIndex: index, active: active)
        syncLiveInputCaptureInfo()
        syncSessionInputRouteMetadata()
    }

    private func setInputChannelGain(index: Int, gainDb: Double) {
        analyzer.updateInputChannelGain(channelIndex: index, gainDb: gainDb)
        audio.updateInputChannelGain(channelIndex: index, gainDb: gainDb)
    }

    private func syncLiveInputCaptureInfo() {
        let info = analyzer.currentCaptureInfo()
        audio.updateLiveInputCaptureInfo(sampleRate: info.sampleRate, channels: info.channels)
    }

    private func syncSessionInputRouteMetadata() {
        let info = analyzer.currentInputRouteInfo()
        client.configureSessionInputRoute(
            inputDeviceUID: info.inputUID.isEmpty ? nil : info.inputUID,
            inputDeviceName: info.inputName,
            inputChannels: info.inputChannels,
            inputActiveChannels: info.activeSummary,
            inputRouteWarning: info.warning
        )
    }

    private func setOutputDevice(uid: String) {
        DispatchQueue.main.async {
            audio.selectOutputDevice(uid: uid)
            syncSessionOutputRouteMetadata()
        }
    }

    private func syncSessionOutputRouteMetadata() {
        let info = audio.currentOutputRouteInfo()
        client.configureSessionOutputRoute(
            outputDeviceUID: info.outputUID.isEmpty ? nil : info.outputUID,
            outputDeviceName: info.outputName,
            outputChannels: info.hardwareChannels,
            outputRouteMode: info.activeMode.rawValue,
            outputRouteMapping: info.mappingSummary,
            outputRouteWarning: info.warning
        )
    }

    private func parseEvalModesCSV(_ raw: String) -> [Int] {
        let pieces = raw
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" })
            .compactMap { Int($0) }
            .filter { (0...10).contains($0) }
        var seen = Set<Int>()
        return pieces.filter { seen.insert($0).inserted }
    }

    private func shellEscape(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        let escaped = raw.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func runPhase1EvalAB() {
        let dataset = evalDatasetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseline = evalBaselinePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = evalCandidatePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dataset.isEmpty, !baseline.isEmpty, !candidate.isEmpty else { return }

        let modes = parseEvalModesCSV(evalModesCSV)
        isEvalRunning = true
        evalStatus = "Running phase1 eval..."
        evalReportText = ""
        controlRoom.appendEvent("Running phase1 A/B eval.", severity: .info)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")

            var evalArgs = [
                "eval-phase1",
                "--dataset \(self.shellEscape(dataset))",
                "--baseline \(self.shellEscape(baseline))",
                "--candidate \(self.shellEscape(candidate))",
                "--fail-on-regression"
            ]
            for mode in modes {
                evalArgs.append("--mode \(mode)")
            }
            let tubMlCommand = ".venv/bin/tub-ml \(evalArgs.joined(separator: " "))"
            let fallbackCommand = "source .venv/bin/activate && tub-ml \(evalArgs.joined(separator: " "))"
            let command = [
                "cd /Users/seb/the-tub-ml",
                "if [ -x .venv/bin/tub-ml ]; then \(tubMlCommand); else \(fallbackCommand); fi"
            ]
            process.arguments = ["-lc", command.joined(separator: " && ")]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.isEvalRunning = false
                    self.evalStatus = "Eval launch failed: \(error.localizedDescription)"
                    self.controlRoom.appendEvent("Phase1 eval launch failed.", severity: .error)
                }
                return
            }

            let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let merged = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            let trimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
            let pass = trimmed.contains("\"overall_pass\": true")
            let failed = process.terminationStatus != 0

            DispatchQueue.main.async {
                self.isEvalRunning = false
                if failed {
                    self.evalStatus = "Phase1 eval failed (exit \(process.terminationStatus))."
                    self.controlRoom.appendEvent("Phase1 eval failed.", severity: .error)
                } else {
                    self.evalStatus = pass ? "Phase1 eval PASS." : "Phase1 eval FAIL."
                    self.controlRoom.appendEvent(
                        pass ? "Phase1 eval pass." : "Phase1 eval fail.",
                        severity: pass ? .info : .warning
                    )
                }
                self.evalReportText = trimmed.isEmpty ? "No output." : trimmed
            }
        }
    }

    private func startSelectedProfile() {
        guard !isTransportTransitioning else { return }
        if isReplayRunning {
            stopReplay()
        }
        replayStatus = nil
        isTransportTransitioning = true

        client.featuresProvider = { [weak analyzer] in
            analyzer?.snapshotFrame() ?? FeaturePacketSnapshot(
                features: Features(
                    loudnessLufs: -80,
                    onsetRateHz: 0,
                    specCentroidHz: 0,
                    bandLow: 0,
                    bandMid: 0,
                    bandHigh: 0,
                    noisiness: 0
                ),
                source: "dummy",
                fallbackReason: "analyzer_unavailable"
            )
        }
        if runMode == .training {
            client.interventionsProvider = { [weak audio] in
                audio?.snapshotSafetyInterventions() ?? []
            }
        } else {
            client.interventionsProvider = nil
        }

        client.onModelOut = { [weak audio, modeEngine, weak audienceServer, weak videoStage] out, _, sentButtons in
            guard let audio else { return }
            DispatchQueue.main.async {
                var influencedOut = out
                if let audienceServer,
                   let telemetry = audienceServer.applyAudienceOverlay(to: &influencedOut) {
                    videoStage?.ingestAudienceInfluenceTelemetry(telemetry)
                }
                let control = modeEngine.makeControl(out: influencedOut, sentButtons: sentButtons)
                audio.apply(control: control)
            }
        }

        client.setMode(mode)

        let shouldRecordInputAudio = (runMode == .training ? recordInputAudio : false)
        client.startLoop(
            recordInputAudio: shouldRecordInputAudio,
            replayMode: false,
            replayedSessionId: nil,
            runMode: runMode
        )
        syncLiveInputCaptureInfo()
        syncSessionInputRouteMetadata()
        syncSessionOutputRouteMetadata()
        client.setReplayContext(replayMode: false, replayedSessionId: nil)
        client.setReplayAudioMissing(false)
        let inputAudioPathForRecording = shouldRecordInputAudio ? client.inputAudioPath : nil

        DispatchQueue.global(qos: .userInitiated).async { [analyzer, audio] in
            analyzer.start()
            audio.start()

            var recordingError: Error?
            var recordingInfo: (sampleRate: Double, channels: Int, format: String, path: String)?
            if let path = inputAudioPathForRecording {
                do {
                    let info = try audio.startInputRecording(to: URL(fileURLWithPath: path), fileFormat: "caf")
                    recordingInfo = (sampleRate: info.sampleRate, channels: info.channels, format: info.format, path: path)
                } catch {
                    recordingError = error
                }
            }

            DispatchQueue.main.async {
                speechTranscriber.start()
                if let recordingInfo {
                    client.configureSessionInputAudio(
                        sampleRate: recordingInfo.sampleRate,
                        channels: recordingInfo.channels,
                        format: recordingInfo.format,
                        path: recordingInfo.path
                    )
                    controlRoom.appendEvent("Input audio recording enabled.", severity: .info)
                } else {
                    if let recordingError {
                        replayStatus = "Input audio recording failed: \(recordingError.localizedDescription)"
                        controlRoom.appendEvent("Input audio recording failed.", severity: .warning)
                    }
                    let inputInfo = analyzer.currentCaptureInfo()
                    client.configureSessionInputAudio(
                        sampleRate: inputInfo.sampleRate,
                        channels: inputInfo.channels,
                        format: inputInfo.format,
                        path: nil
                    )
                    controlRoom.appendEvent("Started \(runMode.title.lowercased()) run.", severity: .info)
                }
                syncLiveInputCaptureInfo()
                syncSessionInputRouteMetadata()
                syncSessionOutputRouteMetadata()
                isTransportTransitioning = false
            }
        }
    }

    private func stopAll() {
        guard !isTransportTransitioning else { return }
        isTransportTransitioning = true
        releaseAllJoltHolds()
        if isReplayRunning {
            stopReplay()
        }
        client.stopLoop()
        speechTranscriber.stop()

        let shouldCollectTrainingSummary = (runMode == .training)
        DispatchQueue.global(qos: .userInitiated).async { [audio, analyzer] in
            let summary = shouldCollectTrainingSummary ? audio.stopInputRecording() : nil
            audio.stop()
            analyzer.stop()

            DispatchQueue.main.async {
                if let summary {
                    client.configureSessionInputAudio(
                        sampleRate: summary.sampleRate,
                        channels: summary.channels,
                        format: summary.fileFormat,
                        path: summary.outputURL.path
                    )
                    if let alignment = summary.alignment {
                        client.noteSessionAudioAlignment(hostTime: alignment.hostTime, sampleIndex: alignment.sampleIndex)
                    }
                }

                if runMode == .training {
                    if let sid = client.activeSessionId {
                        replaySessionId = sid
                    }
                    if let p = client.logPath {
                        replayPath = p
                    }
                }
                syncLiveInputCaptureInfo()
                syncSessionInputRouteMetadata()
                syncSessionOutputRouteMetadata()
                controlRoom.appendEvent("Run stopped.", severity: .info)
                isTransportTransitioning = false
            }
        }
    }

    private func startReplaySession() {
        let sessionId = replayResolvedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionId.isEmpty else { return }
        guard !isReplayRunning else { return }
        guard !isTransportTransitioning else {
            replayStatus = "Transport busy. Try replay again in a moment."
            controlRoom.setReplayStatus(replayStatus)
            return
        }
        releaseAllJoltHolds()
        replaySessionId = sessionId

        if client.isRunning {
            stopAll()
            replayStatus = "Stopping live run. Tap replay again."
            controlRoom.setReplayStatus(replayStatus)
            return
        }
        analyzer.stop()
        audio.startReplayEngineIfNeeded()
        controlRoom.resetReplayAlignment()

        let token = ReplayCancellationToken()
        replayCancelToken = token
        isReplayRunning = true
        replayStatus = "Replay running for \(sessionId)..."
        client.setReplayAudioMissing(false)
        controlRoom.setReplayRunning(true)
        controlRoom.setReplayStatus(replayStatus)
        controlRoom.appendEvent("Replay started for session \(sessionId).", severity: .info)

        let endpoint = client.modelEndpoint()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let session = try ReplaySessionLoader.load(sessionId: sessionId)
                let startTs = session.metadata.alignment.startTsMs != 0
                    ? session.metadata.alignment.startTsMs
                    : (session.frames.first?.tsMs ?? 0)

                let hasAudio = (session.inputAudioURL != nil)
                if let audioURL = session.inputAudioURL {
                    try audio.startReplayInput(from: audioURL)
                    let warmupDeadline = Date().addingTimeInterval(0.50)
                    while !audio.isReplayInputActive && Date() < warmupDeadline {
                        usleep(5_000)
                    }
                } else {
                    audio.enableSilentReplayInputFallback()
                    client.setReplayAudioMissing(true)
                    print("{\"replay_audio_missing\":true,\"session_id\":\"\(sessionId)\"}")
                }
                let replayAnchorS = hasAudio ? audio.replayCurrentTimeSeconds() : 0

                let baseInterventions = hasAudio ? [String]() : ["replay_audio_missing"]
                let outURL = try TraceReplayer.replaySession(
                    session: session,
                    host: endpoint.host,
                    port: endpoint.port,
                    timeoutMs: 1_000,
                    timingProvider: hasAudio ? { max(0, audio.replayCurrentTimeSeconds() - replayAnchorS) } : nil,
                    baseInterventions: baseInterventions,
                    shouldCancel: { token.isCancelled },
                    onFrameResult: { frame, modelOut in
                        let target = max(0, Double(frame.tsMs - startTs) / 1000.0)
                        let audioTime = max(0, audio.replayCurrentTimeSeconds() - replayAnchorS)
                        DispatchQueue.main.async {
                            controlRoom.noteReplayAlignment(targetTimeS: target, audioTimeS: audioTime)
                        }

                        guard let modelOut else { return }
                        DispatchQueue.main.async {
                            let control = modeEngine.makeControl(out: modelOut, sentButtons: frame.modelIn.buttons)
                            audio.apply(control: control)
                        }
                    }
                )

                DispatchQueue.main.async {
                    isReplayRunning = false
                    replayCancelToken = nil
                    replayStatus = "Replay complete: \(outURL.path)"
                    replayPath = outURL.path
                    audio.stopReplayInput(restoreLiveInput: false)
                    audio.stop()
                    controlRoom.setReplayRunning(false)
                    controlRoom.setReplayStatus(replayStatus)
                    controlRoom.resetReplayAlignment()
                    controlRoom.appendEvent("Replay completed.", severity: .info)
                }
            } catch TraceReplayError.cancelled {
                DispatchQueue.main.async {
                    isReplayRunning = false
                    replayCancelToken = nil
                    replayStatus = "Replay stopped."
                    audio.stopReplayInput(restoreLiveInput: false)
                    audio.stop()
                    controlRoom.setReplayRunning(false)
                    controlRoom.setReplayStatus(replayStatus)
                    controlRoom.resetReplayAlignment()
                    controlRoom.appendEvent("Replay cancelled.", severity: .warning)
                }
            } catch {
                DispatchQueue.main.async {
                    isReplayRunning = false
                    replayCancelToken = nil
                    replayStatus = "Replay failed: \(error.localizedDescription)"
                    audio.stopReplayInput(restoreLiveInput: false)
                    audio.stop()
                    controlRoom.setReplayRunning(false)
                    controlRoom.setReplayStatus(replayStatus)
                    controlRoom.resetReplayAlignment()
                    controlRoom.appendEvent("Replay failed.", severity: .error)
                }
            }
        }
    }

    private func stopReplay() {
        guard isReplayRunning else { return }
        replayStatus = "Stopping replay..."
        replayCancelToken?.cancel()
        controlRoom.setReplayStatus(replayStatus)
    }

    private func seekReplay() {
        guard isReplayRunning else { return }
        guard let seconds = Double(replaySeekSeconds.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite else {
            replayStatus = "Seek value must be a number."
            controlRoom.setReplayStatus(replayStatus)
            return
        }
        seekReplay(to: seconds)
    }

    private func seekReplay(to seconds: Double) {
        guard isReplayRunning else { return }
        do {
            try audio.seekReplayInput(to: max(0, seconds))
            replayStatus = "Replay seeked to \(String(format: "%.2f", max(0, seconds)))s."
            controlRoom.setReplayStatus(replayStatus)
            controlRoom.appendEvent("Replay seek to \(String(format: "%.2f", max(0, seconds)))s", severity: .info)
        } catch {
            replayStatus = "Replay seek failed: \(error.localizedDescription)"
            controlRoom.setReplayStatus(replayStatus)
            controlRoom.appendEvent("Replay seek failed.", severity: .error)
        }
    }

    private func roundTripLine(_ out: ModelOut) -> String {
        let level = fmt(out.params["level"])
        let brightness = fmt(out.params["brightness"])
        let density = fmt(out.params["density"])
        let preset = out.picks.presetId ?? "nil"
        let spatial = out.picks.spatialPatternId ?? "nil"
        return "RoundTrip mode=\(out.mode) preset=\(preset) level=\(level) bright=\(brightness) dens=\(density) spatial=\(spatial) proto=\(out.protocolVersion)"
    }

    private func fmt(_ value: Double?) -> String {
        guard let value else { return "na" }
        return String(format: "%.2f", value)
    }

    private func featuresLine(_ f: Features) -> String {
        let pitchPart: String
        if let hz = f.pitchHz, f.pitchConf > 0.2 {
            pitchPart = String(format: " pitch=%.1fHz(%.2f)", hz, f.pitchConf)
        } else {
            pitchPart = " pitch=na"
        }
        let keyPart = " key=\(f.keyEstimate ?? "unknown")(\(String(format: "%.2f", f.keyConf)))"
        return String(
            format: "Features loud=%.1f onset=%.2f cent=%.0f bands=[%.2f %.2f %.2f] noise=%.2f%@",
            f.loudnessLufs,
            f.onsetRateHz,
            f.specCentroidHz,
            f.bandLow,
            f.bandMid,
            f.bandHigh,
            f.noisiness,
            pitchPart + keyPart
        )
    }

    private func mode56DiagLine(mode: Int, interventions: [String]) -> String {
        let modePrefix = "mode\(mode)_"
        let relevant = interventions.filter { token in
            token.hasPrefix(modePrefix) || token.hasPrefix("mode56_") || token.hasPrefix("render_mode:")
        }
        guard !relevant.isEmpty else { return "" }
        return "AudioDiag " + relevant.suffix(8).joined(separator: " | ")
    }
}
