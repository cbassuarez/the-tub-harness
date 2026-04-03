//
//  ReadLearnView.swift
//  TubCompanion
//
//  Learn v4: enterprise command-shell orientation manual.
//

import SwiftUI
import Combine
import Darwin

enum LearnMode: String, CaseIterable {
    case ritual
    case atlas

    var title: String {
        switch self {
        case .ritual: return "BRIEFING"
        case .atlas: return "MANUAL"
        }
    }
}

enum LearnChapter: Int, CaseIterable, Hashable {
    case enter
    case touch
    case voice
    case claim
}

enum LearnJumpTarget {
    case steer
    case play

    var appTab: AppTab {
        switch self {
        case .steer: return .steer
        case .play: return .play
        }
    }

    var commandTitle: String {
        switch self {
        case .steer: return "JUMP STEER"
        case .play: return "JUMP PLAY"
        }
    }
}

struct LearnChapterSpec: Equatable {
    let chapter: LearnChapter
    let title: String
    let subtitle: String
    let briefLines: [String]
    let operationsLines: [String]
    let commandLines: [String]
    let jumpTarget: LearnJumpTarget?
    let previous: LearnChapter?
    let next: LearnChapter?
}

struct LearnAtlasSection: Identifiable, Hashable {
    let id: String
    let title: String
    let body: [String]
    let commands: [String]
}

struct LearnReturnContext: Equatable {
    var mode: LearnMode
    var chapter: LearnChapter
    var atlasAnchor: String?
}

@MainActor
final class LearnViewModel: ObservableObject {
    @Published var mode: LearnMode = .ritual
    @Published var activeChapter: LearnChapter = .enter
    @Published var completedChapters: Set<LearnChapter> = []
    @Published var lastAtlasAnchor: String?
    @Published var pendingJumpTarget: LearnJumpTarget?
    @Published private(set) var stageSnapshot: StageSnapshotPayload?
    @Published private(set) var stageVisualFallback: VisualOutput?
    @Published private(set) var stageFeedState: StageFeedState = .standby

    let chapterSpecs: [LearnChapter: LearnChapterSpec]
    let atlasSections: [LearnAtlasSection]

    private let harnessClient: HarnessClient
    private var stagedReturnContext: LearnReturnContext?
    private var cancellables: Set<AnyCancellable> = []
    private var stageRefreshTicker: AnyCancellable?
    private var lastStageSnapshotAt: Date?
    private var lastVisualAt: Date?

