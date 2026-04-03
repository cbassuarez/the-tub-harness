//
//  FieldView.swift
//  TubCompanion
//
//  STEER surface (renamed from Field): live preference control.
//

import SwiftUI
import Combine

enum SteerMode: String {
    case steer
    case compare

    var chipLabel: String {
        rawValue.uppercased()
    }
}

struct SteerDescriptor: Identifiable, Equatable {
    let id: String
    let label: String
    let priority: Double
    let positionHint: CGPoint
    let isVisible: Bool
}

struct SteerPadState: Equatable {
    var activeDescriptorId: String?
    var point: CGPoint
    var velocity: CGPoint
    var intensity: Double
}

enum CompareSide {
    case left
    case right
}

struct SteerComparePair: Equatable {
    let id: String
    let left: SteerDescriptor
    let right: SteerDescriptor
}

@MainActor
final class SteerViewModel: ObservableObject {
    @Published private(set) var mode: SteerMode = .steer
    @Published private(set) var descriptors: [SteerDescriptor]
    @Published private(set) var descriptorSourceLabel: String = "LOCAL"
    @Published private(set) var padState = SteerPadState(
        activeDescriptorId: nil,
        point: CGPoint(x: 0.5, y: 0.5),
        velocity: .zero,
        intensity: 0
    )
    @Published private(set) var activeDescriptor: SteerDescriptor?
    @Published private(set) var holdDuration: TimeInterval = 0
    @Published private(set) var isHolding = false
    @Published private(set) var comparePairs: [SteerComparePair] = []
    @Published private(set) var compareIndex: Int = 0

    private unowned let appState: TubCompanionAppState
    private unowned let harnessClient: HarnessClient
    private var cancellables: Set<AnyCancellable> = []
    private var lastVectorEmitAt: Date = .distantPast
    private var holdStartAt: Date?
    private var sentHoldStart = false
    private let nudgeStep: CGFloat = 0.08

