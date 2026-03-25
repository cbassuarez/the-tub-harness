import SwiftUI

private enum HarnessRunProfile: String, CaseIterable, Identifiable {
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

struct ContentView: View {
    @StateObject private var client = TubMLClient(host: "127.0.0.1", port: 9910)

    @StateObject private var audio = AudioEngineController()
    @StateObject private var analyzer = AudioInputAnalyzer()
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

    init(defaultRecordInputAudio: Bool = false) {
        _recordInputAudio = State(initialValue: defaultRecordInputAudio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ML UDP")
                    .font(.headline)

                Spacer()

                Circle()
                    .fill(client.isReady ? Color.green : Color.red)
                    .frame(width: 10, height: 10)

                Text(client.isReady ? "READY" : "NOT READY")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Run profile", selection: $runProfile) {
                ForEach(HarnessRunProfile.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Record Input Audio (CAF)", isOn: $recordInputAudio)
                .toggleStyle(.switch)

            HStack(spacing: 10) {
                if analyzer.inputDevices.isEmpty {
                    Text("Input: none detected")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Picker(
                        "Input",
                        selection: Binding(
                            get: { analyzer.selectedInputUID },
                            set: { setInputDevice(uid: $0) }
                        )
                    ) {
                        ForEach(analyzer.inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .frame(maxWidth: 360)
                }

                Button("Refresh Inputs") {
                    analyzer.refreshInputDevices()
                }

                Text("Selected: \(analyzer.activeInputName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Stepper("Mode: \(mode)", value: $mode, in: 0...10)
                    .onChange(of: mode) { _, newValue in
                        client.setMode(newValue)
                    }

                Button("Jolt") {
                    client.pulseJolt()
                }

                Button("Clear") {
                    client.pulseClear()
                }
            }

            HStack(spacing: 8) {
                Text("Label:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Good") { client.setHumanLabel(.good) }
                    .keyboardShortcut("1", modifiers: [])
                Button("Too Much") { client.setHumanLabel(.tooMuch) }
                    .keyboardShortcut("2", modifiers: [])
                Button("Too Flat") { client.setHumanLabel(.tooFlat) }
                    .keyboardShortcut("3", modifiers: [])
                Button("Clear Label") { client.setHumanLabel(nil) }
                    .keyboardShortcut("0", modifiers: [])
                Text("Current: \(client.currentLabel?.rawValue ?? "none")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(client.isRunning ? "Stop" : "Start") {
                    if client.isRunning {
                        stopAll()
                    } else {
                        startSelectedProfile()
                    }
                }
                .disabled(isReplayRunning)

                Button("Send once") {
                    client.sendOnce(mode: mode)
                }
                .disabled(isReplayRunning)

                if let sid = client.activeSessionId {
                    Button("Use Last Session") {
                        replaySessionId = sid
                    }
                }

                Spacer()

                if let p = client.logPath {
                    Text(p)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                if let eventPath = client.eventLogPath {
                    Text("Events: \(eventPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let bundlePath = client.bundlePath {
                    Text("Bundle: \(bundlePath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                if let metaPath = client.sessionMetaPath {
                    Text("Session Meta: \(metaPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let audioPath = client.inputAudioPath {
                    Text("Input Audio: \(audioPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                TextField("Replay session_id", text: $replaySessionId)
                    .textFieldStyle(.roundedBorder)
                Button("Start Replay") {
                    startReplaySession()
                }
                .disabled(client.isRunning || isReplayRunning || replaySessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop Replay") {
                    stopReplay()
                }
                .disabled(!isReplayRunning)
            }

            HStack(spacing: 10) {
                TextField("Seek seconds (optional)", text: $replaySeekSeconds)
                    .textFieldStyle(.roundedBorder)
                Button("Seek Replay") {
                    seekReplay()
                }
                .disabled(!isReplayRunning || replaySeekSeconds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let replayStatus {
                Text(replayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Sent: \(client.sentCount)")
                Text("Recv: \(client.recvCount)")
                Text("Timeout: \(client.timeoutCount)")
                if let ms = client.lastLatencyMs {
                    Text("Latency: \(ms)ms")
                }
                if let tick = client.lastTickIntervalMs {
                    Text(String(format: "Tick: %.1fms", tick))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("AudioIn: \(analyzer.inputStatus.label)")
                .font(.caption)
                .foregroundStyle(analyzer.inputStatus == .running ? Color.secondary : Color.orange)

            if let reason = analyzer.fallbackReason {
                Text("Feature fallback: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let err = client.lastError {
                Text("Error: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let out = client.lastOut {
                Text(roundTripLine(out))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if runProfile == .audioAndFeatures {
                Text(featuresLine(analyzer.latestFeatures))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Features source: dummy (network-only proof mode)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .onAppear {
            client.setMode(mode)
            analyzer.refreshInputDevices()
            audio.onInputRecordingAlignment = { alignment in
                client.noteSessionAudioAlignment(
                    hostTime: alignment.hostTime,
                    sampleIndex: alignment.sampleIndex
                )
            }
        }
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
                    client.configureSessionInputAudio(
                        sampleRate: info.sampleRate,
                        channels: info.channels,
                        format: info.format,
                        path: path
                    )
                } catch {
                    replayStatus = "Input audio recording failed: \(error.localizedDescription)"
                    let inputInfo = audio.currentInputCaptureInfo()
                    client.configureSessionInputAudio(
                        sampleRate: inputInfo.sampleRate,
                        channels: inputInfo.channels,
                        format: inputInfo.format,
                        path: nil
                    )
                }
            } else {
                let inputInfo = audio.currentInputCaptureInfo()
                client.configureSessionInputAudio(
                    sampleRate: inputInfo.sampleRate,
                    channels: inputInfo.channels,
                    format: inputInfo.format,
                    path: nil
                )
            }
        }
    }

    private func stopAll() {
        if isReplayRunning {
            stopReplay()
        }
        if let summary = audio.stopInputRecording() {
            client.configureSessionInputAudio(
                sampleRate: summary.sampleRate,
                channels: summary.channels,
                format: summary.fileFormat,
                path: summary.outputURL.path
            )
            if let alignment = summary.alignment {
                client.noteSessionAudioAlignment(
                    hostTime: alignment.hostTime,
                    sampleIndex: alignment.sampleIndex
                )
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

        let endpoint = client.modelEndpoint()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let session = try ReplaySessionLoader.load(sessionId: sessionId)
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
                }
            } catch TraceReplayError.cancelled {
                DispatchQueue.main.async {
                    isReplayRunning = false
                    replayCancelToken = nil
                    replayStatus = "Replay stopped."
                    audio.stopReplayInput(restoreLiveInput: true)
                }
            } catch {
                DispatchQueue.main.async {
                    isReplayRunning = false
                    replayCancelToken = nil
                    replayStatus = "Replay failed: \(error.localizedDescription)"
                    audio.stopReplayInput(restoreLiveInput: true)
                }
            }
        }
    }

    private func stopReplay() {
        guard isReplayRunning else { return }
        replayStatus = "Stopping replay..."
        replayCancelToken?.cancel()
    }

    private func seekReplay() {
        guard isReplayRunning else { return }
        guard let seconds = Double(replaySeekSeconds.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite else {
            replayStatus = "Seek value must be a number."
            return
        }
        do {
            try audio.seekReplayInput(to: max(0, seconds))
            replayStatus = "Replay seeked to \(String(format: "%.2f", max(0, seconds)))s."
        } catch {
            replayStatus = "Replay seek failed: \(error.localizedDescription)"
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
