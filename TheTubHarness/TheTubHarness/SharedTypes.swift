//
//  SharedTypes.swift
//  TheTubHarness + TubCompanion
//
//  Shared, platform-agnostic types for cross-target use.
//  This file contains only Swift Foundation types, no platform-specific APIs.
//

import Foundation

// MARK: - Branding Tokens

enum BrandingTokens {
    enum Color {
        // Monitor/terminal aesthetic
        static let darkBackground = "#0a0e27"
        static let glyphGreen = "#00ff41"
        static let aberrationRed = "#ff006e"
        static let aberrationCyan = "#00f5ff"
        static let warningYellow = "#ffbe0b"
        static let successGreen = "#38a169"
        static let gridGray = "#1a1f3a"
    }
    
    enum Typography {
        static let displayFont = "JetBrainsMono"
        static let textFont = "JetBrainsMono"
        static let defaultFontSize: CGFloat = 12.0
        static let headingFontSize: CGFloat = 18.0
        static let displayFontSize: CGFloat = 28.0
    }
    
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }
}

// MARK: - Harness Connection

enum HarnessConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// MARK: - Audience Session Types

enum AudienceSessionType {
    case appCompanion
    case appClip
    case cableOnly
}

struct AudienceSessionState: Codable, Equatable {
    let sessionId: String
    let createdAt: Date
    let sessionType: String
    let isActive: Bool
    let isCableConnected: Bool
    let lastInteractionAt: Date?
    let phoneMotionAvailable: Bool
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionId, createdAt, sessionType, isActive, isCableConnected, lastInteractionAt, phoneMotionAvailable
    }
    
    init(sessionId: String, sessionType: AudienceSessionType, isCableConnected: Bool = false, phoneMotionAvailable: Bool = false) {
        self.sessionId = sessionId
        self.createdAt = Date()
        self.sessionType = sessionType == .appCompanion ? "app" : (sessionType == .appClip ? "clip" : "cable")
        self.isActive = true
        self.isCableConnected = isCableConnected
        self.lastInteractionAt = nil
        self.phoneMotionAvailable = phoneMotionAvailable
    }
}

enum PreferenceEventType: String, Codable {
    case dragTowardDescriptor
    case hold
    case moreAction
    case lessAction
    case pairwiseCompare
    case release
}

struct AudiencePreferenceEvent: Codable, Equatable {
    let eventId: String
    let sessionId: String
    let timestamp: Date
    let eventType: PreferenceEventType
    let descriptorLabel: String?
    let intensity: Double
    let position: CGPoint?
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case eventId, sessionId, timestamp, eventType, descriptorLabel, intensity, position
    }
    
    init(sessionId: String, eventType: PreferenceEventType, descriptorLabel: String? = nil, intensity: Double = 0.5, position: CGPoint? = nil) {
        self.eventId = UUID().uuidString
        self.sessionId = sessionId
        self.timestamp = Date()
        self.eventType = eventType
        self.descriptorLabel = descriptorLabel
        self.intensity = min(max(intensity, 0.0), 1.0)
        self.position = position
    }
}

enum AudioContributionState: String, Codable {
    case inbox
    case cooldown
    case normalizing
    case transientSplicing = "transient_splicing"
    case approved
    case rejected
    
    var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .cooldown: return "Cooling Down"
        case .normalizing: return "Normalizing"
        case .transientSplicing: return "Processing"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        }
    }
}

struct AudienceAudioContribution: Codable, Equatable {
    let contributionId: String
    let sessionId: String
    let createdAt: Date
    let fileUrl: String?
    let durationMs: Int?
    var state: AudioContributionState
    var stateTransitionAt: Date
    let normalizedGain: Double?
    var rejectionReason: String?
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contributionId, sessionId, createdAt, fileUrl, durationMs, state, stateTransitionAt, normalizedGain, rejectionReason
    }
    
    init(sessionId: String, fileUrl: String? = nil, durationMs: Int? = nil) {
        self.contributionId = UUID().uuidString
        self.sessionId = sessionId
        self.createdAt = Date()
        self.fileUrl = fileUrl
        self.durationMs = durationMs
        self.state = .inbox
        self.stateTransitionAt = Date()
        self.normalizedGain = nil
        self.rejectionReason = nil
    }
}