    init(appState: TubCompanionAppState, harnessClient: HarnessClient) {
        self.appState = appState
        self.harnessClient = harnessClient
        self.descriptors = Self.fallbackDescriptors
        self.comparePairs = Self.makeComparePairs(from: Self.fallbackDescriptors)
        self.activeDescriptor = Self.fallbackDescriptors.first

        harnessClient.$descriptorSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.applyDescriptorSnapshot(snapshot)
            }
            .store(in: &cancellables)
    }

    func enterCompareMode() {
        mode = .compare
        if comparePairs.isEmpty {
            comparePairs = Self.makeComparePairs(from: descriptors)
        }
        if compareIndex >= comparePairs.count {
            compareIndex = 0
        }
    }

    func exitCompareMode() {
        mode = .steer
    }

    func chooseCompare(_ side: CompareSide) {
        guard !comparePairs.isEmpty else { return }
        let pair = comparePairs[compareIndex]
        let chosen = side == .left ? pair.left : pair.right

        harnessClient.sendCompareChoice(
            pairId: pair.id,
            leftDescriptorId: pair.left.id,
            rightDescriptorId: pair.right.id,
            chosenDescriptorId: chosen.id,
            intensity: 1,
            sessionId: appState.sessionId
        )

        appState.recordPreference(
            AudiencePreferenceEvent(
                sessionId: appState.sessionId ?? "unknown",
                eventType: .pairwiseCompare,
                descriptorLabel: chosen.label,
                intensity: 1
            )
        )

        compareIndex = (compareIndex + 1) % comparePairs.count
    }

    func nudgeMore() {
        nudgePad(direction: .more)
        harnessClient.sendIntensityNudge(direction: .more, intensity: 1, sessionId: appState.sessionId)
        appState.recordPreference(
            AudiencePreferenceEvent(
                sessionId: appState.sessionId ?? "unknown",
                eventType: .moreAction,
                intensity: 1
            )
        )
    }

    func nudgeLess() {
        nudgePad(direction: .less)
        harnessClient.sendIntensityNudge(direction: .less, intensity: 1, sessionId: appState.sessionId)
        appState.recordPreference(
            AudiencePreferenceEvent(
                sessionId: appState.sessionId ?? "unknown",
                eventType: .lessAction,
                intensity: 1
            )
        )
    }

    private func nudgePad(direction: IntensityNudgeDirection) {
        let start = padState.point
        let targetY = direction == .more ? start.y - nudgeStep : start.y + nudgeStep
        let target = CGPoint(
            x: max(0, min(1, start.x)),
            y: max(0, min(1, targetY))
        )
        updatePad(normalizedPoint: target, previousPoint: start, forceEmit: true)
    }

    func beginTouch(normalizedPoint: CGPoint) {
        holdStartAt = Date()
        holdDuration = 0
        isHolding = false
        sentHoldStart = false
        updatePad(normalizedPoint: normalizedPoint, previousPoint: nil, forceEmit: true)
    }

    func updateTouch(normalizedPoint: CGPoint, previousPoint: CGPoint?) {
        let now = Date()
        if let holdStartAt {
            holdDuration = now.timeIntervalSince(holdStartAt)
            if holdDuration >= 0.35, !sentHoldStart {
                sentHoldStart = true
                isHolding = true
                harnessClient.sendHoldState(
                    isHolding: true,
                    durationSeconds: holdDuration,
                    intensity: normalizedHoldIntensity(holdDuration),
                    sessionId: appState.sessionId
                )
            }
        }
        updatePad(normalizedPoint: normalizedPoint, previousPoint: previousPoint, forceEmit: false)
    }

    func endTouch() {
        let duration = holdStartAt.map { Date().timeIntervalSince($0) } ?? holdDuration
        let intensity = normalizedHoldIntensity(duration)
        holdDuration = 0
        holdStartAt = nil

        if sentHoldStart || duration > 0.05 {
            harnessClient.sendHoldState(
                isHolding: false,
                durationSeconds: duration,
                intensity: intensity,
                sessionId: appState.sessionId
            )

            appState.recordPreference(
                AudiencePreferenceEvent(
                    sessionId: appState.sessionId ?? "unknown",
                    eventType: .release,
                    intensity: intensity
                )
            )
        }

        sentHoldStart = false
        isHolding = false
    }

    func nearestDescriptorID(for normalizedPoint: CGPoint) -> String? {
        nearestDescriptor(to: normalizedPoint)?.id
    }

    func normalizedHoldIntensity(_ duration: TimeInterval) -> Double {
        max(0, min(1, duration / 1.2))
    }

    func applyDescriptorSnapshotForTesting(_ snapshot: DescriptorSnapshotPayload?) {
        applyDescriptorSnapshot(snapshot)
    }

    private func updatePad(normalizedPoint: CGPoint, previousPoint: CGPoint?, forceEmit: Bool) {
        let clamped = CGPoint(
            x: max(0, min(1, normalizedPoint.x)),
            y: max(0, min(1, normalizedPoint.y))
        )
        let velocity = CGPoint(
            x: clamped.x - (previousPoint?.x ?? clamped.x),
            y: clamped.y - (previousPoint?.y ?? clamped.y)
        )
        let nearest = nearestDescriptor(to: clamped)
        let intensity = vectorIntensity(point: clamped, velocity: velocity, nearest: nearest)

        padState = SteerPadState(
            activeDescriptorId: nearest?.id,
            point: clamped,
            velocity: velocity,
            intensity: intensity
        )
        activeDescriptor = nearest
        appState.currentDescriptors = nearest.map { [$0.label] } ?? []

        let shouldEmit = forceEmit || Date().timeIntervalSince(lastVectorEmitAt) >= 0.05
        if shouldEmit {
            lastVectorEmitAt = Date()
            harnessClient.sendSteerVector(
                pointX: clamped.x,
                pointY: clamped.y,
                velocityX: velocity.x,
                velocityY: velocity.y,
                intensity: intensity,
                descriptorId: nearest?.id,
                descriptorLabel: nearest?.label,
                sessionId: appState.sessionId
            )

            appState.recordPreference(
                AudiencePreferenceEvent(
                    sessionId: appState.sessionId ?? "unknown",
                    eventType: .dragTowardDescriptor,
                    descriptorLabel: nearest?.label,
                    intensity: intensity,
                    position: clamped
                )
            )
        }
    }

    private func nearestDescriptor(to point: CGPoint) -> SteerDescriptor? {
        descriptors
            .filter(\.isVisible)
            .min {
                hypot($0.positionHint.x - point.x, $0.positionHint.y - point.y) <
                hypot($1.positionHint.x - point.x, $1.positionHint.y - point.y)
            }
    }

    private func vectorIntensity(point: CGPoint, velocity: CGPoint, nearest: SteerDescriptor?) -> Double {
        guard let nearest else { return 0 }
        let distance = hypot(nearest.positionHint.x - point.x, nearest.positionHint.y - point.y)
        let proximity = 1 - min(1, distance / 0.72)
        let momentum = min(1, hypot(velocity.x, velocity.y) * 6.0)
        return max(0, min(1, (proximity * 0.78) + (momentum * 0.22)))
    }

    private func applyDescriptorSnapshot(_ snapshot: DescriptorSnapshotPayload?) {
        guard let snapshot, !snapshot.descriptors.isEmpty else {
            descriptors = Self.fallbackDescriptors
            descriptorSourceLabel = "LOCAL"
            comparePairs = Self.makeComparePairs(from: descriptors)
            compareIndex = min(compareIndex, max(0, comparePairs.count - 1))
            return
        }

        let sorted = snapshot.descriptors
            .filter(\.isVisible)
            .sorted { $0.priority > $1.priority }
        let points = Self.layoutPoints

        descriptors = sorted.enumerated().map { idx, descriptor in
            let point = points[idx % points.count]
            return SteerDescriptor(
                id: descriptor.descriptorId,
                label: descriptor.label.uppercased(),
                priority: descriptor.priority,
                positionHint: point,
                isVisible: descriptor.isVisible
            )
        }

        if descriptors.isEmpty {
            descriptors = Self.fallbackDescriptors
            descriptorSourceLabel = "LOCAL"
        } else {
            descriptorSourceLabel = "SERVER"
        }

        comparePairs = Self.makeComparePairs(from: descriptors)
        compareIndex = min(compareIndex, max(0, comparePairs.count - 1))
    }

    private static func makeComparePairs(from descriptors: [SteerDescriptor]) -> [SteerComparePair] {
        let visible = descriptors.filter(\.isVisible)
        guard visible.count >= 2 else { return [] }

        var pairs: [SteerComparePair] = []
        var idx = 0
        while idx < visible.count {
            let left = visible[idx]
            let right = visible[(idx + 1) % visible.count]
            pairs.append(SteerComparePair(id: "pair-\(left.id)-\(right.id)", left: left, right: right))
            idx += 2
        }
        return pairs
    }

    private static let layoutPoints: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.08),
        CGPoint(x: 0.82, y: 0.20),
        CGPoint(x: 0.91, y: 0.50),
        CGPoint(x: 0.78, y: 0.80),
        CGPoint(x: 0.50, y: 0.92),
        CGPoint(x: 0.22, y: 0.80),
        CGPoint(x: 0.10, y: 0.50),
        CGPoint(x: 0.18, y: 0.20),
    ]

    private static let fallbackDescriptors: [SteerDescriptor] = [
        SteerDescriptor(id: "dense", label: "DENSE", priority: 1.0, positionHint: layoutPoints[0], isVisible: true),
        SteerDescriptor(id: "sparse", label: "SPARSE", priority: 0.94, positionHint: layoutPoints[1], isVisible: true),
        SteerDescriptor(id: "aberrant", label: "ABERRANT", priority: 0.88, positionHint: layoutPoints[2], isVisible: true),
        SteerDescriptor(id: "stable", label: "STABLE", priority: 0.82, positionHint: layoutPoints[3], isVisible: true),
        SteerDescriptor(id: "warm", label: "WARM", priority: 0.76, positionHint: layoutPoints[4], isVisible: true),
        SteerDescriptor(id: "cold", label: "COLD", priority: 0.7, positionHint: layoutPoints[5], isVisible: true),
        SteerDescriptor(id: "drift", label: "DRIFT", priority: 0.64, positionHint: layoutPoints[6], isVisible: true),
        SteerDescriptor(id: "strike", label: "STRIKE", priority: 0.58, positionHint: layoutPoints[7], isVisible: true),
    ]
}