    init(harnessClient: HarnessClient) {
        self.harnessClient = harnessClient

        let enter = LearnChapterSpec(
            chapter: .enter,
            title: "WHAT IS THE TUB",
            subtitle: "SYSTEM DEFINITION",
            briefLines: [
                "THE TUB IS A LIVE AUDIO-VISUAL INSTRUMENT RUNNING IN PUBLIC.",
                "IT LISTENS, CLASSIFIES, TRANSFORMS, AND PROJECTS IN REAL TIME.",
                "YOU DO NOT BOOT THE TUB; YOU ENTER A SYSTEM ALREADY IN MOTION."
            ],
            operationsLines: [
                "TREAT THE ROOM AS HOT INFRASTRUCTURE, NOT A TOY PANEL.",
                "EVERY INPUT PATH CHANGES WHAT THE CROWD SEES AND HEARS.",
                "ACTIONS ARE COLLECTIVE: MANY PARTICIPANTS SHAPE ONE OUTPUT."
            ],
            commandLines: [
                "scli system describe --scope tub",
                "scli monitor stage --follow"
            ],
            jumpTarget: .steer,
            previous: nil,
            next: .touch
        )

        let touch = LearnChapterSpec(
            chapter: .touch,
            title: "HOW PEOPLE PARTICIPATE",
            subtitle: "INPUT STACK",
            briefLines: [
                "PARTICIPANTS USE BUTTONS, TOUCH VECTORS, AND INTENSITY NUDGES.",
                "AN ALWAYS-ON OFF-SITE MIC PROVIDES CONTINUOUS AMBIENT CONTEXT.",
                "KINECT TRACKS MOTION, BODY ORIENTATION, AND GROUP SHAPE."
            ],
            operationsLines: [
                "ML FUSES AUDIO + MOTION + GESTURE INTO SCENE DECISIONS.",
                "BODY AWARENESS MODULATES COHESION, DISRUPTION, AND THOUGHT OUTPUT.",
                "SMALL MOVES MATTER; CONSISTENT INTENT BEATS RAW FORCE."
            ],
            commandLines: [
                "scli participation inspect --sources buttons,mic,kinect,ml",
                "scli telemetry bodies --watch"
            ],
            jumpTarget: .steer,
            previous: .enter,
            next: .voice
        )

        let voice = LearnChapterSpec(
            chapter: .voice,
            title: "WHAT THIS APP IS",
            subtitle: "COMPANION TERMINAL",
            briefLines: [
                "THE APP IS THE AUDIENCE CONTROL TERMINAL FOR THE TUB.",
                "STEER SENDS PREFERENCE VECTORS; PLAY INJECTS AUDIO MATERIAL.",
                "LEARN PROVIDES THIS OPERATOR MANUAL AND SYSTEM CONTEXT."
            ],
            operationsLines: [
                "THE APP MODULATES THE INSTALLATION; IT DOES NOT REPLACE IT.",
                "YOUR PHONE IS A NODE IN A SHARED NETWORKED PERFORMANCE SURFACE.",
                "ROUTING, LINK STATE, AND FEED HEALTH ARE ALWAYS EXPLICIT."
            ],
            commandLines: [
                "scli app surfaces --list",
                "scli route status --verbose"
            ],
            jumpTarget: .play,
            previous: .touch,
            next: .claim
        )

        let claim = LearnChapterSpec(
            chapter: .claim,
            title: "OPERATING DOCTRINE",
            subtitle: "FIELD RULES",
            briefLines: [
                "OPERATE WITH INTENT: LESS NOISE, MORE SIGNAL.",
                "USE STEER TO SHAPE DIRECTION, PLAY TO SUPPLY MATERIAL.",
                "VERIFY LINK + FEED BEFORE ANY PUBLIC INTERACTION."
            ],
            operationsLines: [
                "IF FEED IS DEGRADED, HOLD STATE AND AVOID RAPID TACTIC SHIFTS.",
                "IF LINK IS DOWN, DO NOT PRETEND CONTROL IS ACTIVE.",
                "REENTRY IS ALLOWED: CHECK MANUAL MODE FOR FAST REFERENCE."
            ],
            commandLines: [
                "scli doctrine print --operator",
                "scli learn open --mode manual"
            ],
            jumpTarget: .play,
            previous: .voice,
            next: nil
        )

        chapterSpecs = [
            .enter: enter,
            .touch: touch,
            .voice: voice,
            .claim: claim
        ]

        atlasSections = [
            LearnAtlasSection(
                id: "system-overview",
                title: "SYSTEM OVERVIEW",
                body: [
                    "THE TUB IS A COMPUTATIONAL PERFORMANCE SYSTEM.",
                    "CORE LOOP: HEAR -> INFER -> RESPOND -> PROJECT.",
                    "OUTPUT IS SHARED ACROSS THE ROOM, NOT PRIVATE TO ONE USER."
                ],
                commands: [
                    "scli system overview",
                    "scli stage scene --current"
                ]
            ),
            LearnAtlasSection(
                id: "participation-stack",
                title: "PARTICIPATION STACK",
                body: [
                    "BUTTONS + TOUCH PADS PROVIDE EXPLICIT USER COMMANDS.",
                    "OFF-SITE MIC FEEDS CONTINUOUS ENVIRONMENTAL SIGNAL.",
                    "KINECT PROVIDES MOTION/BODY PRESENCE CONTEXT.",
                    "ML MEDIATES ALL SIGNALS INTO MODE AND THOUGHT CHANGES."
                ],
                commands: [
                    "scli participation stack --explain",
                    "scli telemetry inputs --watch"
                ]
            ),
            LearnAtlasSection(
                id: "app-surfaces",
                title: "APP SURFACES",
                body: [
                    "STEER: DESCRIPTOR ATTRACTOR + COMPARE FLOW.",
                    "PLAY: LIVE SAMPLE GRID INTO ACTIVE OUTPUT ROUTE.",
                    "LEARN: ORIENTATION + OPERATOR REFERENCE.",
                    "SETTINGS: DEVICE + SESSION DIAGNOSTICS."
                ],
                commands: [
                    "scli app surfaces --list",
                    "scli app open --surface steer"
                ]
            ),
            LearnAtlasSection(
                id: "signal-path",
                title: "SIGNAL PATH",
                body: [
                    "INPUTS ARE FUSED, SCORED, THEN MAPPED TO RENDER STATE.",
                    "AUDIO STATE AND BODY STATE BOTH INFLUENCE OUTPUT.",
                    "STATE SNAPSHOTS STREAM TO THE COMPANION FOR MIRROR VIEW."
                ],
                commands: [
                    "scli signal trace --tail",
                    "scli stage snapshot --follow"
                ]
            ),
            LearnAtlasSection(
                id: "queue-claims",
                title: "QUEUE / CLAIMS",
                body: [
                    "CONTRIBUTIONS ENTER A QUEUE BEFORE APPROVAL.",
                    "CLAIMS MARK PRESENCE AND PARTICIPATION OVER TIME.",
                    "STATE CHANGES ARE LOGGED FOR OPERATOR REVIEW."
                ],
                commands: [
                    "scli queue status",
                    "scli claims inspect --active"
                ]
            ),
            LearnAtlasSection(
                id: "safety-etiquette",
                title: "SAFETY + ETIQUETTE",
                body: [
                    "USE CLEAR, DELIBERATE INTERACTIONS.",
                    "DO NOT FLOOD CONTROLS DURING DEGRADED FEED STATES.",
                    "ASSUME PUBLIC VISIBILITY FOR ALL ACTIONS."
                ],
                commands: [
                    "scli safety checklist",
                    "scli operator doctrine --summary"
                ]
            )
        ]

        harnessClient.$lastStageSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.stageSnapshot = snapshot
                if snapshot != nil {
                    self.lastStageSnapshotAt = Date()
                }
                self.refreshStageFeedState()
            }
            .store(in: &cancellables)

