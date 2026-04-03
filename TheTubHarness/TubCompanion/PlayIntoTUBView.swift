//
//  PlayIntoTUBView.swift
//  TubCompanion
//
//  Minimal Play surface:
//  one square 2D grid that triggers one-shot samples to the active output route.
//

import SwiftUI
import Combine
import UIKit

@MainActor
struct PlayIntoTUBView: View {
    @ObservedObject var appState: TubCompanionAppState
    @ObservedObject var harnessClient: HarnessClient
    @ObservedObject var externalAudioRouteMonitor: ExternalAudioRouteMonitor

    @StateObject private var viewModel = PlayGridViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayGridScanlines().ignoresSafeArea().opacity(0.22)

            VStack(alignment: .leading, spacing: 14) {
                header
                chips
                gridSurface
                CommandSignalRule(opacity: 0.2)
                footer
                CommandSignalRule(opacity: 0.2)
                longStripSurface
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)

            if appState.shouldPresentOverlay(for: .play) {
                ConnectionRequiredOverlay(
                    appState: appState,
                    harnessClient: harnessClient,
                    externalAudioRouteMonitor: externalAudioRouteMonitor,
                    preferredIntent: .playLive
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.start(using: appState)
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.setScenePhase(phase)
        }
        .onChange(of: appState.isExternalAudioRouteActive) { _, _ in
            viewModel.updateRoute(using: appState)
        }
        .onChange(of: appState.isDebugOutputSimulated) { _, _ in
            viewModel.updateRoute(using: appState)
        }
        .onChange(of: appState.isCableRouteSimulated) { _, _ in
            viewModel.updateRoute(using: appState)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PLAY")
                .playMono(12, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.7))
            Text("LIVE SAMPLE GRID")
                .playMono(28, weight: .bold)
                .foregroundStyle(BrandingColors.glyphGreen)
                .chromaticAberration()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            PlayStatusChip(
                title: "LINK",
                value: viewModel.linkStatus,
                tone: viewModel.linkTone
            )
            PlayStatusChip(
                title: "OUTPUT",
                value: viewModel.outputStatus,
                tone: viewModel.outputTone
            )
            PlayStatusChip(
                title: "SOURCE",
                value: viewModel.libraryStatus,
                tone: viewModel.libraryTone
            )
            PlayStatusChip(
                title: "DEBUG",
                value: viewModel.debugStatus,
                tone: viewModel.debugTone
            )
        }
    }

    private var gridSurface: some View {
        GeometryReader { proxy in
            let side = max(1, proxy.size.width)
            let cell = side / CGFloat(viewModel.gridDimension)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.black.opacity(0.7))
                Rectangle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)

                ForEach(viewModel.cells) { gridCell in
                    let x = CGFloat(gridCell.column) * cell
                    let y = CGFloat(gridCell.row) * cell

                    ZStack {
                        Rectangle()
                            .stroke(Color.white.opacity(0.13), lineWidth: 0.8)
                            .background(
                                Rectangle()
                                    .fill(viewModel.isCellActive(gridCell) ? BrandingColors.glyphGreen.opacity(0.22) : Color.clear)
                            )

                        Text(gridCell.displayToken)
                            .playMono(12, weight: .semibold)
                            .foregroundStyle(viewModel.isCellActive(gridCell) ? BrandingColors.glyphGreen : Color.white.opacity(0.68))
                    }
                    .frame(width: cell, height: cell)
                    .offset(x: x, y: y)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .overlay {
                PlayMultiTouchCaptureView(
                    onTouchesChanged: { touches in
                        viewModel.handleTouches(touches, in: CGSize(width: side, height: side))
                    },
                    onTouchesEnded: {
                        viewModel.endTouch()
                    }
                )
                .allowsHitTesting(true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        viewModel.handleTouch(value.location, in: CGSize(width: side, height: side))
                    }
                    .onEnded { _ in
                        viewModel.endTouch()
                    }
            )
            .opacity(viewModel.canOutput ? 1 : 0.6)
            .overlay(alignment: .center) {
                if !viewModel.canOutput {
                    Text("NO AUDIO ROUTE. CONNECT LINK OR ENABLE DEBUG OUTPUT.")
                        .playMono(12, weight: .bold)
                        .foregroundStyle(BrandingColors.warningYellow)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.88))
                        .overlay {
                            Rectangle()
                                .stroke(BrandingColors.warningYellow.opacity(0.6), lineWidth: 1)
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PLAY GRID")
            .accessibilityHint("DRAG ACROSS GRID CELLS TO TRIGGER AUDIO EVENTS.")
            .accessibilityIdentifier("play.grid.surface")
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }

    private var longStripSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("LONG SOUNDS GRADIENT STRIP")
                    .playMono(11, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
                Text("BANK \(viewModel.longBankStatus)")
                    .playMono(10, weight: .bold)
                    .foregroundStyle(BrandingColors.glyphGreen)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("play.long.bank.status")
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let height = max(1, proxy.size.height)
                let slotWidth = width / CGFloat(max(1, viewModel.longStripSlotCount))

                ZStack(alignment: .topLeading) {
                    LinearGradient(
                        colors: [
                            BrandingColors.glyphGreen.opacity(0.05),
                            BrandingColors.warningYellow.opacity(0.07),
                            BrandingColors.glyphGreen.opacity(0.04)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    Rectangle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)

                    ForEach(viewModel.longStripCells) { cell in
                        let x = CGFloat(cell.slotIndex) * slotWidth

                        Rectangle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                            .frame(width: slotWidth, height: height)
                            .offset(x: x)

                        if viewModel.isLongSlotActive(cell.slotIndex) {
                            Rectangle()
                                .stroke(BrandingColors.glyphGreen.opacity(0.9), lineWidth: 1.4)
                                .frame(width: slotWidth, height: height)
                                .offset(x: x)
                        }

                        Text(cell.displayToken)
                            .playMono(10, weight: .bold)
                            .foregroundStyle(cell.hasSample ? Color.white.opacity(0.72) : Color.white.opacity(0.3))
                            .frame(width: slotWidth, height: height, alignment: .bottom)
                            .padding(.bottom, 7)
                            .offset(x: x)
                    }
                }
                .contentShape(Rectangle())
                .overlay {
                    PlayMultiTouchCaptureView(
                        onTouchesChanged: { touches in
                            viewModel.handleLongTouches(touches, in: CGSize(width: width, height: height))
                        },
                        onTouchesEnded: {
                            viewModel.endLongTouch()
                        }
                    )
                    .allowsHitTesting(true)
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            viewModel.handleLongTouch(value.location, in: CGSize(width: width, height: height))
                        }
                        .onEnded { _ in
                            viewModel.endLongTouch()
                        }
                )
                .opacity(viewModel.canOutput ? 1 : 0.6)
                .overlay(alignment: .center) {
                    if !viewModel.canOutput {
                        Text("NO AUDIO ROUTE.")
                            .playMono(11, weight: .bold)
                            .foregroundStyle(BrandingColors.warningYellow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.88))
                            .overlay {
                                Rectangle()
                                    .stroke(BrandingColors.warningYellow.opacity(0.6), lineWidth: 1)
                            }
                    }
                }
            }
            .frame(height: 86)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("LONG SOUNDS GRADIENT STRIP")
            .accessibilityHint("TOUCH OR DRAG HORIZONTALLY TO SELECT LONG SAMPLE PLAYBACK.")
            .accessibilityIdentifier("play.long.strip.surface")

            CommandSignalRule(opacity: 0.2)

            HStack(spacing: 8) {
                Button(action: viewModel.previousLongBank) {
                    Text("LONG -")
                        .playMono(11, weight: .bold)
                        .foregroundStyle(Color.white.opacity(viewModel.hasMultipleLongBanks ? 0.86 : 0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.black)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(viewModel.hasMultipleLongBanks ? 0.42 : 0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasMultipleLongBanks)
                .accessibilityIdentifier("play.long.bank.previous")
                .accessibilityLabel("Previous Long Sample Bank")

                Button(action: viewModel.stopLong) {
                    Text("STOP LONG")
                        .playMono(11, weight: .bold)
                        .foregroundStyle(Color.white.opacity(viewModel.hasActiveLongSample ? 0.86 : 0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.black)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(viewModel.hasActiveLongSample ? 0.42 : 0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasActiveLongSample)
                .accessibilityIdentifier("play.long.stop")
                .accessibilityLabel("Stop Long Sample")

                Button(action: viewModel.nextLongBank) {
                    Text("LONG +")
                        .playMono(11, weight: .bold)
                        .foregroundStyle(Color.white.opacity(viewModel.hasMultipleLongBanks ? 0.86 : 0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.black)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(viewModel.hasMultipleLongBanks ? 0.42 : 0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasMultipleLongBanks)
                .accessibilityIdentifier("play.long.bank.next")
                .accessibilityLabel("Next Long Sample Bank")
            }

            HStack(spacing: 8) {
                Text("LONG")
                    .playMono(10, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.5))
                Text(viewModel.activeLongLabel)
                    .playMono(11, weight: .bold)
                    .foregroundStyle(BrandingColors.glyphGreen)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
                Spacer(minLength: 8)
                Text(viewModel.longElapsedLabel)
                    .playMono(11, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.76))
            }

            Text(viewModel.longActivityLine)
                .playMono(10, weight: .regular)
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: viewModel.previousBank) {
                    Text("BANK -")
                        .playMono(11, weight: .bold)
                        .foregroundStyle(Color.white.opacity(viewModel.hasMultipleBanks ? 0.86 : 0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.black)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(viewModel.hasMultipleBanks ? 0.42 : 0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasMultipleBanks)
                .accessibilityIdentifier("play.grid.bank.previous")
                .accessibilityLabel("Previous Sample Bank")

                Text("BANK \(viewModel.bankStatus)")
                    .playMono(11, weight: .bold)
                    .foregroundStyle(BrandingColors.glyphGreen)
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .accessibilityIdentifier("play.grid.bank.status")

                Button(action: viewModel.nextBank) {
                    Text("BANK +")
                        .playMono(11, weight: .bold)
                        .foregroundStyle(Color.white.opacity(viewModel.hasMultipleBanks ? 0.86 : 0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.black)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(viewModel.hasMultipleBanks ? 0.42 : 0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasMultipleBanks)
                .accessibilityIdentifier("play.grid.bank.next")
                .accessibilityLabel("Next Sample Bank")
            }

            HStack(spacing: 8) {
                Text("LAST")
                    .playMono(10, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.5))
                Text(viewModel.lastEventLabel)
                    .playMono(12, weight: .bold)
                    .foregroundStyle(BrandingColors.glyphGreen)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(viewModel.activityLine)
                .playMono(10, weight: .regular)
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

@MainActor
private final class PlayGridViewModel: ObservableObject {
    let gridDimension = 6
    let longStripSlotCount = PlayLongStripLayout.defaultSlotCount

    @Published private(set) var cells: [PlayGridCell] = []
    @Published private(set) var longStripCells: [LongStripCell] = []
    @Published private(set) var lastEventLabel = "—"
    @Published private(set) var activeLongLabel = "—"
    @Published private(set) var longElapsedLabel = "00:00.0"
    @Published private(set) var activityLine = "DRAG THROUGH CELLS TO FIRE EVENTS."
    @Published private(set) var longActivityLine = "LONG STRIP IDLE."
    @Published private(set) var linkStatus = "MISSING"
    @Published private(set) var outputStatus = "OFF"
    @Published private(set) var libraryStatus = "SCAN…"
    @Published private(set) var bankStatus = "01/01"
    @Published private(set) var longBankStatus = "01/01"
    @Published private(set) var debugStatus = "OFF"
    @Published private(set) var canOutput = false

    private let audio = PlayGridAudioEngine()
    private var sampleURLs: [URL] = []
    private var longSampleEntries: [PlayLongSampleEntry] = []
    private var bankSampleURLs: [[URL]] = []
    private var longBanks: [[LongStripCell]] = []
    private var activeBankIndex = 0
    private var activeLongBankIndex = 0
    private var activeCellIDs: Set<PlayGridCell.ID> = []
    private var activeTouchCellIDByTouch: [Int: PlayGridCell.ID] = [:]
    private var lastTriggerCellIDByTouch: [Int: PlayGridCell.ID] = [:]
    private var lastTriggerAtByTouch: [Int: Date] = [:]
    private var activeLongSlotIndex: Int?
    private var lastLongTouchSlot: Int?
    private var activeLongURL: URL?
    private var longStartedAt: Date?
    private var longElapsedTicker: AnyCancellable?
    private var didStart = false

    init() {
        self.cells = Self.makeCells(gridDimension: gridDimension)
        self.longStripCells = PlayLongStripLayout.emptyBank(slotCount: longStripSlotCount)
    }

    func start(using appState: TubCompanionAppState) {
        guard !didStart else { return }
        didStart = true
        updateRoute(using: appState)
        loadSampleLibrary()
    }

    func setScenePhase(_ phase: ScenePhase) {
        if phase != .active {
            endTouch()
            audio.stopAll()
            endLongTouch()
            stopLong()
        }
    }

    func updateRoute(using appState: TubCompanionAppState) {
        let connected = appState.isExternalAudioRouteActive || appState.isCableRouteSimulated || appState.isCablePathSatisfied
        let debugSpeaker = appState.isDebugOutputSimulated && !connected

        linkStatus = appState.isCableRouteSimulated ? "SIMULATED" : (connected ? "CONNECTED" : "MISSING")
        outputStatus = connected ? "INTERFACE" : (debugSpeaker ? "SPEAKER" : "OFF")
        debugStatus = debugSpeaker || appState.isCableRouteSimulated ? "ON" : "OFF"
        canOutput = connected || debugSpeaker

        audio.setOutputPolicy(allowSpeakerFallback: debugSpeaker, prefersExternal: connected)
        if !canOutput {
            endTouch()
            endLongTouch()
            audio.stopAll()
            stopLong()
        }
    }

    func handleTouch(_ point: CGPoint, in size: CGSize) {
        handleTouches([PlayTouchPoint(id: 0, location: point)], in: size)
    }

    func handleTouches(_ touches: [PlayTouchPoint], in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard !touches.isEmpty else {
            endTouch()
            return
        }

        let activeTouchIDs = Set(touches.map(\.id))
        activeTouchCellIDByTouch = activeTouchCellIDByTouch.filter { activeTouchIDs.contains($0.key) }
        lastTriggerCellIDByTouch = lastTriggerCellIDByTouch.filter { activeTouchIDs.contains($0.key) }
        lastTriggerAtByTouch = lastTriggerAtByTouch.filter { activeTouchIDs.contains($0.key) }

        for touch in touches {
            let col = max(0, min(gridDimension - 1, Int((touch.location.x / size.width) * CGFloat(gridDimension))))
            let row = max(0, min(gridDimension - 1, Int((touch.location.y / size.height) * CGFloat(gridDimension))))
            let id = PlayGridCell.makeID(row: row, column: col)
            activeTouchCellIDByTouch[touch.id] = id

            let now = Date()
            let lastID = lastTriggerCellIDByTouch[touch.id]
            let lastAt = lastTriggerAtByTouch[touch.id] ?? .distantPast
            let shouldRetriggerSameCell = id == lastID && now.timeIntervalSince(lastAt) >= 0.18
            let shouldTriggerNewCell = id != lastID
            guard shouldTriggerNewCell || shouldRetriggerSameCell else { continue }

            trigger(row: row, column: col)
            lastTriggerCellIDByTouch[touch.id] = id
            lastTriggerAtByTouch[touch.id] = now
        }

        activeCellIDs = Set(activeTouchCellIDByTouch.values)
    }

    func endTouch() {
        activeCellIDs.removeAll()
        activeTouchCellIDByTouch.removeAll()
        lastTriggerCellIDByTouch.removeAll()
        lastTriggerAtByTouch.removeAll()
    }

    func handleLongTouch(_ point: CGPoint, in size: CGSize) {
        handleLongTouches([PlayTouchPoint(id: 0, location: point)], in: size)
    }

    func handleLongTouches(_ touches: [PlayTouchPoint], in size: CGSize) {
        guard !longBanks.isEmpty else {
            longActivityLine = "LONG EMPTY. NO STRIP EVENTS."
            return
        }
        guard let touch = touches.first else { return }

        let slot = PlayLongStripLayout.slotIndex(for: touch.location, in: size, slotCount: longStripSlotCount)
        guard slot != lastLongTouchSlot else { return }
        lastLongTouchSlot = slot
        triggerLong(slotIndex: slot)
    }

    func endLongTouch() {
        lastLongTouchSlot = nil
    }

    func isCellActive(_ cell: PlayGridCell) -> Bool {
        activeCellIDs.contains(cell.id)
    }

    var linkTone: PlayChipTone {
        linkStatus == "CONNECTED" || linkStatus == "SIMULATED" ? .good : .warn
    }

    var outputTone: PlayChipTone {
        canOutput ? .good : .warn
    }

    var libraryTone: PlayChipTone {
        sampleURLs.isEmpty && longSampleEntries.isEmpty ? .warn : .good
    }

    var debugTone: PlayChipTone {
        debugStatus == "ON" ? .warn : .neutral
    }

    var hasMultipleBanks: Bool {
        bankSampleURLs.count > 1
    }

    var hasMultipleLongBanks: Bool {
        longBanks.count > 1
    }

    var hasActiveLongSample: Bool {
        activeLongURL != nil
    }

    func nextBank() {
        guard bankSampleURLs.count > 1 else { return }
        activeBankIndex = (activeBankIndex + 1) % bankSampleURLs.count
        updateBankStatus()
        endTouch()
        audio.stopAll()
        activityLine = "BANK \(bankStatus) ARMED."
    }

    func previousBank() {
        guard bankSampleURLs.count > 1 else { return }
        activeBankIndex = (activeBankIndex - 1 + bankSampleURLs.count) % bankSampleURLs.count
        updateBankStatus()
        endTouch()
        audio.stopAll()
        activityLine = "BANK \(bankStatus) ARMED."
    }

    func nextLongBank() {
        guard longBanks.count > 1 else { return }
        activeLongBankIndex = (activeLongBankIndex + 1) % longBanks.count
        updateLongBankStatus()
        endLongTouch()
        stopLong()
        longActivityLine = "LONG BANK \(longBankStatus) ARMED."
    }

    func previousLongBank() {
        guard longBanks.count > 1 else { return }
        activeLongBankIndex = (activeLongBankIndex - 1 + longBanks.count) % longBanks.count
        updateLongBankStatus()
        endLongTouch()
        stopLong()
        longActivityLine = "LONG BANK \(longBankStatus) ARMED."
    }

    func stopLong() {
        audio.stopLong()
        stopLongElapsedTicker()
        activeLongURL = nil
        activeLongSlotIndex = nil
        longStartedAt = nil
        activeLongLabel = "—"
        longElapsedLabel = "00:00.0"
        longActivityLine = "LONG STRIP IDLE."
    }

    private func trigger(row: Int, column: Int) {
        let token = cells.first(where: { $0.row == row && $0.column == column })?.displayToken ?? "??"
        guard !sampleURLs.isEmpty, !bankSampleURLs.isEmpty else {
            activityLine = "SOURCE LIBRARY EMPTY. GRID EVENT SKIPPED."
            lastEventLabel = token
            return
        }

        let cellSerial = row * gridDimension + column
        let activeBank = bankSampleURLs[min(activeBankIndex, bankSampleURLs.count - 1)]
        let url = activeBank[cellSerial % max(1, activeBank.count)]
        let pan = Float((Double(column) / Double(max(gridDimension - 1, 1))) * 2 - 1)
        let gain = Float(0.36 + (1 - (Double(row) / Double(max(gridDimension - 1, 1)))) * 0.52)

        audio.trigger(url: url, pan: pan, gain: gain)

        lastEventLabel = token
        activityLine = "BANK \(bankStatus) / CELL \(row + 1):\(column + 1) -> \(url.deletingPathExtension().lastPathComponent.uppercased())"
    }

    func isLongSlotActive(_ slotIndex: Int) -> Bool {
        activeLongSlotIndex == slotIndex
    }

    private func triggerLong(slotIndex: Int) {
        guard !longBanks.isEmpty else {
            longActivityLine = "LONG EMPTY. NO STRIP EVENTS."
            return
        }
        let bank = longBanks[min(max(0, activeLongBankIndex), longBanks.count - 1)]
        guard slotIndex >= 0, slotIndex < bank.count else { return }
        let cell = bank[slotIndex]
        guard let url = cell.sampleURL else {
            longActivityLine = "SLOT \(cell.displayToken) EMPTY."
            return
        }

        let targetGain: Float = 0.62
        if activeLongURL == nil {
            audio.triggerLong(url: url, gain: targetGain)
        } else if activeLongURL != url {
            audio.transitionLong(to: url, gain: targetGain)
        } else {
            return
        }

        activeLongURL = url
        activeLongSlotIndex = slotIndex
        activeLongLabel = cell.displayName.uppercased()
        longStartedAt = Date()
        updateLongElapsedLabel(now: Date())
        startLongElapsedTicker()
        longActivityLine = "LONG \(longBankStatus) / SLOT \(cell.displayToken) -> \(cell.displayName.uppercased())"
    }

    private func loadSampleLibrary() {
        libraryStatus = "SCAN…"
        Task.detached(priority: .userInitiated) {
            let discovered = PlayGridAudioEngine.discoverSampleLibrary()
            let urls = Self.makeCuratedSampleList(discovered)
            let descriptors = urls.map { url -> PlaySampleDescriptor in
                let duration = PlayGridAudioEngine.sampleDuration(url: url) ?? 0
                let sampleClass = PlaySampleClass.classify(duration: duration, threshold: 4)
                return PlaySampleDescriptor(url: url, duration: duration, sampleClass: sampleClass)
            }
            await MainActor.run {
                self.sampleURLs = descriptors
                    .filter { $0.sampleClass == .short }
                    .map(\.url)
                self.longSampleEntries = descriptors
                    .filter { $0.sampleClass == .long }
                    .map {
                        PlayLongSampleEntry(
                            url: $0.url,
                            duration: $0.duration,
                            displayToken: Self.longToken(for: $0.url),
                            displayName: $0.url.deletingPathExtension().lastPathComponent
                        )
                    }
                self.rebuildBanks()
                self.libraryStatus = Self.libraryStatus(shortCount: self.sampleURLs.count, longCount: self.longSampleEntries.count)
                if self.sampleURLs.isEmpty && self.longSampleEntries.isEmpty {
                    self.activityLine = "NO SAMPLE FILES DISCOVERED IN BUNDLE."
                    self.longActivityLine = "NO LONG SAMPLES DISCOVERED."
                } else if self.sampleURLs.isEmpty {
                    self.activityLine = "SHORT EMPTY. GRID EVENTS DISABLED."
                    self.longActivityLine = "LONG STRIP READY (\(self.longBankStatus))."
                } else if self.longSampleEntries.isEmpty {
                    self.activityLine = "GRID READY (\(self.bankStatus)). DRAG TO PLAY."
                    self.longActivityLine = "LONG EMPTY. SHORT GRID ONLY."
                } else {
                    self.activityLine = "LIBRARY READY (\(self.bankStatus)). DRAG TO PLAY."
                    self.longActivityLine = "LONG READY (\(self.longBankStatus)). TOUCH STRIP."
                }
            }
        }
    }

    private func rebuildBanks() {
        if sampleURLs.isEmpty {
            bankSampleURLs = []
            activeBankIndex = 0
            bankStatus = "01/01"
        } else {
            let cellCount = gridDimension * gridDimension
            let count = sampleURLs.count
            let bankCount = max(1, Int(ceil(Double(count) / Double(max(1, cellCount)))))
            let step = Self.coprimeStep(for: count)
            var banks: [[URL]] = []
            banks.reserveCapacity(bankCount)

            for bank in 0..<bankCount {
                let offset = (bank * cellCount) % count
                var entries: [URL] = []
                entries.reserveCapacity(cellCount)
                for serial in 0..<cellCount {
                    let index = (offset + serial * step) % count
                    entries.append(sampleURLs[index])
                }
                banks.append(entries)
            }

            bankSampleURLs = banks
            activeBankIndex = min(activeBankIndex, banks.count - 1)
            updateBankStatus()
        }

        longBanks = PlayLongStripLayout.makeBanks(entries: longSampleEntries, slotCount: longStripSlotCount)
        if longBanks.isEmpty {
            activeLongBankIndex = 0
            longBankStatus = "01/01"
            longStripCells = PlayLongStripLayout.emptyBank(slotCount: longStripSlotCount)
            activeLongSlotIndex = nil
        } else {
            activeLongBankIndex = min(activeLongBankIndex, longBanks.count - 1)
            updateLongBankStatus()
        }
    }

    private func updateBankStatus() {
        let total = max(1, bankSampleURLs.count)
        let current = min(max(0, activeBankIndex), total - 1) + 1
        bankStatus = String(format: "%02d/%02d", current, total)
    }

    private func updateLongBankStatus() {
        let total = max(1, longBanks.count)
        let current = min(max(0, activeLongBankIndex), total - 1) + 1
        longBankStatus = String(format: "%02d/%02d", current, total)
        if longBanks.isEmpty {
            longStripCells = PlayLongStripLayout.emptyBank(slotCount: longStripSlotCount)
        } else {
            longStripCells = longBanks[min(max(0, activeLongBankIndex), longBanks.count - 1)]
        }
    }

    private static func libraryStatus(shortCount: Int, longCount: Int) -> String {
        if shortCount == 0 && longCount == 0 {
            return "EMPTY"
        }
        return "S\(shortCount)/L\(longCount)"
    }

    private static func longToken(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.uppercased()
        let compact = stem.filter { $0.isLetter || $0.isNumber }
        if compact.count >= 4 {
            return String(compact.prefix(4))
        }
        if compact.isEmpty {
            return "LONG"
        }
        return compact
    }

    private func startLongElapsedTicker() {
        stopLongElapsedTicker()
        longElapsedTicker = Timer
            .publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                guard let self else { return }
                self.updateLongElapsedLabel(now: now)
            }
    }

    private func stopLongElapsedTicker() {
        longElapsedTicker?.cancel()
        longElapsedTicker = nil
    }

    private func updateLongElapsedLabel(now: Date) {
        guard let startedAt = longStartedAt else {
            longElapsedLabel = "00:00.0"
            return
        }
        longElapsedLabel = Self.formatElapsed(now.timeIntervalSince(startedAt))
    }

    private static func formatElapsed(_ value: TimeInterval) -> String {
        let clamped = max(0, value)
        let totalTenths = Int((clamped * 10).rounded(.down))
        let minutes = totalTenths / 600
        let seconds = (totalTenths / 10) % 60
        let tenths = totalTenths % 10
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    nonisolated private static func makeCuratedSampleList(_ urls: [URL]) -> [URL] {
        guard !urls.isEmpty else { return [] }
        var seenResolvedPath = Set<String>()
        var seenIdentity = Set<String>()
        var unique: [URL] = []
        unique.reserveCapacity(urls.count)

        for url in urls {
            let resolvedKey = url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            guard seenResolvedPath.insert(resolvedKey).inserted else { continue }

            let identity = sampleIdentity(url)
            guard seenIdentity.insert(identity).inserted else { continue }
            unique.append(url)
        }

        return unique.sorted {
            sampleSortKey($0) < sampleSortKey($1)
        }
    }

    nonisolated private static func sampleIdentity(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let parts = stem.split(separator: "_", omittingEmptySubsequences: true)
        if parts.count > 1, parts.first?.allSatisfy(\.isNumber) == true {
            return parts.dropFirst().joined(separator: "_")
        }
        return stem
    }

    nonisolated private static func sampleSortKey(_ url: URL) -> String {
        let identity = sampleIdentity(url)
        let hash = fnv1a(identity)
        return String(format: "%08x_%@", hash, identity)
    }

    nonisolated private static func fnv1a(_ value: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    nonisolated private static func coprimeStep(for count: Int) -> Int {
        guard count > 1 else { return 1 }
        var step = max(1, count / 7)
        if step % 2 == 0 { step += 1 }

        while step < count {
            if gcd(step, count) == 1 {
                return step
            }
            step += 2
        }
        return 1
    }

    nonisolated private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return max(1, x)
    }

    private static func makeCells(gridDimension: Int) -> [PlayGridCell] {
        var result: [PlayGridCell] = []
        result.reserveCapacity(gridDimension * gridDimension)

        for row in 0..<gridDimension {
            for column in 0..<gridDimension {
                let serial = row * gridDimension + column
                let token = String(format: "%02X", serial)
                result.append(PlayGridCell(row: row, column: column, displayToken: token))
            }
        }
        return result
    }
}

enum PlaySampleClass: Equatable {
    case short
    case long

    nonisolated static func classify(duration: TimeInterval, threshold: TimeInterval = 4) -> PlaySampleClass {
        duration >= threshold ? .long : .short
    }
}

struct PlaySampleDescriptor: Equatable {
    let url: URL
    let duration: TimeInterval
    let sampleClass: PlaySampleClass
}

struct PlayLongSampleEntry: Equatable {
    let url: URL
    let duration: TimeInterval
    let displayToken: String
    let displayName: String
}

struct LongStripCell: Identifiable, Equatable {
    let slotIndex: Int
    let displayToken: String
    let sampleURL: URL?
    let duration: TimeInterval
    let displayName: String

    var id: Int { slotIndex }
    var hasSample: Bool { sampleURL != nil }
}

enum PlayLongStripLayout {
    static let defaultSlotCount = 12

    static func makeBanks(entries: [PlayLongSampleEntry], slotCount: Int = defaultSlotCount) -> [[LongStripCell]] {
        guard !entries.isEmpty else { return [] }
        let count = max(1, slotCount)
        let bankCount = max(1, Int(ceil(Double(entries.count) / Double(count))))
        var banks: [[LongStripCell]] = []
        banks.reserveCapacity(bankCount)

        for bankIndex in 0..<bankCount {
            let base = bankIndex * count
            var cells: [LongStripCell] = []
            cells.reserveCapacity(count)
            for slot in 0..<count {
                let entryIndex = base + slot
                if entryIndex < entries.count {
                    let entry = entries[entryIndex]
                    cells.append(
                        LongStripCell(
                            slotIndex: slot,
                            displayToken: entry.displayToken,
                            sampleURL: entry.url,
                            duration: entry.duration,
                            displayName: entry.displayName
                        )
                    )
                } else {
                    cells.append(
                        LongStripCell(
                            slotIndex: slot,
                            displayToken: String(format: "%02X", slot),
                            sampleURL: nil,
                            duration: 0,
                            displayName: "EMPTY"
                        )
                    )
                }
            }
            banks.append(cells)
        }

        return banks
    }

    static func emptyBank(slotCount: Int = defaultSlotCount) -> [LongStripCell] {
        let count = max(1, slotCount)
        return (0..<count).map { slot in
            LongStripCell(
                slotIndex: slot,
                displayToken: String(format: "%02X", slot),
                sampleURL: nil,
                duration: 0,
                displayName: "EMPTY"
            )
        }
    }

    static func slotIndex(for point: CGPoint, in size: CGSize, slotCount: Int = defaultSlotCount) -> Int {
        let count = max(1, slotCount)
        guard size.width > 0 else { return 0 }
        let normalized = max(0, min(0.999_999, point.x / size.width))
        return min(count - 1, max(0, Int(normalized * CGFloat(count))))
    }
}

private struct PlayTouchPoint {
    let id: Int
    let location: CGPoint
}

private struct PlayMultiTouchCaptureView: UIViewRepresentable {
    let onTouchesChanged: ([PlayTouchPoint]) -> Void
    let onTouchesEnded: () -> Void

    func makeUIView(context: Context) -> PlayTouchCaptureUIView {
        let view = PlayTouchCaptureUIView()
        view.onTouchesChanged = onTouchesChanged
        view.onTouchesEnded = onTouchesEnded
        return view
    }

    func updateUIView(_ uiView: PlayTouchCaptureUIView, context: Context) {
        uiView.onTouchesChanged = onTouchesChanged
        uiView.onTouchesEnded = onTouchesEnded
    }
}

private final class PlayTouchCaptureUIView: UIView {
    var onTouchesChanged: (([PlayTouchPoint]) -> Void)?
    var onTouchesEnded: (() -> Void)?
    private var activeTouches: [ObjectIdentifier: UITouch] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        updateTouches(touches, remove: false)
        emitTouches()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        updateTouches(touches, remove: false)
        emitTouches()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        updateTouches(touches, remove: true)
        emitTouches()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        updateTouches(touches, remove: true)
        emitTouches()
    }

    private func updateTouches(_ touches: Set<UITouch>, remove: Bool) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if remove {
                activeTouches.removeValue(forKey: key)
            } else {
                activeTouches[key] = touch
            }
        }
    }

    private func emitTouches() {
        guard !activeTouches.isEmpty else {
            onTouchesEnded?()
            return
        }

        let points = activeTouches.map { key, touch in
            PlayTouchPoint(id: key.hashValue, location: touch.location(in: self))
        }
        onTouchesChanged?(points)
    }
}

private struct PlayGridCell: Identifiable {
    let row: Int
    let column: Int
    let displayToken: String

    var id: String { Self.makeID(row: row, column: column) }

    static func makeID(row: Int, column: Int) -> String {
        "\(row)-\(column)"
    }
}

private enum PlayChipTone {
    case good
    case warn
    case neutral

    var color: Color {
        switch self {
        case .good:
            return BrandingColors.glyphGreen
        case .warn:
            return BrandingColors.warningYellow
        case .neutral:
            return Color.white.opacity(0.75)
        }
    }
}

private struct PlayStatusChip: View {
    let title: String
    let value: String
    let tone: PlayChipTone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .playMono(8, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.56))
            Text(value)
                .playMono(11, weight: .bold)
                .foregroundStyle(tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.black)
        .overlay {
            Rectangle()
                .stroke(tone.color.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }
}

private struct PlayGridScanlines: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            let step: CGFloat = 3.2
            var y: CGFloat = 0
            while y <= size.height {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(lines, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)
        }
    }
}

private extension View {
    func playMono(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced))
            .textCase(.uppercase)
            .tracking(1.1)
    }
}
