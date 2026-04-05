import SwiftUI

struct OperatorActivityLogSectionModel: Equatable {
    let operatorName: String
    let latestEvent: OperatorActivityEvent
    let eventCount: Int
}

enum OperatorActivityLogFeed {
    static func recentEvents(
        timeline: [OperatorActivityEvent],
        sessionId: String?,
        includeSelf: Bool,
        surface: OperatorActivitySurface,
        limit: Int
    ) -> [OperatorActivityEvent] {
        let resolvedLimit = max(0, limit)
        let filtered = timeline.filter { event in
            guard event.surface == surface else { return false }
            if includeSelf { return true }
            guard let sessionId else { return true }
            return event.sessionId != sessionId
        }
        return Array(filtered.prefix(resolvedLimit))
    }

    static func activeSections(
        timeline: [OperatorActivityEvent],
        sessionId: String?,
        includeSelf: Bool,
        surface: OperatorActivitySurface,
        window: TimeInterval,
        now: Date,
        displayName: (String) -> String
    ) -> [OperatorActivityLogSectionModel] {
        let threshold = now.addingTimeInterval(-max(0, window))
        let recent = recentEvents(
            timeline: timeline,
            sessionId: sessionId,
            includeSelf: includeSelf,
            surface: surface,
            limit: 300
        )
            .filter { $0.timestamp >= threshold }

        let grouped = Dictionary(grouping: recent) { displayName($0.sessionId) }
        let sections = grouped.compactMap { key, events -> OperatorActivityLogSectionModel? in
            guard let latest = events.max(by: { $0.timestamp < $1.timestamp }) else {
                return nil
            }
            return OperatorActivityLogSectionModel(
                operatorName: key,
                latestEvent: latest,
                eventCount: events.count
            )
        }

        return sections.sorted { lhs, rhs in
            lhs.latestEvent.timestamp > rhs.latestEvent.timestamp
        }
    }
}

struct OperatorActivityLogModal: View {
    let idPrefix: String
    let title: String
    let appState: TubCompanionAppState
    let connectionState: HarnessConnectionState
    let surface: OperatorActivitySurface
    let onClose: () -> Void

    @State private var includeSelf = false

    private var isRelayConnected: Bool {
        if case .connected = connectionState {
            return true
        }
        return false
    }

    private var effectiveIncludeSelf: Bool {
        includeSelf || !isRelayConnected
    }

    private var recentEvents: [OperatorActivityEvent] {
        OperatorActivityLogFeed.recentEvents(
            timeline: appState.operatorActivityRecent(includeSelf: true, limit: 300),
            sessionId: appState.sessionId,
            includeSelf: effectiveIncludeSelf,
            surface: surface,
            limit: 60
        )
    }