        harnessClient.$lastVisualOutput
            .receive(on: RunLoop.main)
            .sink { [weak self] visual in
                guard let self else { return }
                self.stageVisualFallback = visual
                if visual != nil {
                    self.lastVisualAt = Date()
                }
                self.refreshStageFeedState()
            }
            .store(in: &cancellables)

        harnessClient.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStageFeedState()
            }
            .store(in: &cancellables)

        harnessClient.$stageFeedState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStageFeedState()
            }
            .store(in: &cancellables)

        stageRefreshTicker = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStageFeedState()
            }
    }

    func spec(for chapter: LearnChapter) -> LearnChapterSpec {
        guard let spec = chapterSpecs[chapter] else { return chapterSpecs[.enter]! }
        return spec
    }

    func next() {
        let spec = spec(for: activeChapter)
        completedChapters.insert(activeChapter)
        if let next = spec.next {
            activeChapter = next
            return
        }
        skipToAtlas()
    }

    func back() {
        let spec = spec(for: activeChapter)
        guard let previous = spec.previous else { return }
        activeChapter = previous
    }

    func skipToAtlas() {
        mode = .atlas
        if lastAtlasAnchor == nil {
            lastAtlasAnchor = atlasSections.first?.id
        }
    }

    func setMode(_ newMode: LearnMode) {
        mode = newMode
        if newMode == .atlas, lastAtlasAnchor == nil {
            lastAtlasAnchor = atlasSections.first?.id
        }
    }

    func setAtlasAnchor(_ id: String) {
        mode = .atlas
        lastAtlasAnchor = id
    }

    func jumpToSteer() {
        pendingJumpTarget = .steer
    }

    func jumpToPlay() {
        pendingJumpTarget = .play
    }

    func consumePendingJumpTarget() {
        pendingJumpTarget = nil
    }

    func stageReturnContext(_ context: LearnReturnContext?) {
        stagedReturnContext = context
    }

    func restoreContext() {
        guard let stagedReturnContext else { return }
        mode = stagedReturnContext.mode
        activeChapter = stagedReturnContext.chapter
        lastAtlasAnchor = stagedReturnContext.atlasAnchor
    }

    var currentContext: LearnReturnContext {
        LearnReturnContext(
            mode: mode,
            chapter: activeChapter,
            atlasAnchor: lastAtlasAnchor
        )
    }

    var effectiveStageSnapshot: StageSnapshotPayload? {
        if let stageSnapshot {
            return stageSnapshot
        }
        if let stageVisualFallback {
            return .synthetic(from: stageVisualFallback)
        }
        return nil
    }

    private func refreshStageFeedState(now: Date = Date()) {
        let connected: Bool
        if case .connected = harnessClient.connectionState {
            connected = true
        } else {
            connected = false
        }

        let next: StageFeedState
        if connected,
           let lastStageSnapshotAt,
           now.timeIntervalSince(lastStageSnapshotAt) <= 1.5 {
            next = .live
        } else if connected, (lastStageSnapshotAt != nil || lastVisualAt != nil) {
            let lastSeen = max(lastStageSnapshotAt ?? .distantPast, lastVisualAt ?? .distantPast)
            next = now.timeIntervalSince(lastSeen) <= 4.0 ? .degraded : .standby
        } else {
            next = .standby
        }

        if stageFeedState != next {
            stageFeedState = next
        }
    }
}

