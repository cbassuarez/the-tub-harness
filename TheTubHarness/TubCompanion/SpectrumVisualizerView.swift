//
//  SpectrumVisualizerView.swift
//  TubCompanion
//
//  Animated frequency spectrum, onset detection, pitch visualization.
//  Shows what THE TUB "hears" in real time (stylized, not literal).
//

import SwiftUI

struct SpectrumVisualizerView: View {
    @State private var spectrumBars: [CGFloat] = Array(repeating: 0.3, count: 12)
    @State private var onsetPeaks: [CGFloat] = Array(repeating: 0.0, count: 3)
    
    var body: some View {
        VStack(spacing: 24) {
            Text("What We Hear")
                .playSans(18, weight: .semibold)
                .foregroundColor(.white)
            
            // Frequency spectrum
            VStack(spacing: 16) {
                Text("Frequency Response")
                    .playSans(11, weight: .semibold)
                    .foregroundColor(.gray)
                
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.02))
                        .border(Color.white.opacity(0.1), width: 1)
                    
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(0..<spectrumBars.count, id: \.self) { idx in
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color(UIColor(named: "AberrationCyan") ?? .cyan),
                                                Color(UIColor(named: "GlyphGreen") ?? .green)
                                            ]),
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(height: spectrumBars[idx] * 60)
                                
                                Text("\(idx * 2)k")
                                    .playMono(7)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(height: 100)
            }
            
            // Onset detection
            VStack(spacing: 16) {
                Text("Onset Detection (Sudden Changes)")
                    .playSans(11, weight: .semibold)
                    .foregroundColor(.gray)
                
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.02))
                        .border(Color.white.opacity(0.1), width: 1)
                    
                    HStack(alignment: .center, spacing: 12) {
                        ForEach(0..<onsetPeaks.count, id: \.self) { idx in
                            VStack(spacing: 0) {
                                ZStack {
                                    Circle()
                                        .fill(Color(UIColor(named: "AberrationMagenta") ?? .magenta).opacity(0.2))
                                        .frame(width: 40, height: 40)
                                    
                                    Circle()
                                        .fill(Color(UIColor(named: "AberrationMagenta") ?? .magenta))
                                        .frame(width: max(8, onsetPeaks[idx] * 30), height: max(8, onsetPeaks[idx] * 30))
                                        .scaleEffect(onsetPeaks[idx] > 0.5 ? 1.2 : 1.0)
                                        .animation(
                                            Animation.easeOut(duration: 0.3)
                                                .repeatForever(autoreverses: true),
                                            value: onsetPeaks[idx]
                                        )
                                }
                                
                                Text("Peak \(idx + 1)")
                                    .playMono(8)
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(12)
                }
                .frame(height: 80)
            }
            
            Text("THE TUB analyzes loudness, energy, spectral content, and sudden changes in real time.")
                .playSans(10)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .padding(16)
        .onAppear {
            animateSpectrum()
            animateOnsets()
        }
    }
    
    private func animateSpectrum() {
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                for idx in 0..<spectrumBars.count {
                    spectrumBars[idx] = CGFloat.random(in: 0.2...0.9)
                }
            }
        }
    }
    
    private func animateOnsets() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            withAnimation(.easeOut(duration: 0.4)) {
                for idx in 0..<onsetPeaks.count {
                    onsetPeaks[idx] = CGFloat.random(in: 0.3...1.0)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SpectrumVisualizerView()
        .background(Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea())
}
