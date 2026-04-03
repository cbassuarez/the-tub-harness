//
//  GestureBasedPageView.swift
//  TubCompanion
//
//  Gesture-driven page navigation: swipe between full-screen sections.
//  No visible tabs—navigation feels "magic" and seamless.
//

import SwiftUI

struct GestureBasedPageView<Content: View>: View {
    @State private var currentIndex: Int = 0
    @State private var dragOffset: CGFloat = 0
    
    let pages: [String]  // Section IDs
    let content: (Int) -> Content
    let onIndexChanged: ((Int) -> Void)?
    
    var body: some View {
        ZStack {
            Color(UIColor(named: "DarkBackground") ?? .black).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Section title (minimal, fades in/out)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LEARN")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        Text(pages[currentIndex].replacingOccurrences(of: "-", with: " ").uppercased())
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    
                    // Page indicator (subtle dots)
                    HStack(spacing: 4) {
                        ForEach(0..<pages.count, id: \.self) { idx in
                            Circle()
                                .fill(idx == currentIndex ? Color(UIColor(named: "GlyphGreen") ?? .green) : Color.white.opacity(0.2))
                                .frame(width: 6, height: 6)
                                .animation(.easeInOut(duration: 0.3), value: currentIndex)
                        }
                    }
                }
                .padding(16)
                .borderBottom(color: Color.white.opacity(0.1))
                
                // Content area (gesture-driven)
                ZStack {
                    ForEach(0..<pages.count, id: \.self) { idx in
                        if idx == currentIndex || idx == currentIndex + 1 || idx == currentIndex - 1 {
                            content(idx)
                                .offset(x: CGFloat(idx - currentIndex) * UIScreen.main.bounds.width + dragOffset)
                                .opacity(1 - abs(dragOffset) / UIScreen.main.bounds.width * 0.5)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            let threshold = UIScreen.main.bounds.width * 0.3
                            
                            if value.translation.width > threshold && currentIndex > 0 {
                                // Swiped right, go to previous
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentIndex -= 1
                                    dragOffset = 0
                                    onIndexChanged?(currentIndex)
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } else if value.translation.width < -threshold && currentIndex < pages.count - 1 {
                                // Swiped left, go to next
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentIndex += 1
                                    dragOffset = 0
                                    onIndexChanged?(currentIndex)
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } else {
                                // Snap back
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
            }
        }
    }
}

// MARK: - Preview

#Preview {
    GestureBasedPageView(
        pages: ["Quick Start", "What is", "Gesture Field"],
        content: { idx in
            VStack {
                Spacer()
                Text("Section \(idx)")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor(named: "DarkBackground") ?? .black))
        },
        onIndexChanged: { _ in }
    )
}