struct ReadLearnView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @StateObject private var viewModel: LearnViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appState: TubCompanionAppState, harnessClient: HarnessClient) {
        self.appState = appState
        self.harnessClient = harnessClient
        _viewModel = StateObject(wrappedValue: LearnViewModel(harnessClient: harnessClient))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    headerStrip
                    CommandSignalRule()
                    ritualDeck(viewportHeight: max(proxy.size.height * 0.76, 620))
                }
                .padding(.horizontal, 16)
                .padding(.top, max(proxy.safeAreaInsets.top + 8, 14))
                .padding(.bottom, max(proxy.safeAreaInsets.bottom + 10, 14))
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("learn.root")
        .onAppear {
            viewModel.stageReturnContext(appState.learnReturnContext)
            viewModel.restoreContext()
        }
        .onChange(of: appState.learnReturnContext) { _, context in
            viewModel.stageReturnContext(context)
            viewModel.restoreContext()
        }
        .onChange(of: viewModel.pendingJumpTarget) { _, target in
            guard let target else { return }
            appState.storeLearnReturnContext(viewModel.currentContext)
            appState.requestTabNavigation(target.appTab)
            viewModel.consumePendingJumpTarget()
        }
    }

    private var headerStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TUBCORP ENTERPRISE SCLI")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(Color.white.opacity(0.68))
                    Text("OPERATOR ORIENTATION MANUAL")
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                        .chromaticAberration()
                }
            }

            Text("WELCOME TO TUBCORP // READ BEFORE OPERATION")
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.56))
                .tracking(1.3)

            Text("LINK \(appState.harnessConnectionState == .connected ? "CONNECTED" : "OFFLINE") // STAGE FEED \(viewModel.stageFeedState.chipLabel)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
                .tracking(1.0)
                .textCase(.uppercase)
                .accessibilityIdentifier("learn.status.line")
        }
        .padding(.vertical, 8)
    }

    private func ritualDeck(viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear
                        .frame(height: 1)
                        .id("learn.ritual.top")

                    ritualManualHeader

                    CommandSignalRule(opacity: 0.16)

                    ritualTableOfContents(proxy: proxy)

                    CommandSignalRule(opacity: 0.16)

                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(LearnChapter.allCases, id: \.self) { chapter in
                            let spec = viewModel.spec(for: chapter)
                            let index = (LearnChapter.allCases.firstIndex(of: chapter) ?? 0) + 1
                            RitualSectionView(
                                sectionNumber: index,
                                spec: spec,
                                isActive: chapter == viewModel.activeChapter
                            )
                            .id(ritualAnchorID(for: chapter))
                        }
                    }

                    CommandSignalRule(opacity: 0.16)

                    Text("REFERENCE ATLAS")
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                        .foregroundStyle(.white)
                        .tracking(1.1)

                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(viewModel.atlasSections) { section in
                            AtlasInlineSectionView(section: section)
                                .id(section.id)
                                .accessibilityIdentifier("learn.atlas.section.\(section.id)")
                        }
                    }

                    CommandSignalRule(opacity: 0.16)

                    HStack(spacing: 10) {
                        commandButton(
                            title: "JUMP STEER",
                            action: viewModel.jumpToSteer,
                            identifier: "learn.command.jumpSteer",
                            accessibilityHint: "Open the Steer tab now"
                        )
                        commandButton(
                            title: "JUMP PLAY",
                            action: viewModel.jumpToPlay,
                            identifier: "learn.command.jumpPlay",
                            accessibilityHint: "Open the Play tab now"
                        )
                    }
                    .padding(.bottom, 10)
                }
            }
            .frame(minHeight: min(max(viewportHeight * 0.86, 560), 980))
            .onAppear {
                scrollRitual(to: viewModel.activeChapter, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.activeChapter) { _, chapter in
                scrollRitual(to: chapter, proxy: proxy)
            }
        }
        .accessibilityIdentifier("learn.ritual.deck")
    }

    private var ritualManualHeader: some View {
        let activeSpec = viewModel.spec(for: viewModel.activeChapter)
        let activeIndex = (LearnChapter.allCases.firstIndex(of: viewModel.activeChapter) ?? 0) + 1

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ONE-PAGE ORIENTATION")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(BrandingColors.glyphGreen.opacity(0.9))
                    .tracking(1.3)
                Spacer()
                Text("SECTION \(activeIndex)/\(LearnChapter.allCases.count)")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .tracking(1.2)
                    .accessibilityIdentifier("learn.ritual.chapter.meta")
            }

            Text(activeSpec.title)
                .font(.system(.title2, design: .monospaced, weight: .bold))
                .foregroundStyle(.white)
                .tracking(1.2)
                .chromaticAberration()
                .accessibilityIdentifier("learn.ritual.chapter.title")

            Text("READ TOP TO BOTTOM. ORIENTATION FIRST, REFERENCE SECOND.")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.74))
                .tracking(1.0)
                .textCase(.uppercase)
                .accessibilityIdentifier("learn.ritual.chapter.copy")
        }
    }

    private func ritualTableOfContents(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TABLE OF CONTENTS")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.62))
                .tracking(1.4)

            ForEach(LearnChapter.allCases, id: \.self) { chapter in
                let spec = viewModel.spec(for: chapter)
                let isActive = chapter == viewModel.activeChapter
                let chapterIndex = (LearnChapter.allCases.firstIndex(of: chapter) ?? 0) + 1
                Button {
                    viewModel.activeChapter = chapter
                    scrollRitual(to: chapter, proxy: proxy)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(chapterIndex).")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.66))
                        Text(spec.title)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.84))
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("learn.ritual.toc.\(chapter.rawValue)")
                .accessibilityLabel("\(chapterIndex). \(spec.title.lowercased())")
                .accessibilityHint("Jump to this briefing section")
            }
        }
    }

    private func atlasDeck(viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                atlasIndex(proxy: proxy)
                    .padding(.top, 6)

                CommandSignalRule(opacity: 0.16)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(viewModel.atlasSections) { section in
                            AtlasSectionView(section: section, viewportHeight: viewportHeight)
                                .id(section.id)
                                .accessibilityIdentifier("learn.atlas.section.\(section.id)")
                        }
                    }
                    .padding(.vertical, 10)
                }
                .accessibilityIdentifier("learn.atlas.scroll")
            }
            .onAppear {
                scrollAtlasToCurrentAnchor(proxy: proxy)
            }
            .onChange(of: viewModel.lastAtlasAnchor) { _, _ in
                scrollAtlasToCurrentAnchor(proxy: proxy)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("learn.atlas.deck")
    }

    private func atlasIndex(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.atlasSections) { section in
                    let isSelected = viewModel.lastAtlasAnchor == section.id
                    Button {
                        viewModel.setAtlasAnchor(section.id)
                        scrollAtlasToCurrentAnchor(proxy: proxy)
                    } label: {
                        Text(section.title)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(isSelected ? BrandingColors.aberrationCyan : Color.white.opacity(0.72))
                            .tracking(1.0)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .overlay {
                                Rectangle()
                                    .stroke(
                                        isSelected
                                        ? BrandingColors.aberrationCyan.opacity(0.7)
                                        : Color.white.opacity(0.2),
                                        lineWidth: 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("learn.atlas.anchor.\(section.id)")
                    .accessibilityLabel(section.title.lowercased())
                    .accessibilityHint("Jump to this manual section")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func ritualAnchorID(for chapter: LearnChapter) -> String {
        "learn.ritual.section.\(chapter.rawValue)"
    }

    private func scrollRitual(to chapter: LearnChapter, proxy: ScrollViewProxy, animated: Bool = true) {
        let id = ritualAnchorID(for: chapter)
        DispatchQueue.main.async {
            if reduceMotion || !animated {
                proxy.scrollTo(id, anchor: .top)
            } else {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    private var commandRail: some View {
        VStack(spacing: 10) {
            if viewModel.mode == .ritual {
                HStack(spacing: 10) {
                    commandButton(
                        title: "SCROLL TOP",
                        action: { viewModel.activeChapter = .enter },
                        identifier: "learn.command.top",
                        accessibilityHint: "Jump to the top section"
                    )
                }

                HStack(spacing: 10) {
                    commandButton(
                        title: "SKIP TO MANUAL",
                        action: viewModel.skipToAtlas,
                        identifier: "learn.command.skipAtlas",
                        accessibilityHint: "Open manual mode"
                    )
                    commandButton(
                        title: "JUMP STEER",
                        action: viewModel.jumpToSteer,
                        identifier: "learn.command.jumpSteer",
                        accessibilityHint: "Open the Steer tab now"
                    )
                    commandButton(
                        title: "JUMP PLAY",
                        action: viewModel.jumpToPlay,
                        identifier: "learn.command.jumpPlay",
                        accessibilityHint: "Open the Play tab now"
                    )
                }
            } else {
                HStack(spacing: 10) {
                    commandButton(
                        title: "RETURN TO BRIEFING",
                        action: { viewModel.setMode(.ritual) },
                        identifier: "learn.command.returnRitual",
                        accessibilityHint: "Return to guided briefing mode"
                    )
                    commandButton(
                        title: "JUMP STEER",
                        action: viewModel.jumpToSteer,
                        identifier: "learn.command.jumpSteer",
                        accessibilityHint: "Open the Steer tab now"
                    )
                    commandButton(
                        title: "JUMP PLAY",
                        action: viewModel.jumpToPlay,
                        identifier: "learn.command.jumpPlay",
                        accessibilityHint: "Open the Play tab now"
                    )
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("learn.command.rail")
    }

    private func commandButton(
        title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        identifier: String,
        accessibilityHint: String
    ) -> some View {
        CommandRailButton(
            title: title,
            isEnabled: isEnabled,
            isActive: false,
            accent: BrandingColors.glyphGreen,
            action: action
        )
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title.lowercased())
        .accessibilityHint(accessibilityHint)
    }

    private func scrollAtlasToCurrentAnchor(proxy: ScrollViewProxy) {
        guard let anchor = viewModel.lastAtlasAnchor else { return }
        DispatchQueue.main.async {
            if reduceMotion {
                proxy.scrollTo(anchor, anchor: .top)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }
}

private struct OperatorBlock: View {
    let title: String
    let lines: [String]
    let accent: Color
    var emphasizeMonospace: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(accent.opacity(0.9))
                    .frame(width: 3, height: 12)
                Text(title)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(accent.opacity(0.9))
                    .tracking(1.4)
            }

            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: emphasizeMonospace ? 12 : 13, weight: emphasizeMonospace ? .semibold : .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .textCase(.uppercase)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .overlay {
            Rectangle()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct RitualSectionView: View {
    let sectionNumber: Int
    let spec: LearnChapterSpec
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%02d", sectionNumber))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.72))
                    .tracking(1.2)

                Text(spec.title)
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .foregroundStyle(.white)
                    .tracking(1.0)
                    .chromaticAberration()

                Spacer()

                if isActive {
                    Text("ACTIVE")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(BrandingColors.glyphGreen.opacity(0.9))
                        .tracking(1.2)
                }
            }

            Text(spec.subtitle)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(BrandingColors.aberrationCyan.opacity(0.82))
                .tracking(1.4)

            OperatorBlock(
                title: "SYSTEM BRIEF",
                lines: spec.briefLines,
                accent: BrandingColors.glyphGreen
            )

            OperatorBlock(
                title: "OPERATING NOTES",
                lines: spec.operationsLines,
                accent: BrandingColors.warningYellow
            )

            OperatorBlock(
                title: "SCLI REFERENCE",
                lines: spec.commandLines,
                accent: BrandingColors.aberrationCyan,
                emphasizeMonospace: true
            )

            if let jumpTarget = spec.jumpTarget {
                Text("VECTOR: \(jumpTarget.commandTitle)")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .tracking(1.3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .overlay {
            Rectangle()
                .stroke(
                    isActive
                    ? BrandingColors.glyphGreen.opacity(0.5)
                    : Color.white.opacity(0.16),
                    lineWidth: 1
                )
        }
    }
}

private struct AtlasSectionView: View {
    let section: LearnAtlasSection
    let viewportHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommandSignalRule(opacity: 0.16)

            Text(section.title)
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .foregroundStyle(.white)
                .tracking(1.0)

            ForEach(section.body, id: \.self) { line in
                Text(line)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .textCase(.uppercase)
            }

            OperatorBlock(
                title: "SCLI",
                lines: section.commands,
                accent: BrandingColors.aberrationCyan,
                emphasizeMonospace: true
            )
            .frame(minHeight: min(max(viewportHeight * 0.15, 100), 180))
        }
    }
}

private struct AtlasInlineSectionView: View {
    let section: LearnAtlasSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(.headline, design: .monospaced, weight: .bold))
                .foregroundStyle(BrandingColors.aberrationCyan.opacity(0.92))
                .tracking(1.1)

            ForEach(section.body, id: \.self) { line in
                Text("- \(line)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .textCase(.uppercase)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("COMMANDS")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.56))
                .tracking(1.2)
                .padding(.top, 2)

            ForEach(section.commands, id: \.self) { command in
                Text(command)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }

            CommandSignalRule(opacity: 0.12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LearnStageMirrorBackground: View {
    let snapshot: StageSnapshotPayload?
    let feedState: StageFeedState
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? (1.0 / 10.0) : (1.0 / 24.0))) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let surface = snapshot ?? .standby

            ZStack {
                Color.black.ignoresSafeArea()

                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.fill(Path(rect), with: .color(.black))
                    drawScanlines(context: &context, size: size)
                    drawGrid(context: &context, size: size, density: surface.density)
                    drawTopology(
                        context: &context,
                        size: size,
                        sceneId: surface.sceneId,
                        t: t,
                        disruption: surface.disruption
                    )
                    drawNoise(
                        context: &context,
                        size: size,
                        t: t,
                        disruption: surface.disruption,
                        brightness: surface.audio.brightness
                    )
                }
                .ignoresSafeArea()
                .opacity(0.92)

                VStack(spacing: 0) {
                    HStack {
                        Text("STAGE MIRROR // \(feedState.chipLabel)")
                        Spacer()
                        Text("SCENE \(surface.sceneId.uppercased())")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.white.opacity(0.44))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    Spacer()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(surface.thought.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(BrandingColors.glyphGreen.opacity(0.72))
                            .tracking(1.1)
                            .chromaticAberration()

                        ForEach(Array(surface.thoughtLog.prefix(4)), id: \.self) { line in
                            Text(line.uppercased())
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.42))
                                .tracking(1.0)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func drawScanlines(context: inout GraphicsContext, size: CGSize) {
        var lines = Path()
        stride(from: CGFloat(0), through: size.height, by: 6).forEach { y in
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(Color.white.opacity(0.02)), lineWidth: 0.5)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize, density: Double) {
        var grid = Path()
        let spacing = max(44, 108 - CGFloat(max(0, min(1, density)) * 48))
        stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(Color.white.opacity(0.06)), lineWidth: 1)
    }

    private func drawTopology(
        context: inout GraphicsContext,
        size: CGSize,
        sceneId: String,
        t: TimeInterval,
        disruption: Double
    ) {
        let normalized = max(0, min(1, disruption))
        let color = (normalized > 0.5 ? BrandingColors.warningYellow : BrandingColors.glyphGreen)
            .opacity(0.20 + normalized * 0.22)

        switch sceneId {
        case "relay_mesh":
            var path = Path()
            let anchors = [
                CGPoint(x: size.width * 0.2, y: size.height * 0.5),
                CGPoint(x: size.width * 0.5, y: size.height * 0.38),
                CGPoint(x: size.width * 0.8, y: size.height * 0.5)
            ]
            path.move(to: anchors[0])
            path.addLine(to: anchors[1])
            path.addLine(to: anchors[2])
            context.stroke(path, with: .color(color), lineWidth: 2)
        case "fault_lattice", "alarm_splay":
            var path = Path()
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            for i in 0..<5 {
                let angle = Double(i) * (.pi / 2.5) + (reduceMotion ? 0 : Darwin.sin(t * 0.8) * 0.12)
                let radius = min(size.width, size.height) * 0.34
                let point = CGPoint(
                    x: center.x + CGFloat(Darwin.cos(angle)) * radius,
                    y: center.y + CGFloat(Darwin.sin(angle)) * radius
                )
                path.move(to: center)
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(color), lineWidth: 2.2)
        default:
            var path = Path()
            let y = size.height * 0.52
            path.move(to: CGPoint(x: size.width * 0.08, y: y))
            path.addLine(to: CGPoint(x: size.width * 0.92, y: y))
            context.stroke(path, with: .color(color), lineWidth: 1.6)
        }
    }

    private func drawNoise(
        context: inout GraphicsContext,
        size: CGSize,
        t: TimeInterval,
        disruption: Double,
        brightness: Double
    ) {
        let count = 14 + Int(max(0, min(1, disruption)) * 26)
        for index in 0..<count {
            let seed = Double(index) * 0.31 + t * (reduceMotion ? 0.2 : 0.9)
            let x = (Darwin.sin(seed * 2.3) * 0.5 + 0.5) * size.width
            let y = (Darwin.cos(seed * 1.7) * 0.5 + 0.5) * size.height
            let width = CGFloat(8 + (Darwin.sin(seed * 0.9) * 0.5 + 0.5) * 22)
            let rect = CGRect(x: x, y: y, width: width, height: 1)
            let color = BrandingColors.aberrationCyan.opacity(0.03 + max(0, min(1, brightness)) * 0.06)
            context.fill(Path(rect), with: .color(color))
        }
    }
}

private extension StageSnapshotPayload {
    static let standby = StageSnapshotPayload(
        mode: 0,
        sceneId: "quiet_watch",
        thought: "idle",
        thoughtLog: ["QUIET WATCH"],
        density: 0.16,
        cohesion: 0.62,
        disruption: 0.12,
        isRunning: false,
        isWaiting: false,
        waitingReason: nil,
        paramLines: [],
        pickLines: [],
        changeLines: [],
        audio: StageAudioSummaryPayload(
            rms: 0,
            transientFlux: 0,
            lowBand: 0,
            midBand: 0,
            highBand: 0,
            peak: 0,
            brightness: 0,
            overloadPulse: 0
        ),
        joltHeld: false,
        timestamp: .distantPast
    )

    static func synthetic(from visual: VisualOutput) -> StageSnapshotPayload {
        StageSnapshotPayload(
            mode: 0,
            sceneId: visual.sceneId,
            thought: visual.thought,
            thoughtLog: [visual.thought],
            density: visual.density,
            cohesion: visual.cohesion,
            disruption: visual.disruption,
            isRunning: true,
            isWaiting: false,
            waitingReason: nil,
            paramLines: [],
            pickLines: [],
            changeLines: [],
            audio: StageAudioSummaryPayload(
                rms: 0,
                transientFlux: 0,
                lowBand: 0,
                midBand: 0,
                highBand: 0,
                peak: 0,
                brightness: 0,
                overloadPulse: 0
            ),
            joltHeld: false,
            timestamp: Date()
        )
    }
}