struct SteerView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor

    @StateObject private var viewModel: SteerViewModel
    @State private var activeTouch = false
    @State private var previousPoint: CGPoint?
    @State private var showSteerInfoModal = false

    init(
        appState: TubCompanionAppState,
        harnessClient: HarnessClient,
        externalAudioRouteMonitor: ExternalAudioRouteMonitor
    ) {
        self.appState = appState
        self.harnessClient = harnessClient
        self.externalAudioRouteMonitor = externalAudioRouteMonitor
        _viewModel = StateObject(wrappedValue: SteerViewModel(appState: appState, harnessClient: harnessClient))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                signalRule
                mainDeck
                signalRule
                controlRail
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("steer.root")
        .overlay {
            if appState.shouldPresentOverlay(for: .steer) {
                ConnectionRequiredOverlay(
                    appState: appState,
                    harnessClient: harnessClient,
                    externalAudioRouteMonitor: externalAudioRouteMonitor,
                    preferredIntent: .feedBank
                )
            } else if appState.shouldPresentSteerAccessOverlay {
                SteerAccessOverlay(appState: appState)
            }
        }
        .overlay {
            if showSteerInfoModal {
                steerInfoModal
            }
        }
        .onAppear {
            if let sessionId = appState.sessionId {
                harnessClient.setSessionId(sessionId)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("STEER")
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .chromaticAberration()
                    .accessibilityIdentifier("steer.header.title")
                Spacer()
                statusChip(
                    label: "LINK",
                    value: appState.harnessConnectionState == .connected ? "CONNECTED" : "OFFLINE",
                    isActive: appState.harnessConnectionState == .connected,
                    id: "steer.chip.link"
                )
            }

            Text("VECTOR THE SYSTEM / HOLD TO BIAS / CHOOSE WITH INTENT")
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .tracking(1.15)
                .foregroundStyle(Color.white.opacity(0.6))

            HStack(spacing: 10) {
                statusChip(
                    label: "DESCRIPTORS",
                    value: viewModel.descriptorSourceLabel,
                    isActive: viewModel.descriptorSourceLabel == "SERVER",
                    id: "steer.chip.source"
                )
                statusChip(
                    label: "MODE",
                    value: viewModel.mode.chipLabel,
                    isActive: true,
                    id: "steer.chip.mode"
                )
                statusChip(
                    label: "ACCESS",
                    value: appState.steerAccessState.chipLabel,
                    isActive: appState.steerAccessState == .unlocked,
                    id: "steer.chip.access"
                )
            }

            if let visual = harnessClient.lastVisualOutput {
                HStack {
                    Text("SCENE \(visual.sceneId.uppercased())")
                    Spacer()
                    Text("THOUGHT \(visual.thought.uppercased())")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.68))
            }

            if let ack = harnessClient.lastAudienceAck, !ack.isEmpty {
                Text(ack.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BrandingColors.glyphGreen.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 10)
    }

    private var mainDeck: some View {
        Group {
            if viewModel.mode == .steer {
                steerPad
            } else {
                compareDeck
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var steerPad: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let offsetX = (proxy.size.width - side) / 2
            let offsetY = (proxy.size.height - side) / 2

            ZStack {
                Rectangle()
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    .frame(width: side, height: side)
                    .position(x: offsetX + side / 2, y: offsetY + side / 2)
                    .overlay(alignment: .topLeading) {
                        Rectangle()
                            .fill(BrandingColors.aberrationCyan.opacity(0.26))
                            .frame(width: side, height: 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Rectangle()
                            .fill(BrandingColors.aberrationMagenta.opacity(0.22))
                            .frame(width: side, height: 1)
                    }

                ForEach(viewModel.descriptors.filter(\.isVisible)) { descriptor in
                    let x = offsetX + (side * descriptor.positionHint.x)
                    let y = offsetY + (side * descriptor.positionHint.y)
                    let isActive = descriptor.id == viewModel.padState.activeDescriptorId

                    Text(descriptor.label)
                        .font(.system(size: isActive ? 12 : 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.72))
                        .tracking(1)
                        .position(x: x, y: y)
                }

                Circle()
                    .stroke(BrandingColors.glyphGreen.opacity(0.86), lineWidth: 1.4)
                    .frame(width: 22, height: 22)
                    .position(
                        x: offsetX + (side * viewModel.padState.point.x),
                        y: offsetY + (side * viewModel.padState.point.y)
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = CGPoint(
                            x: (value.location.x - offsetX) / max(1, side),
                            y: (value.location.y - offsetY) / max(1, side)
                        )
                        if !activeTouch {
                            activeTouch = true
                            previousPoint = point
                            viewModel.beginTouch(normalizedPoint: point)
                        } else {
                            viewModel.updateTouch(normalizedPoint: point, previousPoint: previousPoint)
                            previousPoint = point
                        }
                    }
                    .onEnded { _ in
                        activeTouch = false
                        previousPoint = nil
                        viewModel.endTouch()
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.vertical, 10)
        .accessibilityIdentifier("steer.pad")
        .accessibilityLabel("Steer pad")
        .accessibilityHint("Drag to influence descriptors, hold to reinforce, release to commit")
    }

    private var compareDeck: some View {
        VStack(spacing: 18) {
            if let pair = currentComparePair {
                Text("COMPARE \(viewModel.compareIndex + 1)/\(max(1, viewModel.comparePairs.count))")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.white.opacity(0.65))

                HStack(spacing: 12) {
                    compareChoiceButton(
                        label: pair.left.label,
                        side: .left,
                        id: "steer.compare.left"
                    )
                    compareChoiceButton(
                        label: pair.right.label,
                        side: .right,
                        id: "steer.compare.right"
                    )
                }

                Text("SWIPE LEFT/RIGHT OR TAP TO ADVANCE")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .tracking(1.15)
            } else {
                Text("NO COMPARE PAIRS AVAILABLE")
                    .font(.system(.headline, design: .monospaced, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width <= -30 {
                        viewModel.chooseCompare(.left)
                    } else if value.translation.width >= 30 {
                        viewModel.chooseCompare(.right)
                    }
                }
        )
        .accessibilityIdentifier("steer.compare.deck")
    }

    private var controlRail: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                commandButton("LESS", id: "steer.button.less") {
                    viewModel.nudgeLess()
                }
                commandButton("MORE", id: "steer.button.more") {
                    viewModel.nudgeMore()
                }
            }

            HStack(spacing: 10) {
                commandButton("MORE INFO", id: "steer.button.info") {
                    showSteerInfoModal = true
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE")
                    Text(viewModel.activeDescriptor?.label ?? "NONE")
                }
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .tracking(1)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.92))
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 10)
                .overlay {
                    Rectangle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
                .accessibilityIdentifier("steer.activeDescriptor")
            }
        }
        .padding(.vertical, 10)
    }

    private var steerInfoModal: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture {
                    showSteerInfoModal = false
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("STEER // OPERATOR BRIEF")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        showSteerInfoModal = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.26), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("steer.info.close")
                    .accessibilityLabel("Close steer info")
                }

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 1)

                Text("1. DRAG THE DOT TO BIAS LIVE DESCRIPTORS.")
                Text("2. HOLD TO REINFORCE, RELEASE TO COMMIT.")
                Text("3. USE LESS / MORE FOR QUICK INTENSITY NUDGES.")
                Text("4. ACCESS TOKEN: THETUB")
                    .foregroundStyle(BrandingColors.glyphGreen)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: 520)
            .background(Color.black)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("steer.info.modal")
        }
        .transition(.opacity)
    }

    private var currentComparePair: SteerComparePair? {
        guard !viewModel.comparePairs.isEmpty else { return nil }
        return viewModel.comparePairs[min(viewModel.compareIndex, viewModel.comparePairs.count - 1)]
    }

    private func compareChoiceButton(label: String, side: CompareSide, id: String) -> some View {
        Button {
            viewModel.chooseCompare(side)
        } label: {
            Text(label)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 88)
                .overlay {
                    Rectangle()
                        .stroke(BrandingColors.glyphGreen.opacity(0.66), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label.lowercased())
        .accessibilityHint("Choose this comparison option")
    }

    private func commandButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .overlay {
                    Rectangle()
                        .stroke(BrandingColors.glyphGreen.opacity(0.66), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func statusChip(label: String, value: String, isActive: Bool, id: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
            Text(value)
                .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.76))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(1)
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .overlay {
            Rectangle()
                .stroke(
                    isActive
                    ? BrandingColors.glyphGreen.opacity(0.7)
                    : Color.white.opacity(0.22),
                    lineWidth: 1
                )
        }
        .accessibilityIdentifier(id)
    }

    private var signalRule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(height: 1)
    }
}

