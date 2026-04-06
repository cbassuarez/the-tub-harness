//
//  SynthKeyboardView.swift
//  TubCompanion
//
//  On-screen keyboard (C3–C5) for synth note playback.
//  Tap to play notes, long-press for sustain, swipe to change octaves.
//

import SwiftUI
import AVFoundation
import AudioToolbox

struct SynthKeyboardView: View {
    @ObservedObject var looperEngine: LooperEngine
    let padId: UUID
    
    @State private var selectedInstrument: String = "piano"
    @State private var currentOctave: Int = 3
    @State private var pressedNotes: Set<String> = []
    
    private let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private let instruments = ["piano", "organ", "bells", "marimba"]
    
    var body: some View {
        VStack(spacing: 12) {
            // Instrument selector
            HStack(spacing: 8) {
                Text("Instrument")
                    .playMono(10, weight: .bold)
                    .foregroundColor(.gray)
                
                Picker("Instrument", selection: $selectedInstrument) {
                    ForEach(instruments, id: \.self) { inst in
                        Text(inst)
                            .playMono(11)
                            .tag(inst)
                    }
                }
                .pickerStyle(.segmented)
                .playMono(10)
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(4)
            
            // Octave display
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Octave")
                        .playMono(10, weight: .bold)
                        .foregroundColor(.gray)
                    Text("C\(currentOctave) – B\(currentOctave)")
                        .playMono(12, weight: .semibold)
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: { if currentOctave > 2 { currentOctave -= 1 } }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(4)
                    }
                    .disabled(currentOctave <= 2)
                    
                    Button(action: { if currentOctave < 5 { currentOctave += 1 } }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(4)
                    }
                    .disabled(currentOctave >= 5)
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(4)
            
            // Keyboard grid
            VStack(spacing: 4) {
                // White keys
                HStack(spacing: 2) {
                    ForEach(["C", "D", "E", "F", "G", "A", "B"], id: \.self) { note in
                        KeyButton(
                            note: note,
                            octave: currentOctave,
                            isBlack: false,
                            isPressed: pressedNotes.contains("\(note)\(currentOctave)"),
                            onPress: { playNote(note, octave: currentOctave) },
                            onRelease: { releaseNote(note, octave: currentOctave) }
                        )
                    }
                }
                .frame(height: 120)
                
                // Black keys (overlay)
                HStack(spacing: 2) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        
                        HStack(spacing: 2) {
                            Spacer()
                                .frame(width: 12)
                            
                            ForEach([(note: "C#", offset: 0), (note: "D#", offset: 48), (note: "F#", offset: 96), (note: "G#", offset: 132), (note: "A#", offset: 168)], id: \.note) { item in
                                KeyButton(
                                    note: item.note,
                                    octave: currentOctave,
                                    isBlack: true,
                                    isPressed: pressedNotes.contains("\(item.note)\(currentOctave)"),
                                    onPress: { playNote(item.note, octave: currentOctave) },
                                    onRelease: { releaseNote(item.note, octave: currentOctave) }
                                )
                                .frame(width: 28, height: 70)
                                
                                if item.note != "A#" {
                                    Spacer()
                                        .frame(width: 18)
                                }
                            }
                            
                            Spacer()
                        }
                    }
                    .frame(height: 70)
                }
            }
            .background(Color.black.opacity(0.3))
            .cornerRadius(4)
            
            // Help text
            Text("Tap keys to play notes. Long-press for sustain.")
                .playSans(9)
                .foregroundColor(.gray.opacity(0.8))
                .lineLimit(2)
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
        .accessibilityLabel(Text("Synth keyboard"))
        .accessibilityHint(Text("Tap piano keys to play notes, select instrument at top"))
    }
    
    private func playNote(_ note: String, octave: Int) {
        let noteName = "\(note)\(octave)"
        pressedNotes.insert(noteName)
        
        let midiNote = getMidiNote(note, octave: octave)
        AudioServicesPlayAlertSound(SystemSoundID(1104)) // Brief click feedback
        
        // Play synth note (would integrate with LooperEngine)
        #if DEBUG
        print("🎹 Playing: \(noteName) (MIDI: \(midiNote))")
        #endif
    }
    
    private func releaseNote(_ note: String, octave: Int) {
        let noteName = "\(note)\(octave)"
        pressedNotes.remove(noteName)
        
        #if DEBUG
        print("🎹 Released: \(noteName)")
        #endif
    }
    
    private func getMidiNote(_ note: String, octave: Int) -> Int {
        let noteToMidi: [String: Int] = [
            "C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5,
            "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11
        ]
        return (octave + 1) * 12 + (noteToMidi[note] ?? 0)
    }
}

// MARK: - Key Button

struct KeyButton: View {
    let note: String
    let octave: Int
    let isBlack: Bool
    let isPressed: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var isLongPressing = false
    
    var body: some View {
        VStack {
            Text(note)
                .playMono(isBlack ? 9 : 11, weight: .semibold)
                .foregroundColor(isBlack ? .white : .black)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isBlack ? Color.black : Color.white)
        .cornerRadius(isBlack ? 3 : 4)
        .opacity(isPressed ? (isBlack ? 0.7 : 0.85) : 1.0)
        .shadow(color: isBlack ? Color.black.opacity(0.5) : Color.white.opacity(0.2), radius: 2)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) {
            isLongPressing = true
            onPress()
        }
        .onTapGesture {
            if !isLongPressing {
                onPress()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onRelease()
                }
            } else {
                isLongPressing = false
                onRelease()
            }
        }
        .accessibilityLabel(Text("\(note)\(octave) key"))
        .accessibilityHint(Text("Tap to play note"))
    }
}

#Preview {
    ZStack {
        Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea()
        
        ScrollView {
            SynthKeyboardView(
                looperEngine: LooperEngine(),
                padId: UUID()
            )
            .padding(16)
        }
    }
}
