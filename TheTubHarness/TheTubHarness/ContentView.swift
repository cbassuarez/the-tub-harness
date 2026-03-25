import SwiftUI
import Combine

enum HarnessRunProfile: String, CaseIterable, Identifiable {
    case networkOnly
    case audioAndFeatures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .networkOnly:
            return "Network Only (10 Hz)"
        case .audioAndFeatures:
            return "Audio + Real Features"
        }
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

struct RubricScores: Codable, Equatable {
    var stability: Double = 3
    var responsiveness: Double = 3
    var timbreQuality: Double = 3
    var modeFidelity: Double = 3
    var performanceConfidence: Double = 3

    var average: Double {
        (stability + responsiveness + timbreQuality + modeFidelity + performanceConfidence) / 5.0
    }
}

private struct RubricEntry: Codable {
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
                let enc = JSONEncoder()
                enc.keyEncodingStrategy = .convertToSnakeCase
                var payload = try enc.encode(entry)
                payload.append(0x0A)
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

        let entry = RubricEntry(
            tsMs: Int(Date().timeIntervalSince1970 * 1000),
            sessionId: client.activeSessionId,
            bundleId: client.bundlePath,
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
                context.stroke(border, with: .color(Color.white.opacity(0.18)), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                Text("Latency / Tick / Timeout / Alignment")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.35), in: Capsule())
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

struct ContentView: View {
    @StateObject private var client = TubMLClient(host: "127.0.0.1", port: 9910)
    @StateObject private var audio = AudioEngineController()
    @StateObject private var analyzer = AudioInputAnalyzer()
    @StateObject private var controlRoom = ControlRoomState()

    private let modeEngine = ModeEngine()

    @State private var mode: Int = 0
    @State private var runProfile: HarnessRunProfile = .audioAndFeatures
    @State private var recordInputAudio: Bool

    @State private var replayPath: String = ""
    @State private var replaySessionId: String = ""
    @State private var replaySeekSeconds: String = ""
    @State private var replayStatus: String?
    @State private var isReplayRunning: Bool = false
    @State private var replayCancelToken: ReplayCancellationToken?
    @State private var commandQuery: String = ""

    init(defaultRecordInputAudio: Bool = false) {
        _recordInputAudio = State(initialValue: defaultRecordInputAudio)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.08),
                    Color(red: 0.11, green: 0.12, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar

                HStack(alignment: .top, spacing: 10) {
                    if controlRoom.shell.showLeftRail {
                        leftRail
                            .frame(width: 330)
                    }

                    centerStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if controlRoom.shell.showRightRail {
                        rightRail
                            .frame(width: 360)
                    }
                }

                if controlRoom.shell.showBottomTimeline {
                    bottomTimeline
                        .frame(height: 220)
                }
            }
            .padding(12)
            .foregroundStyle(Color.white.opacity(0.93))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
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
        .onAppear {
            client.setMode(mode)
            analyzer.refreshInputDevices()
            controlRoom.bind(client: client, audio: audio, analyzer: analyzer)

            audio.onInputRecordingAlignment = { alignment in
                client.noteSessionAudioAlignment(hostTime: alignment.hostTime, sampleIndex: alignment.sampleIndex)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("THE TUB CONTROL ROOM")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.86, green: 0.90, blue: 0.96))

            statusChip(label: controlRoom.transport.isReady ? "MODEL READY" : "MODEL OFFLINE", active: controlRoom.transport.isReady)
            statusChip(label: client.isRunning ? "LIVE RUN" : "IDLE", active: client.isRunning)
            statusChip(label: isReplayRunning ? "REPLAY" : "NO REPLAY", active: isReplayRunning)

            Spacer(minLength: 8)