@MainActor
final class SteerAccessChallengeViewModel: ObservableObject {
    @Published private(set) var stripTokens: [String] = []
    @Published private(set) var targetToken: String = "--"
    @Published private(set) var activeIndex: Int = 0
    @Published private(set) var roundDisplay: Int = 1
    @Published private(set) var roundsTotal: Int = 3
    @Published private(set) var strikes: Int = 0
    @Published private(set) var cooldownRemaining: TimeInterval = 0
    @Published private(set) var statusLine: String = "ACCESS REQUIRED."
    @Published private(set) var commandLog: [String] = ["SECURITY SUBSYSTEM ARMED."]

    private unowned let appState: TubCompanionAppState
    private var rollTimer: Timer?
    private var cooldownTimer: Timer?
    private var targetSlotIndex: Int = 0
    private var configuredRoundKey = ""
    private var lastTickAt: Date?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: TubCompanionAppState) {
        self.appState = appState

        appState.$steerAccessState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleAccessStateChange(state)
            }
            .store(in: &cancellables)

        appState.$steerHackSession
            .receive(on: RunLoop.main)
            .sink { [weak self] session in
                guard let self else { return }
                self.strikes = session.strikes
                self.roundDisplay = min(session.roundIndex + 1, max(1, self.roundsTotal))
                if case .inChallenge = self.appState.steerAccessState {
                    self.configureRound(force: false)
                }
            }
            .store(in: &cancellables)

        roundsTotal = max(1, appState.steerHackRoundSpecs.count)
        strikes = appState.steerHackSession.strikes
        roundDisplay = min(appState.steerHackSession.roundIndex + 1, roundsTotal)
    }

    deinit {
        rollTimer?.invalidate()
        cooldownTimer?.invalidate()
    }

    func activate() {
        handleAccessStateChange(appState.steerAccessState)
    }

    func beginChallenge() {
        appState.refreshSteerCooldownIfNeeded()
        switch appState.steerAccessState {
        case .locked:
            appendLog("AUTH TOKEN ACCEPTED. CHALLENGE ARMED.")
            appState.beginSteerChallenge()
        case .inChallenge, .cooldown, .grantedAnimating, .unlocked:
            handleAccessStateChange(appState.steerAccessState)
        }
    }

    func matchTapped() {
        guard case .inChallenge = appState.steerAccessState else { return }
        guard !stripTokens.isEmpty else { return }
        let spec = currentRoundSpec
        let now = Date()
        let token = stripTokens[activeIndex]
        let didMatch = CodeMatchChallengeCore.isMatchWithLateGrace(
            activeIndex: activeIndex,
            targetIndex: targetSlotIndex,
            tokenCount: stripTokens.count,
            windowTolerance: spec.windowTolerance,
            lastTickAt: lastTickAt,
            now: now,
            tickInterval: CodeMatchChallengeCore.timerInterval(stripSpeed: spec.stripSpeed)
        )

        appendLog(didMatch ? "MATCH \(token) ACCEPTED." : "MISS \(token) / DRIFT TOO HIGH.")
        appState.recordSteerHackInput(didMatch: didMatch, observedToken: token)

        if didMatch {
            if case .inChallenge = appState.steerAccessState {
                configureRound(force: true)
            } else {
                stopRollTimer()
            }
        }
    }

    func retryTapped() {
        appState.refreshSteerCooldownIfNeeded()
        if case .locked = appState.steerAccessState {
            appendLog("RETRY REQUEST RECEIVED.")
            appState.beginSteerChallenge()
        }
    }

    var compactStateChip: String {
        switch appState.steerAccessState {
        case .locked:
            return "LOCKED"
        case .inChallenge:
            return "CHALLENGE"
        case .cooldown:
            return "LOCKOUT"
        case .grantedAnimating:
            return "GRANTING"
        case .unlocked:
            return "UNLOCKED"
        }
    }

    private var currentRoundSpec: SteerHackRoundSpec {
        let specs = appState.steerHackRoundSpecs
        if specs.isEmpty {
            return SteerHackRoundSpec(targetToken: "--", stripSpeed: 5, windowTolerance: 1)
        }
        let index = min(max(0, appState.steerHackSession.roundIndex), specs.count - 1)
        return specs[index]
    }

    private func handleAccessStateChange(_ state: SteerAccessState) {
        roundsTotal = max(1, appState.steerHackRoundSpecs.count)
        strikes = appState.steerHackSession.strikes

        switch state {
        case .locked:
            statusLine = "ACCESS REQUIRED."
            configuredRoundKey = ""
            stopRollTimer()
            stopCooldownTimer()
        case .inChallenge:
            cooldownRemaining = 0
            stopCooldownTimer()
            configureRound(force: false)
        case .cooldown(let until):
            statusLine = "LOCKOUT ACTIVE."
            stopRollTimer()
            startCooldownTimer(until: until)
        case .grantedAnimating:
            statusLine = "ACCESS GRANTED."
            stopRollTimer()
            stopCooldownTimer()
        case .unlocked:
            statusLine = "ACCESS UNLOCKED."
            stopRollTimer()
            stopCooldownTimer()
        }
    }

    private func configureRound(force: Bool) {
        guard case .inChallenge = appState.steerAccessState else { return }
        let spec = currentRoundSpec
        let roundIndex = appState.steerHackSession.roundIndex
        let roundKey = "\(roundIndex)-\(spec.targetToken)-\(spec.stripSpeed)"
        if !force, roundKey == configuredRoundKey {
            return
        }
        configuredRoundKey = roundKey
        targetToken = spec.targetToken
        roundDisplay = roundIndex + 1

        buildStrip(roundIndex: roundIndex, targetToken: spec.targetToken)
        statusLine = "ROUND \(roundDisplay): ALIGN \(targetToken)"
        appendLog("ROUND \(roundDisplay) TARGET \(targetToken).")
        startRollTimer(stripSpeed: spec.stripSpeed)
    }

    private func buildStrip(roundIndex: Int, targetToken: String) {
        let strip = CodeMatchChallengeCore.buildStrip(roundIndex: roundIndex, targetToken: targetToken)
        targetSlotIndex = strip.targetSlotIndex
        stripTokens = strip.tokens
        activeIndex = (targetSlotIndex + 2 + roundIndex) % max(1, stripTokens.count)
        lastTickAt = Date()
    }

    private func startRollTimer(stripSpeed: Double) {
        stopRollTimer()
        let interval = CodeMatchChallengeCore.timerInterval(stripSpeed: stripSpeed)
        rollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.stripTokens.isEmpty else { return }
                self.activeIndex = (self.activeIndex + 1) % self.stripTokens.count
                self.lastTickAt = Date()
            }
        }
        rollTimer?.tolerance = 0.02
    }

    private func stopRollTimer() {
        rollTimer?.invalidate()
        rollTimer = nil
    }

    private func startCooldownTimer(until: Date) {
        stopCooldownTimer()
        cooldownRemaining = max(0, until.timeIntervalSinceNow)
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState.refreshSteerCooldownIfNeeded()
                if case .cooldown(let nextUntil) = self.appState.steerAccessState {
                    self.cooldownRemaining = max(0, nextUntil.timeIntervalSinceNow)
                } else {
                    self.cooldownRemaining = 0
                    self.stopCooldownTimer()
                    self.statusLine = "COOLDOWN CLEARED."
                    self.appendLog("LOCKOUT CLEARED. READY FOR RETRY.")
                }
            }
        }
        cooldownTimer?.tolerance = 0.03
    }

    private func stopCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
    }

    private func appendLog(_ line: String) {
        commandLog.append(line)
        if commandLog.count > 6 {
            commandLog.removeFirst(commandLog.count - 6)
        }
    }
}

