//
//  GestureAnimationView.swift
//  TubCompanion
//
//  Visual representations of gesture vocabulary: drag, hold, tap.
//  Animated arrows, pulsing circles, touch indicators.
//

import SwiftUI

// MARK: - Drag Gesture Animation

struct DragGestureAnimation: View {
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Drag to Steer")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            ZStack {
                // Field background
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.02))
                    .border(Color.white.opacity(0.1), width: 1)
                
                VStack(spacing: 16) {
                    Text("← Drag toward any word →")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    // Animated arrow
                    HStack {
                        Spacer()
                        
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { idx in
                                Text("→")
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                                    .offset(x: isAnimating ? CGFloat(idx) * 4 : 0)
                                    .animation(
                                        Animation.easeInOut(duration: 0.6)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(idx) * 0.1),
                                        value: isAnimating
                                    )
                            }
                        }
                        .padding(.trailing, 24)
                    }
                    
                    Text("Guides the system toward your preferred direction")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .frame(height: 140)
            
            Spacer()
        }
        .padding(16)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Hold Gesture Animation

struct HoldGestureAnimation: View {
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Hold to Reinforce")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            ZStack {
                // Field background
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.02))
                    .border(Color.white.opacity(0.1), width: 1)
                
                VStack(spacing: 16) {
                    Text("Press & Hold")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    // Pulsing circle
                    ZStack {
                        // Outer pulse
                        Circle()
                            .stroke(Color(UIColor(named: "GlyphGreen") ?? .green).opacity(0.2), lineWidth: 1)
                            .frame(width: 80, height: 80)
                            .scaleEffect(isAnimating ? 1.3 : 1.0)
                            .opacity(isAnimating ? 0 : 0.5)
                            .animation(
                                Animation.easeOut(duration: 1.0)
                                    .repeatForever(autoreverses: false),
                                value: isAnimating
                            )
                        
                        // Inner circle
                        Circle()
                            .fill(Color(UIColor(named: "GlyphGreen") ?? .green))
                            .frame(width: 50, height: 50)
                            .scaleEffect(isAnimating ? 1.1 : 1.0)
                            .animation(
                                Animation.easeInOut(duration: 0.8)
                                    .repeatForever(autoreverses: true),
                                value: isAnimating
                            )
                    }
                    
                    Text("Reinforces current state with intensity")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .frame(height: 160)
            
            Spacer()
        }
        .padding(16)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Tap Gesture Animation

struct TapGestureAnimation: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("More & Less")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.02))
                    .border(Color.white.opacity(0.1), width: 1)
                
                HStack(spacing: 24) {
                    // Less button
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.05))
                            .border(Color(UIColor(named: "GlyphGreen") ?? .green), width: 1)
                            .overlay(
                                Text("−")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                            )
                            .frame(height: 50)
                        
                        Text("Less")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                    
                    // More button
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.05))
                            .border(Color(UIColor(named: "GlyphGreen") ?? .green), width: 1)
                            .overlay(
                                Text("+")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                            )
                            .frame(height: 50)
                        
                        Text("More")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .padding(20)
            }
            .frame(height: 110)
            
            Text("Quick intensity adjustments without dragging")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Preview

#Preview("Drag Animation") {
    DragGestureAnimation()
        .background(Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea())
}

#Preview("Hold Animation") {
    HoldGestureAnimation()
        .background(Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea())
}

#Preview("Tap Animation") {
    TapGestureAnimation()
        .background(Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea())
}