            Button(client.isRunning ? "Stop" : "Start") {
                if client.isRunning {
                    stopAll()
                } else {
                    startSelectedProfile()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(client.isRunning ? .red : .green)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityIdentifier("control_room.start_stop")
            .disabled(isReplayRunning)

            Button("Palette") {
                controlRoom.shell.showCommandPalette = true
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("k", modifiers: [.command])
            .accessibilityIdentifier("control_room.command_palette")

            Button("Shortcuts") {
                controlRoom.shell.showShortcutLegend = true
            }
            .buttonStyle(.bordered)

            Divider()
                .frame(height: 20)

            Toggle("L", isOn: Binding(
                get: { controlRoom.shell.showLeftRail },
                set: { controlRoom.shell.showLeftRail = $0 }
            ))
            .toggleStyle(.button)

            Toggle("R", isOn: Binding(
                get: { controlRoom.shell.showRightRail },
                set: { controlRoom.shell.showRightRail = $0 }
            ))
            .toggleStyle(.button)

            Toggle("T", isOn: Binding(
                get: { controlRoom.shell.showBottomTimeline },
                set: { controlRoom.shell.showBottomTimeline = $0 }
            ))
            .toggleStyle(.button)
        }
        .padding(10)
        .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 14) {
                Text("Session: \(controlRoom.transport.sessionId.isEmpty ? "none" : controlRoom.transport.sessionId)")
                Text("Endpoint: \(controlRoom.transport.endpointHost):\(controlRoom.transport.endpointPort)")
                Text(controlRoom.transport.bundlePath.isEmpty ? "Bundle: none" : "Bundle loaded")
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.70))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTitle("Mode + Model Slots")

            Stepper("Mode: \(mode)", value: $mode, in: 0...10)
                .onChange(of: mode) { _, newValue in
                    client.setMode(newValue)
                }
                .accessibilityIdentifier("control_room.mode_stepper")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                ForEach(0...10, id: \.self) { m in
                    Button("M\(m)") {
                        mode = m
                        client.setMode(m)
                    }
                    .buttonStyle(.bordered)
                    .tint(mode == m ? .green : .gray)
                }
            }

            Divider().background(Color.white.opacity(0.20))

