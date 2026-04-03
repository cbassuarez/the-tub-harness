//
//  AudienceBodyClaimResolver.swift
//  TheTubHarness
//
//  Matches active audience sessions to nearest Kinect body.
//  Uses stub/provider pattern for compatibility with and without real Kinect hardware.
//

import Foundation
import CoreGraphics

protocol KinectBodyProvider {
    func getActiveBodies() -> [KinectBodyData]
    func getNearestBody(to position: CGPoint) -> KinectBodyData?
}

class StubKinectBodyProvider: KinectBodyProvider {
    func getActiveBodies() -> [KinectBodyData] {
        return [
            KinectBodyData(bodyIndex: 0, position: CGPoint(x: 960, y: 540), depthZ: 2.5, confidence: 0.9, isTracked: true),
            KinectBodyData(bodyIndex: 1, position: CGPoint(x: 300, y: 400), depthZ: 3.2, confidence: 0.7, isTracked: true),
        ]
    }
    
    func getNearestBody(to position: CGPoint) -> KinectBodyData? {
        let bodies = getActiveBodies()
        return bodies.min { a, b in
            let distA = distance(a.position, position)
            let distB = distance(b.position, position)
            return distA < distB
        }
    }
    
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p1.x - p2.x
        let dy = p1.y - p2.y
        return sqrt(dx * dx + dy * dy)
    }
}

class AudienceBodyClaimResolver {
    private let kinectProvider: KinectBodyProvider
    private let claimLock = NSLock()
    
    private var sessionLastInteraction: [String: Date] = [:]
    private var sessionPhoneMotion: [String: CGPoint] = [:]
    
    init(kinectProvider: KinectBodyProvider? = nil) {
        self.kinectProvider = kinectProvider ?? StubKinectBodyProvider()
    }
    
    func updateSessionInteraction(_ sessionId: String) {
        claimLock.lock()
        defer { claimLock.unlock() }
        
        sessionLastInteraction[sessionId] = Date()
    }
    
    func updateSessionPhoneMotion(_ sessionId: String, motion: CGPoint) {
        claimLock.lock()
        defer { claimLock.unlock() }
        
        sessionPhoneMotion[sessionId] = motion
    }
    
    func resolveActiveClaim(for session: AudienceSessionState, activeSessions: [String: AudienceSessionState]) -> AudienceClaimState? {
        claimLock.lock()
        defer { claimLock.unlock() }
        
        guard session.isActive else { return nil }
        
        let bodies = kinectProvider.getActiveBodies()
        guard !bodies.isEmpty else { return nil }
        
        // Simple heuristic: nearest body + recent interaction + optional phone motion
        let recencyThreshold: TimeInterval = 10.0
        let recentSessions = activeSessions.values.filter { s in
            guard let lastInteraction = sessionLastInteraction[s.sessionId] else { return false }
            return Date().timeIntervalSince(lastInteraction) < recencyThreshold
        }
        
        guard recentSessions.contains(where: { $0.sessionId == session.sessionId }) else {
            return nil
        }
        
        // For cabled audio, prefer the session with live cable connection
        if session.isCableConnected {
            var claim = AudienceClaimState(sessionId: session.sessionId, claimedBodyIndex: 0)
            claim.confidenceScore = 0.95
            claim.claimLastUpdatedAt = Date()
            return claim
        }
        
        // For non-cabled, use spatial heuristic (stub)
        if let claimed = bodies.first {
            var claim = AudienceClaimState(sessionId: session.sessionId, claimedBodyIndex: claimed.bodyIndex)
            claim.confidenceScore = 0.6 + (claimed.confidence * 0.4)
            claim.claimLastUpdatedAt = Date()
            return claim
        }
        
        return nil
    }
    
    func getVisibleParticipantFrame(for claim: AudienceClaimState, in bodies: [KinectBodyData]) -> VisibleParticipantClaimFrame? {
        guard let bodyIndex = claim.claimedBodyIndex, let body = bodies.first(where: { $0.bodyIndex == bodyIndex }) else {
            return nil
        }
        
        let boxSize: CGFloat = 120
        let rect = CGRect(
            x: body.position.x - boxSize / 2,
            y: body.position.y - boxSize / 2,
            width: boxSize,
            height: boxSize
        )
        
        let aberrationOffset = 3.0 * claim.confidenceScore
        
        return VisibleParticipantClaimFrame(
            sessionId: claim.sessionId,
            claimedBodyIndex: bodyIndex,
            reticlePosition: body.position,
            boxBounds: rect,
            aberrationOffsetX: aberrationOffset,
            aberrationOffsetY: -aberrationOffset,
            flashIntensity: claim.confidenceScore,
            displayDurationMs: 3000
        )
    }
}