struct AudienceClaimState: Codable, Equatable {
    let sessionId: String
    let claimedBodyIndex: Int?
    var confidenceScore: Double
    let claimStartedAt: Date
    var claimLastUpdatedAt: Date
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionId, claimedBodyIndex, confidenceScore, claimStartedAt, claimLastUpdatedAt
    }
    
    init(sessionId: String, claimedBodyIndex: Int? = nil) {
        self.sessionId = sessionId
        self.claimedBodyIndex = claimedBodyIndex
        self.confidenceScore = 0.0
        self.claimStartedAt = Date()
        self.claimLastUpdatedAt = Date()
    }
}

struct AudienceDescriptorState: Codable, Equatable {
    let descriptorId: String
    let label: String
    let priority: Double
    let isVisible: Bool
    let systemStateId: String?
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case descriptorId, label, priority, isVisible, systemStateId
    }
}

struct AudienceTraceState: Codable, Equatable {
    let traceId: String
    let timestamp: Date
    let sessionId: String
    let preferenceEvents: [AudiencePreferenceEvent]
    let audioContributions: [AudienceAudioContribution]
    let claimState: AudienceClaimState?
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case traceId, timestamp, sessionId, preferenceEvents, audioContributions, claimState
    }
}

// MARK: - Thought Output Bias

struct ThoughtBias: Codable, Equatable {
    let biasFactor: Double
    let targetThoughts: [String]
    let suppressThoughts: [String]
    let sustainDurationMs: Int
    
    init(biasFactor: Double = 0.1, targetThoughts: [String] = [], suppressThoughts: [String] = [], sustainDurationMs: Int = 500) {
        self.biasFactor = min(max(biasFactor, -0.5), 0.5)
        self.targetThoughts = targetThoughts
        self.suppressThoughts = suppressThoughts
        self.sustainDurationMs = sustainDurationMs
    }
}

// MARK: - Post-ML Overlay Payload

struct AudienceOverlayPayload: Codable, Equatable {
    let sessionId: String
    let timestamp: Date
    let paramWeightings: [String: Double]?
    let audioTendencyBias: Double?
    let thoughtBias: ThoughtBias?
    let visualBias: [String: Double]?
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionId, timestamp, paramWeightings, audioTendencyBias, thoughtBias, visualBias
    }
    
    init(sessionId: String, paramWeightings: [String: Double]? = nil, audioTendencyBias: Double? = nil, thoughtBias: ThoughtBias? = nil, visualBias: [String: Double]? = nil) {
        self.sessionId = sessionId
        self.timestamp = Date()
        self.paramWeightings = paramWeightings
        self.audioTendencyBias = audioTendencyBias.map { min(max($0, -0.5), 0.5) }
        self.thoughtBias = thoughtBias
        self.visualBias = visualBias
    }
}

// MARK: - Harnessside Audience Message Contracts

struct HarnessAudienceMessage: Codable, Equatable {
    enum MessageType: String, Codable {
        case sessionOpen
        case sessionClose
        case preferenceEvent
        case audioContribution
        case queryState
    }
    
    let messageType: MessageType
    let payloadJSON: String
    let timestamp: Date
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case messageType, payloadJSON, timestamp
    }
}

// MARK: - NDJSON Audience Envelope v1

enum AudienceEnvelopeKind: String, Codable {
    case sessionOpen
    case sessionClose
    case queryState
    case steerVector
    case holdState
    case intensityNudge
    case compareChoice
    case operatorVector
    case descriptorSnapshot
    case stageSnapshot
    case visualUpdate
    case ack
    case error
    case operatorActivity
    case operatorActivitySnapshot
}