            HStack {
                Text("Model Slots")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Button("+") { controlRoom.addModelSlot() }
                    .buttonStyle(.bordered)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(controlRoom.modelSlots.slots) { slot in
                        slotCard(slot)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .buttonStyle(.borderedProminent)
                .tint(isArmed ? .orange : .blue)
                .accessibilityIdentifier("control_room.slot_switch_\(slot.id.uuidString)")

                if controlRoom.modelSlots.slots.count > 1 {
                    Button("Remove") {
                        controlRoom.removeSlot(slot.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(8)
        .background((isActive ? Color.green.opacity(0.16) : Color.black.opacity(0.22)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isArmed ? Color.orange.opacity(0.9) : Color.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var centerStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTitle("Live Operations")

            HStack(spacing: 10) {
                Picker("Run profile", selection: $runProfile) {
                    ForEach(HarnessRunProfile.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Record Input Audio", isOn: $recordInputAudio)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("control_room.record_toggle")
            }

            HStack(spacing: 8) {
                if analyzer.inputDevices.isEmpty {
                    Text("Input: none detected")
                        .foregroundStyle(Color.orange)
                } else {
                    Picker("Input", selection: Binding(
                        get: { analyzer.selectedInputUID },
                        set: { setInputDevice(uid: $0) }
                    )) {
                        ForEach(analyzer.inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .frame(maxWidth: 340)
                }

                Button("Refresh Inputs") { analyzer.refreshInputDevices() }
                    .buttonStyle(.bordered)
                Spacer()
                Text("Active Input: \(analyzer.activeInputName)")
                    .foregroundStyle(Color.white.opacity(0.75))
            }

            HStack(spacing: 8) {
                Button("Jolt") { client.pulseJolt() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("j", modifiers: [.command])
                    .disabled(isReplayRunning)

                Button("Clear") { client.pulseClear() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("l", modifiers: [.command])
                    .disabled(isReplayRunning)

                Button("Send once") { client.sendOnce(mode: mode) }
                    .buttonStyle(.bordered)
                    .disabled(isReplayRunning)

                Divider().frame(height: 18)

                Button("Good") { client.setHumanLabel(.good) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("1", modifiers: [])
                Button("Too Much") { client.setHumanLabel(.tooMuch) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("2", modifiers: [])
                Button("Too Flat") { client.setHumanLabel(.tooFlat) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("3", modifiers: [])
                Button("Clear Label") { client.setHumanLabel(nil) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("0", modifiers: [])

                Spacer()
                Text("Label: \(client.currentLabel?.rawValue ?? "none")")
                    .foregroundStyle(Color.white.opacity(0.75))
            }

            Divider().background(Color.white.opacity(0.20))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Replay session_id", text: $replaySessionId)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("control_room.replay_session")
                    Button("Start Replay") { startReplaySession() }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(client.isRunning || isReplayRunning || replaySessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("control_room.replay_start")
                    Button("Stop Replay") { stopReplay() }
                        .buttonStyle(.bordered)
                        .disabled(!isReplayRunning)
                        .accessibilityIdentifier("control_room.replay_stop")
                }

                HStack(spacing: 8) {
                    TextField("Seek replay seconds", text: $replaySeekSeconds)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("control_room.replay_seek")
                    Button("Seek") { seekReplay() }
                        .buttonStyle(.bordered)
                        .disabled(!isReplayRunning || replaySeekSeconds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let replayStatus {
                    Text(replayStatus)
                        .foregroundStyle(Color.white.opacity(0.78))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                }
            }

            Divider().background(Color.white.opacity(0.20))

            HStack(spacing: 12) {
                metricCard("Sent", value: "\(client.sentCount)")
                metricCard("Recv", value: "\(client.recvCount)")
                metricCard("Timeout", value: "\(client.timeoutCount)")
                metricCard("Latency", value: client.lastLatencyMs.map { "\($0)ms" } ?? "na")
                metricCard("Tick", value: client.lastTickIntervalMs.map { String(format: "%.1fms", $0) } ?? "na")
                metricCard("AudioIn", value: analyzer.inputStatus.label)
            }

            if let reason = analyzer.fallbackReason {
                Text("Feature fallback: \(reason)")
                    .foregroundStyle(Color.orange)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }

            if let err = client.lastError {
                Text("Error: \(err)")
                    .foregroundStyle(Color(red: 0.94, green: 0.39, blue: 0.37))
            }

            if let out = client.lastOut {
                Text(roundTripLine(out))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(2)
            }

            if runProfile == .audioAndFeatures {
                Text(featuresLine(analyzer.latestFeatures))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(2)
            } else {
                Text("Features source: dummy (network-only proof mode)")
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            Divider().background(Color.white.opacity(0.20))

            VStack(alignment: .leading, spacing: 6) {
                Text("Control Room Event Log")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(controlRoom.events.prefix(30)) { event in
                            HStack(alignment: .top, spacing: 6) {
                                Text(timeString(event.timestamp))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .frame(width: 72, alignment: .leading)
                                Circle()
                                    .fill(event.severity.color)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                Text(event.message)
                                    .foregroundStyle(Color.white.opacity(0.88))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var rightRail: some View {
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
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            }

            TextEditor(text: Binding(
                get: { controlRoom.rubric.notes },
                set: { controlRoom.rubric.notes = $0 }
            ))
            .frame(minHeight: 180)
            .scrollContentBackground(.hidden)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }

            Button("Save Rubric Entry") {
                controlRoom.saveRubric(mode: mode, runProfile: runProfile)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityIdentifier("control_room.rubric_save")

            Spacer(minLength: 4)
        }
        .padding(10)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var bottomTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                panelTitle("Telemetry Timeline")
                Spacer()
                Toggle("Latency", isOn: Binding(get: { controlRoom.telemetry.showLatency }, set: { controlRoom.telemetry.showLatency = $0 }))
                    .toggleStyle(.button)
                Toggle("Tick", isOn: Binding(get: { controlRoom.telemetry.showTick }, set: { controlRoom.telemetry.showTick = $0 }))
                    .toggleStyle(.button)
                Toggle("Timeout", isOn: Binding(get: { controlRoom.telemetry.showTimeouts }, set: { controlRoom.telemetry.showTimeouts = $0 }))
                    .toggleStyle(.button)
                Toggle("Interventions", isOn: Binding(get: { controlRoom.telemetry.showInterventions }, set: { controlRoom.telemetry.showInterventions = $0 }))
                    .toggleStyle(.button)
                Toggle("Alignment", isOn: Binding(get: { controlRoom.telemetry.showAlignment }, set: { controlRoom.telemetry.showAlignment = $0 }))
                    .toggleStyle(.button)
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
            .foregroundStyle(Color.white.opacity(0.70))
        }
        .padding(10)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
    }

    private var shortcutLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("Space: Start/Stop")
            Text("Cmd+K: Command palette")
            Text("1/2/3/0: Label controls")
            Text("Cmd+J: Jolt")
            Text("Cmd+L: Clear")
            Spacer()
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 260)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
    }

    private var paletteActions: [CommandPaletteAction] {
        [
            CommandPaletteAction(id: "start_stop", title: client.isRunning ? "Stop Run" : "Start Run", subtitle: "Toggle live transport", keywords: ["transport", "run", "start", "stop"]),
            CommandPaletteAction(id: "jolt", title: "Pulse Jolt", subtitle: "Send momentary jolt control", keywords: ["jolt", "button"]),
            CommandPaletteAction(id: "clear", title: "Pulse Clear", subtitle: "Send momentary clear control", keywords: ["clear", "button"]),
            CommandPaletteAction(id: "replay_start", title: "Start Replay", subtitle: "Start replay for current session_id", keywords: ["replay", "start"]),
            CommandPaletteAction(id: "replay_stop", title: "Stop Replay", subtitle: "Cancel active replay", keywords: ["replay", "stop"]),
            CommandPaletteAction(id: "toggle_left", title: "Toggle Left Rail", subtitle: "Show/hide mode + model slots", keywords: ["panel", "left"]),
            CommandPaletteAction(id: "toggle_right", title: "Toggle Right Rail", subtitle: "Show/hide rubric workspace", keywords: ["panel", "right"]),
            CommandPaletteAction(id: "toggle_timeline", title: "Toggle Timeline", subtitle: "Show/hide telemetry timeline", keywords: ["panel", "timeline"])
        ]
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

    private func statusChip(label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((active ? Color.green.opacity(0.20) : Color.white.opacity(0.08)), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(active ? Color.green.opacity(0.82) : Color.white.opacity(0.16), lineWidth: 1)
            }
    }

    private func panelTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.87, green: 0.92, blue: 0.97))
    }

    private func metricCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.66))
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        analyzer.selectInputDevice(uid: uid)
        audio.selectInputDevice(uid: uid)
    }

    private func startSelectedProfile() {
        if isReplayRunning {
            stopReplay()
        }
        replayStatus = nil

        switch runProfile {
        case .networkOnly:
            analyzer.stop()
            audio.stop()
            client.featuresProvider = nil
            client.interventionsProvider = nil
            client.onModelOut = nil
            client.setMode(mode)
            client.startLoop(recordInputAudio: false, replayMode: false, replayedSessionId: nil)
            client.configureSessionInputAudio(sampleRate: 0, channels: 0, format: "caf", path: nil)
            client.setReplayAudioMissing(false)
            controlRoom.appendEvent("Started network-only run.", severity: .info)

        case .audioAndFeatures:
            analyzer.start()
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
            client.interventionsProvider = { [weak audio] in
                audio?.snapshotSafetyInterventions() ?? []
            }

            client.onModelOut = { [weak audio, modeEngine] out, _, sentButtons in
                guard let audio else { return }
                DispatchQueue.main.async {
                    let control = modeEngine.makeControl(out: out, sentButtons: sentButtons)
                    audio.apply(control: control)
                }
            }

            audio.start()
            client.setMode(mode)

            client.startLoop(
                recordInputAudio: recordInputAudio,
                replayMode: false,
                replayedSessionId: nil
            )
            client.setReplayContext(replayMode: false, replayedSessionId: nil)
            client.setReplayAudioMissing(false)

            if recordInputAudio, let path = client.inputAudioPath {
                do {
                    let info = try audio.startInputRecording(to: URL(fileURLWithPath: path), fileFormat: "caf")
                    client.configureSessionInputAudio(sampleRate: info.sampleRate, channels: info.channels, format: info.format, path: path)
                    controlRoom.appendEvent("Input audio recording enabled.", severity: .info)
                } catch {
                    replayStatus = "Input audio recording failed: \(error.localizedDescription)"
                    let inputInfo = audio.currentInputCaptureInfo()
                    client.configureSessionInputAudio(sampleRate: inputInfo.sampleRate, channels: inputInfo.channels, format: inputInfo.format, path: nil)
                    controlRoom.appendEvent("Input audio recording failed.", severity: .warning)
                }
            } else {
                let inputInfo = audio.currentInputCaptureInfo()
                client.configureSessionInputAudio(sampleRate: inputInfo.sampleRate, channels: inputInfo.channels, format: inputInfo.format, path: nil)
                controlRoom.appendEvent("Started live audio/features run.", severity: .info)
            }
        }
    }

    private func stopAll() {
        if isReplayRunning {
            stopReplay()
        }
        if let summary = audio.stopInputRecording() {
            client.configureSessionInputAudio(sampleRate: summary.sampleRate, channels: summary.channels, format: summary.fileFormat, path: summary.outputURL.path)
            if let alignment = summary.alignment {
                client.noteSessionAudioAlignment(hostTime: alignment.hostTime, sampleIndex: alignment.sampleIndex)
            }
        }
        client.stopLoop()
        audio.stop()
        analyzer.stop()

        if let sid = client.activeSessionId {
            replaySessionId = sid
        }
        if let p = client.logPath {
            replayPath = p
        }
        controlRoom.appendEvent("Run stopped.", severity: .info)
    }

    private func startReplaySession() {
        let sessionId = replaySessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { return }
        guard !isReplayRunning else { return }

        analyzer.stop()
        if client.isRunning {
            stopAll()
        }
        audio.start()

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
                } else {
                    audio.enableSilentReplayInputFallback()
                    client.setReplayAudioMissing(true)
                    print("{\"replay_audio_missing\":true,\"session_id\":\"\(sessionId)\"}")
                }

                let baseInterventions = hasAudio ? [String]() : ["replay_audio_missing"]
                let outURL = try TraceReplayer.replaySession(
                    session: session,
                    host: endpoint.host,
                    port: endpoint.port,
                    timeoutMs: 1_000,
                    timingProvider: hasAudio ? { audio.replayCurrentTimeSeconds() } : nil,
                    baseInterventions: baseInterventions,
                    shouldCancel: { token.isCancelled },
                    onFrameResult: { frame, modelOut in
                        let target = max(0, Double(frame.tsMs - startTs) / 1000.0)
                        let audioTime = audio.replayCurrentTimeSeconds()
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
                    audio.stopReplayInput(restoreLiveInput: true)
                    controlRoom.setReplayRunning(false)
                    controlRoom.setReplayStatus(replayStatus)
                    controlRoom.appendEvent("Replay completed.", severity: .info)
                }
            } catch TraceReplayError.cancelled {
                DispatchQueue.main.async {
                    isReplayRunning = false
                    replayCancelToken = nil
                    replayStatus = "Replay stopped."
                    audio.stopReplayInput(restoreLiveInput: true)
                    controlRoom.setReplayRunning(false)
                    controlRoom.setReplayStatus(replayStatus)
                    controlRoom.appendEvent("Replay cancelled.", severity: .warning)
                }
            } catch {
                DispatchQueue.main.async {
                    isReplayRunning = false
                    replayCancelToken = nil
                    replayStatus = "Replay failed: \(error.localizedDescription)"
                    audio.stopReplayInput(restoreLiveInput: true)
                    controlRoom.setReplayRunning(false)
                    controlRoom.setReplayStatus(replayStatus)
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
}