    private var activeSections: [OperatorActivityLogSectionModel] {
        OperatorActivityLogFeed.activeSections(
            timeline: appState.operatorActivityRecent(includeSelf: true, limit: 300),
            sessionId: appState.sessionId,
            includeSelf: effectiveIncludeSelf,
            surface: surface,
            window: 2.5,
            now: Date(),
            displayName: { appState.operatorDisplayName(for: $0) }
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            VStack(alignment: .leading, spacing: 12) {
                header
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 1)
                activeNowSection
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 1)
                recentEventsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: 560)
            .background(Color.black)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("\(idPrefix).modal")
        }
        .transition(.opacity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .playSans(14, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 4)

                Button {
                    onClose()
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
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("\(idPrefix).close")
            }

            HStack(spacing: 6) {
                OperatorActivityStatusChip(
                    title: "SURFACE",
                    value: surface.rawValue.uppercased(),
                    isActive: true
                )

                OperatorActivityStatusChip(
                    title: "RELAY",
                    value: isRelayConnected ? "LIVE" : "OFF",
                    isActive: isRelayConnected
                )

                Button {
                    includeSelf.toggle()
                } label: {
                    Text(effectiveIncludeSelf ? "All" : "Others")
                        .playSans(10, weight: .semibold)
                        .foregroundStyle(
                            effectiveIncludeSelf
                            ? BrandingColors.glyphGreen
                            : Color.white.opacity(0.82)
                        )
                        .frame(minWidth: 52, minHeight: 26)
                        .overlay {
                            Rectangle()
                                .stroke(
                                    effectiveIncludeSelf
                                    ? BrandingColors.glyphGreen.opacity(0.7)
                                    : Color.white.opacity(0.25),
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .disabled(!isRelayConnected)
                .opacity(isRelayConnected ? 1 : 0.55)
                .accessibilityIdentifier("\(idPrefix).toggle.scope")
            }

            if !isRelayConnected {
                Text("RELAY OFFLINE. LOCAL-ONLY ACTIVITY.")
                    .playMono(10, weight: .semibold)
                    .foregroundStyle(BrandingColors.warningYellow.opacity(0.94))
            }
        }
    }

    private var activeNowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Now")
                .playSans(11, weight: .bold)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.92))

            if activeSections.isEmpty {
                Text("NO ACTIVE OPERATORS IN WINDOW.")
                    .playMono(10, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.58))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(activeSections.enumerated()), id: \.offset) { _, section in
                        HStack(spacing: 8) {
                            Text(section.operatorName)
                                .playMono(10, weight: .bold)
                                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.96))
                            Text(actionLine(for: section.latestEvent))
                                .playMono(10, weight: .semibold)
                                .foregroundStyle(Color.white.opacity(0.8))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(section.eventCount)x")
                                .playMono(10, weight: .bold)
                                .foregroundStyle(Color.white.opacity(0.56))
                        }
                    }
                }
            }
        }
    }

    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Events")
                .playSans(11, weight: .bold)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.92))

            if recentEvents.isEmpty {
                Text("NO EVENTS YET.")
                    .playMono(10, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.58))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(recentEvents.enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(relativeTimeLabel(for: event.timestamp))
                                    .playMono(10, weight: .bold)
                                    .foregroundStyle(Color.white.opacity(0.54))
                                    .frame(width: 36, alignment: .leading)
                                Text(appState.operatorDisplayName(for: event.sessionId))
                                    .playMono(10, weight: .bold)
                                    .foregroundStyle(BrandingColors.glyphGreen.opacity(0.95))
                                Text(actionLine(for: event))
                                    .playMono(10, weight: .semibold)
                                    .foregroundStyle(Color.white.opacity(0.8))
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private func relativeTimeLabel(for timestamp: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(timestamp))
        if delta < 1 {
            return "NOW"
        }
        if delta < 10 {
            return String(format: "%.1fs", delta)
        }
        return "\(Int(delta.rounded(.down)))s"
    }

    private func actionLine(for event: OperatorActivityEvent) -> String {
        let base: String
        switch event.action {
        case .playGridTrigger:
            base = "GRID TRIGGER"
        case .playBankPrevious:
            base = "BANK -"
        case .playBankNext:
            base = "BANK +"
        case .playLongBankPrevious:
            base = "LONG BANK -"
        case .playLongBankNext:
            base = "LONG BANK +"
        case .playLongTransportPause:
            base = "LONG PAUSE"
        case .playLongTransportResume:
            base = "LONG RESUME"
        case .playLongFadeStart:
            base = "LONG FADE START"
        case .playLongFadeComplete:
            base = "LONG FADE COMPLETE"
        case .playLongSweep:
            base = "LONG SWEEP"
        case .steerVector:
            base = "VECTOR DRAG"
        case .steerHoldStart:
            base = "HOLD START"
        case .steerHoldEnd:
            base = "HOLD END"
        case .steerNudgeMore:
            base = "NUDGE MORE"
        case .steerNudgeLess:
            base = "NUDGE LESS"
        case .steerCompareChoice:
            base = "COMPARE CHOICE"
        }

        let label = event.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if label.isEmpty {
            return base
        }
        return "\(base) \(label.uppercased())"
    }
}

private struct OperatorActivityStatusChip: View {
    let title: String
    let value: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .playSans(9, weight: .semibold)
            Text(value)
                .playMono(9, weight: .semibold)
                .foregroundStyle(
                    isActive
                    ? BrandingColors.glyphGreen.opacity(0.96)
                    : BrandingColors.warningYellow.opacity(0.92)
                )
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 26)
        .overlay {
            Rectangle()
                .stroke(
                    isActive
                    ? BrandingColors.glyphGreen.opacity(0.7)
                    : BrandingColors.warningYellow.opacity(0.62),
                    lineWidth: 1
                )
        }
    }
}