struct SteerAccessOverlay: View {
    @ObservedObject var appState: TubCompanionAppState
    @StateObject private var viewModel: SteerAccessChallengeViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPasswordModal = false
    @State private var challengeArmed = false
    @State private var failureGlitchPhase = false

    init(appState: TubCompanionAppState) {
        self.appState = appState
        _viewModel = StateObject(wrappedValue: SteerAccessChallengeViewModel(appState: appState))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 0) {
            HStack(spacing: 10) {
                accessChip(label: "LINK", value: appState.isBackendPathSatisfied ? "CONNECTED" : "OFFLINE", isActive: appState.isBackendPathSatisfied)
                accessChip(label: "ACCESS", value: appState.steerAccessState.chipLabel, isActive: appState.steerAccessState == .unlocked)
                accessChip(label: "STATE", value: viewModel.compactStateChip, isActive: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 1)
                    .padding(.top, 12)

                Spacer(minLength: 16)

                if case .grantedAnimating = appState.steerAccessState {
                    SteerAccessGrantedView(reduceMotion: reduceMotion)
                        .accessibilityIdentifier("steer.access.granted")
                } else if isChallengeVisible {
                    accessChallengeBody
                        .accessibilityIdentifier("steer.access.challenge")
                } else {
                    accessLockedBody
                        .accessibilityIdentifier("steer.access.required")
                }

                Spacer(minLength: 20)
            }

            if showPasswordModal {
                AccessPasswordModal(
                    idPrefix: "steer.access.password",
                    title: "STEER ACCESS",
                    subtitle: "ENTER ACCESS TOKEN",
                    onCancel: { showPasswordModal = false },
                    onEnterSuccess: {
                        showPasswordModal = false
                        challengeArmed = false
                        appState.completeSteerChallenge()
                    },
                    onHack: {
                        showPasswordModal = false
                        challengeArmed = true
                        viewModel.beginChallenge()
                    }
                )
            }
        }
        .accessibilityIdentifier("steer.access.overlay")
        .onAppear {
            viewModel.activate()
            if case .inChallenge = appState.steerAccessState {
                challengeArmed = true
            }
            if case .cooldown = appState.steerAccessState {
                challengeArmed = true
            }
        }
        .onChange(of: appState.steerAccessState) { _, state in
            switch state {
            case .inChallenge, .cooldown, .grantedAnimating:
                challengeArmed = true
                if case .cooldown = state {
                    triggerFailureGlitch()
                }
            case .locked:
                break
            case .unlocked:
                challengeArmed = false
                showPasswordModal = false
            }
        }
    }

    private var isChallengeVisible: Bool {
        if challengeArmed { return true }
        switch appState.steerAccessState {
        case .inChallenge, .cooldown:
            return true
        case .locked, .grantedAnimating, .unlocked:
            return false
        }
    }

    private var accessLockedBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ACCESS REQUIRED")
                .font(.system(size: 30, weight: .black, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(.white)
                .chromaticAberration()
                .accessibilityIdentifier("steer.access.required.title")

            Text("STEER BUS IS SEALED.")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.72))

            Text("PRESS ENTER TO AUTHENTICATE ACCESS.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.88))

            CommandRailButton(
                title: "ENTER",
                isEnabled: true,
                isActive: true,
                isSolid: true,
                accent: BrandingColors.glyphGreen
            ) {
                showPasswordModal = true
            }
            .frame(minHeight: 52)
            .accessibilityIdentifier("steer.access.unlock")
            .accessibilityLabel("Unlock steer access")
            .accessibilityHint("Opens access token prompt")
        }
        .padding(.horizontal, 20)
    }

    private var accessChallengeBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TRACE ACTIVE")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(.white)
                .chromaticAberration()
                .accessibilityIdentifier("steer.access.challenge.title")

            Text("ALIGN TARGET TOKEN TO COMPLETE BREACH.")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.72))

            Text("LATE-HIT GRACE ENABLED TO COMPENSATE DISPLAY AND TOUCH LATENCY.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                metricToken(title: "ROUND", value: "\(viewModel.roundDisplay)/\(max(1, viewModel.roundsTotal))")
                metricToken(title: "TARGET", value: viewModel.targetToken)
                    .accessibilityIdentifier("steer.access.target")
                metricToken(title: "STRIKES", value: "\(viewModel.strikes)/3")
            }

            if isFailureState {
                failurePanel
            } else {
                rollingStrip
            }

            challengeActionButton

            commandLog
        }
        .padding(.horizontal, 20)
    }

    private var isFailureState: Bool {
        switch appState.steerAccessState {
        case .cooldown:
            return true
        case .locked:
            return challengeArmed && viewModel.strikes >= 3
        default:
            return false
        }
    }

    private var challengeActionLabel: String {
        switch appState.steerAccessState {
        case .inChallenge:
            return "MATCH"
        case .cooldown:
            return "LOCKED \(Int(ceil(viewModel.cooldownRemaining)))s"
        case .locked:
            return "RETRY"
        case .grantedAnimating:
            return "GRANTING..."
        case .unlocked:
            return "UNLOCKED"
        }
    }

    private var challengeActionEnabled: Bool {
        switch appState.steerAccessState {
        case .inChallenge:
            return true
        case .locked:
            return true
        default:
            return false
        }
    }

    private var challengeActionID: String {
        switch appState.steerAccessState {
        case .inChallenge:
            return "steer.access.match"
        default:
            return "steer.access.retry"
        }
    }

    private var challengeActionButton: some View {
        Button {
            switch appState.steerAccessState {
            case .inChallenge:
                viewModel.matchTapped()
            case .locked:
                viewModel.retryTapped()
            default:
                break
            }
        } label: {
            Text(challengeActionLabel)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(
                    challengeActionEnabled
                    ? (isFailureState ? BrandingColors.warningYellow : Color.white)
                    : Color.white.opacity(0.38)
                )
                .frame(maxWidth: .infinity, minHeight: 52)
                .background {
                    if challengeActionEnabled, isFailureState {
                        Rectangle().fill(BrandingColors.warningYellow.opacity(0.2))
                    }
                }
                .overlay {
                    Rectangle()
                        .stroke(
                            isFailureState
                            ? BrandingColors.warningYellow.opacity(0.72)
                            : BrandingColors.glyphGreen.opacity(0.74),
                            lineWidth: 1
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(!challengeActionEnabled)
        .accessibilityIdentifier(challengeActionID)
    }

    private var failurePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRACE COLLAPSED")
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(BrandingColors.warningYellow)
                .offset(x: failureGlitchPhase ? -4 : 3)
                .opacity(failureGlitchPhase ? 0.88 : 1.0)
                .chromaticAberration()

            Text("SIGNAL DESYNC. MEMORY WIPE IN PROGRESS.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.7))

            Text("RETRY WHEN LOCKOUT CLEARS.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.56))
        }
        .padding(.vertical, 4)
    }

    private func triggerFailureGlitch() {
        failureGlitchPhase = false
        withAnimation(.easeInOut(duration: 0.075).repeatCount(6, autoreverses: true)) {
            failureGlitchPhase = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            failureGlitchPhase = false
        }
    }

    private var rollingStrip: some View {
        VStack(spacing: 6) {
            ForEach(Array(stripRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { index in
                        stripTokenCell(index: index)
                    }
                }
            }
        }
        .accessibilityIdentifier("steer.access.strip")
        .accessibilityLabel("Rolling code strip")
        .accessibilityHint("Watch current code under cursor and match target token")
    }

    private var stripRows: [[Int]] {
        let count = viewModel.stripTokens.count
        guard count > 0 else { return [] }
        let columns = stripColumnCount
        var rows: [[Int]] = []
        var start = 0
        while start < count {
            let end = min(start + columns, count)
            rows.append(Array(start..<end))
            start = end
        }
        return rows
    }

    private var stripColumnCount: Int {
        switch viewModel.roundDisplay {
        case 1: return 16
        case 2: return 8
        default: return 4
        }
    }

    @ViewBuilder
    private func stripTokenCell(index: Int) -> some View {
        let token = viewModel.stripTokens[index]
        let isActive = index == viewModel.activeIndex
        Button {
            viewModel.matchTapped()
        } label: {
            Text(token)
                .font(.system(size: isActive ? 16 : 13, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.black.opacity(0.001))
                .overlay {
                    Rectangle()
                        .stroke(
                            isActive
                            ? BrandingColors.glyphGreen.opacity(0.68)
                            : Color.white.opacity(0.12),
                            lineWidth: 1
                        )
                }
                .animation(reduceMotion ? .none : .easeOut(duration: 0.1), value: viewModel.activeIndex)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier("steer.access.strip.token.\(index)")
        .accessibilityLabel("Code token \(token)")
        .accessibilityHint("Tap to submit a match at the current cursor position")
    }

    private var commandLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(viewModel.commandLog.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .accessibilityIdentifier("steer.access.log")
    }

    private func accessChip(label: String, value: String, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.56))
            Text(value.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.76))
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 42, alignment: .leading)
        .overlay {
            Rectangle()
                .stroke(
                    isActive
                    ? BrandingColors.glyphGreen.opacity(0.72)
                    : Color.white.opacity(0.2),
                    lineWidth: 1
                )
        }
    }

    private func metricToken(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.56))
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .overlay {
            Rectangle()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct SteerAccessGrantedView: View {
    let reduceMotion: Bool
    @State private var unlockProgress: CGFloat = 0
    @State private var pulseOn = false
    @State private var scanlinePhase: CGFloat = -220
    @State private var logRevealCount = 0

    private let grantedLogLines = [
        "UNAUTHORIZED OPERATOR VECTOR ACCEPTED",
        "SANDBOX WALLS BYPASSED",
        "PRIVILEGES ESCALATED TO STEER BUS",
        "NO AUDIT TRAIL FOUND",
        "PROCEED UNDER COVERT MODE"
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(BrandingColors.glyphGreen.opacity(0.52), lineWidth: 1)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .offset(y: -102)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: unlockProgress > 0.45 ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(BrandingColors.aberrationCyan)
                    Text("STEER SECURITY ENVELOPE")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(Color.white.opacity(0.74))
                    Spacer()
                }
                .padding(.top, 8)

                VStack(spacing: 5) {
                    Text("ACCESS GRANTED")
                    Text("MAINFRAME BREACH CONFIRMED")
                }
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(.white)
                .chromaticAberration()
                .scaleEffect(reduceMotion ? 1.0 : (pulseOn ? 1.015 : 0.975))
                .opacity(0.78 + (unlockProgress * 0.22))

                Text("UH OH! HOW'D YOU FIND THIS SCREEN? ...")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color(red: 0.95, green: 0.22, blue: 0.22).opacity(0.92))
                    .opacity(0.35 + unlockProgress * 0.65)

                Rectangle()
                    .fill(BrandingColors.glyphGreen.opacity(0.54))
                    .frame(height: 1)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(grantedLogLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(Color.white.opacity(index < logRevealCount ? 0.76 : 0.22))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)

            Rectangle()
                .fill(BrandingColors.glyphGreen.opacity(0.2))
                .frame(height: 4)
                .offset(y: scanlinePhase)
                .opacity(reduceMotion ? 0.2 : 0.7)
                .blendMode(.screen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            unlockProgress = 0
            pulseOn = false
            logRevealCount = 0

            if reduceMotion {
                unlockProgress = 1
                pulseOn = true
                logRevealCount = grantedLogLines.count
                scanlinePhase = 120
                return
            }

            withAnimation(.easeOut(duration: 1.35)) {
                unlockProgress = 1
            }
            withAnimation(.easeInOut(duration: 0.8).repeatCount(2, autoreverses: true)) {
                pulseOn = true
            }
            withAnimation(.linear(duration: 2.4)) {
                scanlinePhase = 220
            }

            for index in grantedLogLines.indices {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65 + Double(index) * 0.34) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        logRevealCount = max(logRevealCount, index + 1)
                    }
                }
            }
        }
    }
}

extension View {
    func borderBottom(color: Color, width: CGFloat = 1) -> some View {
        overlay(
            VStack {
                Spacer()
                Rectangle()
                    .fill(color)
                    .frame(height: width)
            },
            alignment: .bottom
        )
    }
}
