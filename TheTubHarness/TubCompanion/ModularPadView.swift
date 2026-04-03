//
//  ModularPadView.swift
//  TubCompanion
//
//  4-track modular pad grid with independent playback, volume, and mode control.
//  2x2 layout with waveform preview, status indicators, and mode selector per pad.
//

import SwiftUI

struct ModularPadView: View {
    @ObservedObject var looperEngine: LooperEngine
    @ObservedObject var harnessClient: HarnessClient
    
    let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        VStack(spacing: 12) {
            Text("MODULAR PADS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(looperEngine.pads.enumerated()), id: \.element.id) { index, pad in
                    PadControlView(
                        looperEngine: looperEngine,
                        harnessClient: harnessClient,
                        pad: pad,
                        padIndex: index
                    )
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
    }
}

// MARK: - Pad Control View

struct PadControlView: View {
    @ObservedObject var looperEngine: LooperEngine
    @ObservedObject var harnessClient: HarnessClient
    let pad: LooperPad
    let padIndex: Int
    
    @State private var showModeMenu = false
    @State private var showSynthKeyboard = false
    @State private var showingFilePicker = false
    @State private var showingSoundBank = false
    
    var statusColor: Color {
        switch pad.playbackState {
        case .empty:
            return .gray.opacity(0.5)
        case .playing:
            return Color(UIColor(named: "GlyphGreen") ?? .green)
        case .paused:
            return Color(UIColor(named: "WarningYellow") ?? .yellow)
        case .recording:
            return .red
        }
    }
    
    var statusIcon: String {
        switch pad.playbackState {
        case .empty:
            return "circle"
        case .playing:
            return "play.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .recording:
            return "record.circle.fill"
        }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            // Header: Mode + Status
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PAD \(padIndex + 1)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Text(pad.mode.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
                    .accessibilityLabel(Text("Status: \(pad.playbackState)"))
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(4)
            
            // Waveform preview
            if let peaks = pad.audioBuffer != nil ? pad.waveformPeaks : nil, !peaks.isEmpty {
                VStack(spacing: 4) {
                    HStack(spacing: 1) {
                        ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color(UIColor(named: "GlyphGreen") ?? .green).opacity(Double(peak)))
                                .frame(height: CGFloat(peak) * 24)
                        }
                    }
                    .frame(height: 24)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(3)
                    
                    Text("\(Int(pad.duration))s")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.gray)
                }
            } else {
                ZStack {
                    Color.black.opacity(0.2)
                        .cornerRadius(3)
                    
                    VStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("Empty")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                }
                .frame(height: 42)
            }
            
            // Volume slider
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                    
                    Slider(value: Binding(
                        get: { Double(pad.volume) },
                        set: { looperEngine.setPadVolume(pad.id, volume: Float($0)) }
                    ), in: 0...1)
                    .font(.system(size: 11, design: .monospaced))
                    
                    Text("\(Int(pad.volume * 100))%")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 28)
                }
                
                Text("VOL")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Control buttons
            HStack(spacing: 6) {
                // Play/Pause
                Button(action: { looperEngine.playPad(pad.id) }) {
                    Image(systemName: pad.playbackState == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(pad.playbackState == .playing ? Color(UIColor(named: "WarningYellow") ?? .yellow) : Color(UIColor(named: "GlyphGreen") ?? .green))
                        .cornerRadius(4)
                }
                .accessibilityLabel(Text("Play/pause"))
                
                // Mode selector
                Menu {
                    Button(action: { changePadMode(to: .synth(instrument: "piano")) }) {
                        Label("🎹 Synth", systemImage: "waveform.circle")
                    }
                    Button(action: {
                        // Present file picker to choose audio file
                        showingFilePicker = true
                    }) {
                        Label("📁 File", systemImage: "doc.audio")
                    }
                    Button(action: { changePadMode(to: .mic(isRecording: false)) }) {
                        Label("🎤 Mic", systemImage: "mic")
                    }
                    Button(action: {
                        // Present sound bank browser
                        showingSoundBank = true
                    }) {
                        Label("🔊 Bank", systemImage: "waveform.circle.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(4)
                }
                .accessibilityLabel(Text("Mode menu"))
                
                // Delete
                Button(action: { clearPad(pad.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
                .disabled(pad.playbackState == .empty)
                .accessibilityLabel(Text("Clear pad"))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .borderLeading(color: statusColor, width: 3)
        .cornerRadius(6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Pad \(padIndex + 1)"))
        .accessibilityValue(Text(pad.mode.displayName))
        // Present file picker sheet
        .sheet(isPresented: $showingFilePicker) {
            FileBrowserView { url in
                showingFilePicker = false
                Task {
                    let ok = await looperEngine.loadFile(url: url, into: pad.id)
                    if ok {
                        // update pad mode to file
                        if let index = looperEngine.pads.firstIndex(where: { $0.id == pad.id }) {
                            var updated = looperEngine.pads[index]
                            updated.mode = .file(fileName: url.lastPathComponent, sourcePath: url.path)
                            looperEngine.pads[index] = updated
                        }
                    }
                }
            }
        }
        // Present sound bank browser sheet
        .sheet(isPresented: $showingSoundBank) {
            SoundBankBrowserView(harnessClient: harnessClient) { contribution in
                showingSoundBank = false
                // download then load
                harnessClient.downloadContribution(contributionId: contribution.contributionId) { url in
                    guard let url = url else { return }
                    Task {
                        let ok = await looperEngine.loadFile(url: url, into: pad.id)
                        if ok {
                            if let index = looperEngine.pads.firstIndex(where: { $0.id == pad.id }) {
                                var updated = looperEngine.pads[index]
                                updated.mode = .soundBank(contributionId: contribution.contributionId, contributor: contribution.sessionId)
                                looperEngine.pads[index] = updated
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func changePadMode(to newMode: PadMode) {
        var updatedPad = pad
        updatedPad.mode = newMode
        
        if let index = looperEngine.pads.firstIndex(where: { $0.id == pad.id }) {
            looperEngine.pads[index] = updatedPad
        }
        
        // Show synth keyboard if switching to synth mode
        if case .synth = newMode {
            showSynthKeyboard = true
        }
    }
    
    private func clearPad(_ padId: UUID) {
        if let index = looperEngine.pads.firstIndex(where: { $0.id == padId }) {
            var updatedPad = looperEngine.pads[index]
            updatedPad.audioBuffer = nil
            updatedPad.playbackState = .empty
            updatedPad.waveformPeaks = []
            looperEngine.pads[index] = updatedPad
        }
    }
}

// MARK: - Border Left Helper

extension View {
    func borderLeading(color: Color, width: CGFloat = 1) -> some View {
        self.overlay(
            VStack {
                Rectangle()
                    .fill(color)
                    .frame(width: width)
                Spacer()
            },
            alignment: .leading
        )
    }
}

#Preview {
    ZStack {
        Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea()
        
        ScrollView {
            ModularPadView(looperEngine: LooperEngine(), harnessClient: HarnessClient())
                .padding(16)
        }
    }
}
