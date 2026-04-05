import SwiftUI

struct GridLoopRateModal: View {
    let currentMs: Int
    let onChangeMs: (Int) -> Void
    let onClose: () -> Void

    @State private var localMs: Int = 140

    private let referenceBPM = 120
    private let msRange = 20...500

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 12) {
                header
                rule(0.2)
                intervalSection
                rule(0.16)
                musicalSection
                rule(0.16)
                presetsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: 400)
            .background(Color.black)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("play.grid.looprate.modal")
        }
        .transition(.opacity)
        .onAppear { localMs = currentMs }
    }

    private func rule(_ opacity: Double) -> some View {
        Rectangle()
            .fill(Color.white.opacity(opacity))
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Loop Rate")
                .playSans(14, weight: .bold)
                .foregroundStyle(.white)
                .lineLimit(1)

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
            .accessibilityIdentifier("play.grid.looprate.close")
        }
    }

    // MARK: - Interval

    private var intervalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interval")
                .playSans(11, weight: .bold)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.92))

            HStack(spacing: 6) {
                stepButton(label: "-10", delta: -10)
                stepButton(label: "-1", delta: -1)

                Text("\(localMs) MS")
                    .playMono(18, weight: .bold)
                    .foregroundStyle(BrandingColors.glyphGreen)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(Color.black)
                    .overlay {
                        Rectangle()
                            .stroke(BrandingColors.glyphGreen.opacity(0.5), lineWidth: 1)
                    }

                stepButton(label: "+1", delta: 1)
                stepButton(label: "+10", delta: 10)
            }
        }
    }

    private func stepButton(label: String, delta: Int) -> some View {
        Button {
            applyMs(localMs + delta)
        } label: {
            Text(label)
                .playSans(11, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(minWidth: 40, minHeight: 44)
                .background(Color.black)
                .overlay {
                    Rectangle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Musical Reference

    private var musicalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text("Beat Grid")
                    .playSans(11, weight: .bold)
                    .foregroundStyle(BrandingColors.glyphGreen.opacity(0.92))
                Spacer()
                Text("\(referenceBPM) BPM")
                    .playMono(10, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Text(closestSubdivisionLabel)
                .playMono(12, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.82))

            HStack(spacing: 6) {
                subdivisionChip("1/32", division: 32)
                subdivisionChip("1/16", division: 16)
                subdivisionChip("1/8", division: 8)
                subdivisionChip("1/4", division: 4)
                subdivisionChip("1/2", division: 2)
            }
        }
    }

    private func subdivisionMs(_ division: Int) -> Int {
        let quarterMs = 60000.0 / Double(referenceBPM)
        return Int((quarterMs * 4.0 / Double(division)).rounded())
    }

    private var closestSubdivisionLabel: String {
        let quarterMs = 60000.0 / Double(referenceBPM)
        let ratio = Double(localMs) / quarterMs
        let subdivisions: [(String, Double)] = [
            ("1/32", 0.125), ("1/16", 0.25), ("1/8", 0.5),
            ("1/4", 1.0), ("1/2", 2.0)
        ]
        guard let closest = subdivisions.min(by: { abs($0.1 - ratio) < abs($1.1 - ratio) }) else {
            return "CUSTOM"
        }
        let deviation = abs(ratio - closest.1) / closest.1
        if deviation < 0.06 {
            return "CURRENT: \(closest.0) NOTE"
        }
        return "CURRENT: ~\(closest.0) NOTE"
    }

    private func subdivisionChip(_ label: String, division: Int) -> some View {
        let ms = subdivisionMs(division)
        let isActive = localMs == ms
        return Button {
            applyMs(ms)
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .playSans(10, weight: .bold)
                Text("\(ms)")
                    .playMono(9, weight: .semibold)
            }
            .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.72))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(isActive ? BrandingColors.glyphGreen.opacity(0.12) : Color.black)
            .overlay {
                Rectangle()
                    .stroke(
                        isActive ? BrandingColors.glyphGreen.opacity(0.6) : Color.white.opacity(0.2),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets")
                .playSans(11, weight: .bold)
                .foregroundStyle(BrandingColors.glyphGreen.opacity(0.92))

            HStack(spacing: 6) {
                presetButton(ms: 50)
                presetButton(ms: 100)
                presetButton(ms: 140)
                presetButton(ms: 200)
                presetButton(ms: 300)
            }
        }
    }

    private func presetButton(ms: Int) -> some View {
        let isActive = localMs == ms
        return Button {
            applyMs(ms)
        } label: {
            Text("\(ms)ms")
                .playMono(10, weight: .bold)
                .foregroundStyle(isActive ? BrandingColors.glyphGreen : Color.white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(isActive ? BrandingColors.glyphGreen.opacity(0.12) : Color.black)
                .overlay {
                    Rectangle()
                        .stroke(
                            isActive ? BrandingColors.glyphGreen.opacity(0.6) : Color.white.opacity(0.2),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func applyMs(_ ms: Int) {
        let clamped = max(msRange.lowerBound, min(msRange.upperBound, ms))
        localMs = clamped
        onChangeMs(clamped)
    }
}
