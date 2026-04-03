//
//  StateMachineView.swift
//  TubCompanion
//
//  Queue state machine visualization: inbox → cooldown → normalizing → approved/rejected.
//

import SwiftUI

struct StateMachineView: View {
    @State private var activeState = 0
    
    let states = ["Inbox", "Cooldown", "Normalizing", "Approved"]
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Audio Queue States")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            Text("Your audio contributions flow through several states before being admitted to the live system.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
            
            // State flow diagram
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.02))
                    .border(Color.white.opacity(0.1), width: 1)
                
                VStack(spacing: 12) {
                    // Row 1: Inbox → Cooldown
                    HStack(spacing: 0) {
                        StateBox(label: "Inbox", isActive: activeState == 0)
                        Arrow()
                        StateBox(label: "Cooldown", isActive: activeState == 1)
                        Arrow()
                        StateBox(label: "Normalizing", isActive: activeState == 2)
                        Arrow()
                        StateBox(label: "Approved", isActive: activeState >= 3)
                    }
                    
                    Spacer()
                        .frame(height: 16)
                    
                    // Explanation
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(UIColor(named: "GlyphGreen") ?? .green))
                                    .frame(width: 6, height: 6)
                                Text("Admitted")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 6, height: 6)
                                Text("Waiting")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        Spacer()
                    }
                }
                .padding(16)
            }
            .frame(height: 120)
            
            // State descriptions
            VStack(spacing: 12) {
                StateDescription(state: "Inbox", description: "Your audio enters the queue")
                StateDescription(state: "Cooldown", description: "System ensures spacing between contributions")
                StateDescription(state: "Normalizing", description: "Audio is processed for safe levels")
                StateDescription(state: "Approved", description: "Admitted to live system")
            }
            
            Spacer()
        }
        .padding(16)
        .onAppear {
            animateStates()
        }
    }
    
    private func animateStates() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.6)) {
                activeState = (activeState + 1) % 4
            }
        }
    }
}

// MARK: - Helper Components

struct StateBox: View {
    let label: String
    let isActive: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isActive
                        ? Color(UIColor(named: "GlyphGreen") ?? .green).opacity(0.2)
                        : Color.white.opacity(0.05)
                )
                .border(
                    isActive
                        ? Color(UIColor(named: "GlyphGreen") ?? .green)
                        : Color.white.opacity(0.1),
                    width: 1
                )
                .overlay(
                    Text(label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(isActive ? Color(UIColor(named: "GlyphGreen") ?? .green) : .gray)
                )
                .frame(height: 40)
        }
    }
}

struct Arrow: View {
    var body: some View {
        HStack(spacing: 2) {
            Text("→")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
    }
}

struct StateDescription: View {
    let state: String
    let description: String
    
    var body: some View {
        HStack(spacing: 8) {
            Text(state)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                .frame(width: 70, alignment: .leading)
            
            Text(description)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
            
            Spacer()
        }
        .padding(8)
        .background(Color.white.opacity(0.02))
        .cornerRadius(4)
    }
}

// MARK: - Preview

#Preview {
    StateMachineView()
        .background(Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea())
}
