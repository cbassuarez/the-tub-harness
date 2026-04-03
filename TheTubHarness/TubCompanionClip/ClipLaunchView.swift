//
//  ClipLaunchView.swift
//  TubCompanionClip
//
//  App Clip entry point.
//  Handles deep-link URL parsing, NFC tap detection, and handoff to full app.
//  Target: <15 seconds from tap to field.
//

import SwiftUI
#if canImport(CoreNFC)
import CoreNFC
#endif

struct ClipLaunchView: View {
    @State private var detectedSessionId: String?
    @State private var clipStep: ClipStep = .initializing
    @State private var nfcSession: NFCNDEFReaderSession?
    @State private var connectionStateString: String = "disconnected"
    
    enum ClipStep {
        case initializing
        case readingNFC
        case parsing
        case connecting
        case ready
        case error(String)
    }
    
    var body: some View {
        ZStack {
            Color(UIColor(named: "DarkBackground") ?? .black)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("THE TUB")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                    
                    Text("App Clip • Gallery Experience")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .padding(.top, 32)
                
                Spacer()
                
                // Step-based content
                VStack(spacing: 20) {
                    switch clipStep {
                    case .initializing:
                        initializingContent
                    case .readingNFC:
                        readingNFCContent
                    case .parsing:
                        parsingContent
                    case .connecting:
                        connectingContent
                    case .ready:
                        readyContent
                    case .error(let msg):
                        errorContent(msg)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .onAppear {
            handleAppearance()
        }
    }
    
    // MARK: - Step Views
    
    @ViewBuilder
    var initializingContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 40))
                .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green).opacity(0.7))
            
            Text("Tap to NFC Tag")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            Text("Hold your phone against the cable.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }
    
    @ViewBuilder
    var readingNFCContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
                .opacity(0.8)
            
            Text("Reading NFC Tag...")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            ProgressView()
                .scaleEffect(0.8)
                .tint(Color(UIColor(named: "GlyphGreen") ?? .green))
        }
    }
    
    @ViewBuilder
    var parsingContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
            
            Text("Parsing Session...")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            if let sessionId = detectedSessionId {
                Text("Session: \(sessionId.prefix(8))...")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
    
    @ViewBuilder
    var connectingContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green).opacity(0.7))
            
            Text("Connecting to Harness...")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            ProgressView()
                .scaleEffect(0.8)
                .tint(Color(UIColor(named: "GlyphGreen") ?? .green))
        }
    }
    
    @ViewBuilder
    var readyContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(Color(UIColor(named: "GlyphGreen") ?? .green))
            
            Text("Ready to Participate")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            if let sessionId = detectedSessionId {
                Text(sessionId)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            
            VStack(spacing: 12) {
                Button(action: { handoffToFullApp() }) {
                    Text("Open Full App")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Color(UIColor(named: "GlyphGreen") ?? .green))
                        .cornerRadius(4)
                }
                
                Text("Or continue in App Clip →")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(.top, 8)
        }
    }
    
    @ViewBuilder
    func errorContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(Color(UIColor(named: "WarningYellow") ?? .yellow))
            
            Text("Connection Error")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            Text(message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            Button(action: { clipStep = .initializing }) {
                Text("Try Again")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(UIColor(named: "GlyphGreen") ?? .green))
                    .cornerRadius(4)
            }
        }
    }
    
    // MARK: - State Management
    
    private func handleAppearance() {
        // Check if we were invoked via deep link with URL
        if let url = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first })
            .first?.windowScene?.userActivity?.webpageURL {
            parseDeepLinkURL(url)
        } else {
            // No deep link; prompt for NFC
            startNFCSession()
        }
    }
    
    private func parseDeepLinkURL(_ url: URL) {
        clipStep = .parsing
        
        // Extract session ID from URL query params
        // Expected format: cbassuarez.github.io/thetub?session=<session-id>
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let sessionId = components.queryItems?.first(where: { $0.name == "session" })?.value {
            detectedSessionId = sessionId
            beginConnection()
        } else {
            // Try NFC fallback
            startNFCSession()
        }
    }
    
    private func startNFCSession() {
        // NFC scaffolding: CoreNFC integration
        // In production, would:
        // 1. Check NFCNDEFReaderSession.readingAvailable
        // 2. Create session with NFCNDEFReaderSession(delegate: self, queue: .main)
        // 3. Parse NDEF message for session ID
        // 4. Call parseNFCMessage(records)
        
        // For now, show prompt and wait for manual entry fallback
        clipStep = .readingNFC
        
        // Stub: Auto-advance after 5 seconds to show fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            clipStep = .initializing
        }
    }
    
    private func parseNFCMessage(records: [Any]) {
        // Simplified NFC parser fallback: if we can extract Data or String from records, try to parse
        for record in records {
            if let dict = record as? [String: Any], let payload = dict["payload"] as? Data, let text = String(data: payload, encoding: .utf8) {
                detectedSessionId = extractSessionId(from: text)
                beginConnection()
                return
            } else if let text = record as? String {
                detectedSessionId = extractSessionId(from: text)
                beginConnection()
                return
            }
        }
    }
    
    private func extractSessionId(from text: String) -> String {
        // Try to extract UUID-like session ID from text
        if text.contains("session=") {
            return text.components(separatedBy: "session=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func beginConnection() {
        clipStep = .connecting
        
        // Stub: Simulate connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Advance to ready; connection state tracked separately for full app
            clipStep = .ready
        }
    }
    
    private func handoffToFullApp() {
        // Open full app with session ID in URL
        let deepLinkURL = URL(string: "thetub-companion://session/\(detectedSessionId ?? "unknown")")
        if let url = deepLinkURL, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    ClipLaunchView()
}