enum IntensityNudgeDirection: String, Codable {
    case more
    case less
}


enum OperatorActivitySurface: String, Codable {
    case play
    case steer
}

enum OperatorActivityAction: String, Codable {
    case playGridTrigger
    case playBankPrevious
    case playBankNext
    case playLongBankPrevious
    case playLongBankNext
    case playLongTransportPause
    case playLongTransportResume
    case playLongFadeStart
    case playLongFadeComplete
    case playLongSweep

    case steerVector
    case steerHoldStart
    case steerHoldEnd
    case steerNudgeMore
    case steerNudgeLess
    case steerCompareChoice
}

struct OperatorActivityEvent: Codable, Equatable {
    let eventId: String
    let sessionId: String
    let surface: OperatorActivitySurface
    let action: OperatorActivityAction
    let label: String?
    let intensity: Double?
    let position: CGPoint?
    let timestamp: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case eventId, sessionId, surface, action, label, intensity, position, timestamp
    }

    init(
        eventId: String = UUID().uuidString,
        sessionId: String,
        surface: OperatorActivitySurface,
        action: OperatorActivityAction,
        label: String? = nil,
        intensity: Double? = nil,
        position: CGPoint? = nil,
        timestamp: Date = Date()
    ) {
        self.eventId = eventId
        self.sessionId = sessionId
        self.surface = surface
        self.action = action
        self.label = label
        self.intensity = intensity.map { value in max(0, min(1, value)) }
        self.position = position
        self.timestamp = timestamp
    }
}

struct OperatorActivitySnapshot: Codable, Equatable {
    let events: [OperatorActivityEvent]
    let serverTimestamp: Date
}

struct SteerVectorPayload: Codable, Equatable {
    let pointX: Double
    let pointY: Double
    let velocityX: Double
    let velocityY: Double
    let intensity: Double
    let descriptorId: String?
    let descriptorLabel: String?
}

struct HoldStatePayload: Codable, Equatable {
    let isHolding: Bool
    let durationSeconds: Double
    let intensity: Double
}

struct IntensityNudgePayload: Codable, Equatable {
    let direction: IntensityNudgeDirection
    let intensity: Double
}

struct CompareChoicePayload: Codable, Equatable {
    let pairId: String
    let leftDescriptorId: String
    let rightDescriptorId: String
    let chosenDescriptorId: String
    let intensity: Double
}

struct OperatorVectorPayload: Codable, Equatable {
    let paramVector: Double
    let thoughtVector: Double
    let audioVector: Double
    let ttlSeconds: Double
}

struct DescriptorSnapshotPayload: Codable, Equatable {
    let revision: Int
    let descriptors: [AudienceDescriptorState]
}

struct StageAudioSummaryPayload: Codable, Equatable {
    let rms: Double
    let transientFlux: Double
    let lowBand: Double
    let midBand: Double
    let highBand: Double
    let peak: Double
    let brightness: Double
    let overloadPulse: Double
}

struct StageSnapshotPayload: Codable, Equatable {
    let mode: Int
    let sceneId: String
    let thought: String
    let thoughtLog: [String]
    let density: Double
    let cohesion: Double
    let disruption: Double
    let isRunning: Bool
    let isWaiting: Bool
    let waitingReason: String?
    let paramLines: [String]
    let pickLines: [String]
    let changeLines: [String]
    let audio: StageAudioSummaryPayload
    let joltHeld: Bool
    let timestamp: Date
}

struct AudienceAckPayload: Codable, Equatable {
    let message: String?
}

struct AudienceErrorPayload: Codable, Equatable {
    let code: String
    let message: String
}

struct AudienceEnvelope: Codable, Equatable {
    let kind: AudienceEnvelopeKind
    let messageId: String
    let sessionId: String
    let timestamp: Date
    let steerVector: SteerVectorPayload?
    let holdState: HoldStatePayload?
    let intensityNudge: IntensityNudgePayload?
    let compareChoice: CompareChoicePayload?
    let operatorVector: OperatorVectorPayload?
    let descriptorSnapshot: DescriptorSnapshotPayload?
    let stageSnapshot: StageSnapshotPayload?
    let visualUpdate: VisualOutput?
    let ack: AudienceAckPayload?
    let error: AudienceErrorPayload?
    let operatorActivity: OperatorActivityEvent?
    let operatorActivitySnapshot: OperatorActivitySnapshot?

    init(
        kind: AudienceEnvelopeKind,
        messageId: String = UUID().uuidString,
        sessionId: String,
        timestamp: Date = Date(),
        steerVector: SteerVectorPayload? = nil,
        holdState: HoldStatePayload? = nil,
        intensityNudge: IntensityNudgePayload? = nil,
        compareChoice: CompareChoicePayload? = nil,
        operatorVector: OperatorVectorPayload? = nil,
        descriptorSnapshot: DescriptorSnapshotPayload? = nil,
        stageSnapshot: StageSnapshotPayload? = nil,
        visualUpdate: VisualOutput? = nil,
        ack: AudienceAckPayload? = nil,
        error: AudienceErrorPayload? = nil,
        operatorActivity: OperatorActivityEvent? = nil,
        operatorActivitySnapshot: OperatorActivitySnapshot? = nil
    ) {
        self.kind = kind
        self.messageId = messageId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.steerVector = steerVector
        self.holdState = holdState
        self.intensityNudge = intensityNudge
        self.compareChoice = compareChoice
        self.operatorVector = operatorVector
        self.descriptorSnapshot = descriptorSnapshot
        self.stageSnapshot = stageSnapshot
        self.visualUpdate = visualUpdate
        self.ack = ack
        self.error = error
        self.operatorActivity = operatorActivity
        self.operatorActivitySnapshot = operatorActivitySnapshot
    }
}

// MARK: - Visible Claim Rendering Data

struct VisibleParticipantClaimFrame: Codable, Equatable {
    let sessionId: String
    let claimedBodyIndex: Int
    let reticlePosition: CGPoint
    let boxBounds: CGRect
    let aberrationOffsetX: Double
    let aberrationOffsetY: Double
    let flashIntensity: Double
    let displayDurationMs: Int
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionId, claimedBodyIndex, reticlePosition, boxBounds, aberrationOffsetX, aberrationOffsetY, flashIntensity, displayDurationMs
    }
}

// MARK: - Kinect Body State (Stub)

struct KinectBodyData: Codable, Equatable {
    let bodyIndex: Int
    let position: CGPoint
    let depthZ: Double
    let confidence: Double
    let isTracked: Bool
    
    enum CodingKeys: String, CodingKey, CaseIterable {
        case bodyIndex, position, depthZ, confidence, isTracked
    }
}

// MARK: - Visual Output (iOS-compatible lightweight representation)

struct VisualOutput: Codable, Equatable {
    let sceneId: String
    let density: Double
    let cohesion: Double
    let disruption: Double
    let thought: String
    
    init(sceneId: String, density: Double, cohesion: Double, disruption: Double, thought: String) {
        self.sceneId = sceneId
        self.density = density
        self.cohesion = cohesion
        self.disruption = disruption
        self.thought = thought
    }
}

// MARK: - App Clip Routing

enum AppClipDeepLinkPath: Equatable {
    case launch
    case session(sessionId: String)
    case contribute(sessionId: String)
    
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        
        let path = components.path
        if path.isEmpty || path == "/" {
            self = .launch
        } else if path.hasPrefix("/session/") {
            let sessionId = String(path.dropFirst("/session/".count))
            self = .session(sessionId: sessionId)
        } else if path.hasPrefix("/contribute/") {
            let sessionId = String(path.dropFirst("/contribute/".count))
            self = .contribute(sessionId: sessionId)
        } else {
            return nil
        }
    }
}
