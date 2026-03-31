import SwiftUI

// MARK: - Voxel Grid Rendering Engine
// Ported from meodai/heerich: oblique-projected voxel landscape.
// The grid is a height-mapped field viewed from above at an angle.
// Audio input makes columns rise TOWARD the viewer (up on screen).
// Each DSP mode has its own scene structure, density, and color treatment.

// MARK: - Projection

/// Diamond isometric projection viewed from directly above.
/// Both ground axes are diagonal: col goes upper-right, row goes lower-right.
/// Height goes straight UP on screen (toward the viewer).
/// This creates the classic top-down diamond grid (SimCity / tactics style).
struct VoxelProjection {
    let colDX: CGFloat      // col axis: screen-X per column (positive = right)
    let colDY: CGFloat      // col axis: screen-Y per column (negative = up-right)
    let rowDX: CGFloat      // row axis: screen-X per row (positive = right)
    let rowDY: CGFloat      // row axis: screen-Y per row (positive = down-right)
    let heightScale: CGFloat // height: screen-Y per unit (subtracted → up)
    let origin: CGPoint

    func project(col: Double, row: Double, h: Double) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(col) * colDX + CGFloat(row) * rowDX,
            y: origin.y + CGFloat(col) * colDY + CGFloat(row) * rowDY - CGFloat(h) * heightScale
        )
    }
}

// MARK: - Height-Mapped Grid

struct VoxelGrid {
    let cols: Int
    let rows: Int
    var heights: [Int] // row-major: heights[row * cols + col]

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.heights = Array(repeating: 0, count: cols * rows)
    }

    func height(col: Int, row: Int) -> Int {
        guard col >= 0, col < cols, row >= 0, row < rows else { return 0 }
        return heights[row * cols + col]
    }

    mutating func setHeight(col: Int, row: Int, _ h: Int) {
        guard col >= 0, col < cols, row >= 0, row < rows else { return }
        heights[row * cols + col] = max(0, h)
    }

    /// Generate three batched Paths for the diamond isometric view:
    ///   top  — diamond-shaped face on top of each column (always visible from above)
    ///   south — right-side face (row+1 edge, facing lower-right)
    ///   west  — left-side face (col edge, facing lower-left)
    /// Faces only render exposed portions above shorter neighbors.
    func buildFaces(projection: VoxelProjection) -> (top: Path, south: Path, west: Path) {
        var top = Path()
        var south = Path()
        var west = Path()

        for row in 0..<rows {
            for col in 0..<cols {
                let h = height(col: col, row: row)
                guard h > 0 else { continue }

                let hd = Double(h)
                let c = Double(col), r = Double(row)

                // -- Top face: diamond rhombus at column height --
                let t0 = projection.project(col: c,     row: r,     h: hd)
                let t1 = projection.project(col: c + 1, row: r,     h: hd)
                let t2 = projection.project(col: c + 1, row: r + 1, h: hd)
                let t3 = projection.project(col: c,     row: r + 1, h: hd)
                top.move(to: t0); top.addLine(to: t1); top.addLine(to: t2); top.addLine(to: t3)
                top.closeSubpath()

                // -- South face (row+1 edge, right side, facing lower-right) --
                let southNH = height(col: col, row: row + 1)
                if h > southNH {
                    let bH = Double(southNH)
                    let s0 = projection.project(col: c,     row: r + 1, h: hd)
                    let s1 = projection.project(col: c + 1, row: r + 1, h: hd)
                    let s2 = projection.project(col: c + 1, row: r + 1, h: bH)
                    let s3 = projection.project(col: c,     row: r + 1, h: bH)
                    south.move(to: s0); south.addLine(to: s1); south.addLine(to: s2); south.addLine(to: s3)
                    south.closeSubpath()
                }

                // -- West face (col edge, left side, facing lower-left) --
                let westNH = height(col: col - 1, row: row)
                if h > westNH {
                    let bH = Double(westNH)
                    let w0 = projection.project(col: c, row: r,     h: hd)
                    let w1 = projection.project(col: c, row: r + 1, h: hd)
                    let w2 = projection.project(col: c, row: r + 1, h: bH)
                    let w3 = projection.project(col: c, row: r,     h: bH)
                    west.move(to: w0); west.addLine(to: w1); west.addLine(to: w2); west.addLine(to: w3)
                    west.closeSubpath()
                }
            }
        }

        return (top, south, west)
    }
}

// MARK: - Per-Mode Scene Configuration

struct VoxelModeScene {
    let cols: Int
    let rows: Int
    let maxHeight: Int
    let topColor: (r: Double, g: Double, b: Double)
    let southColor: (r: Double, g: Double, b: Double)
    let eastColor: (r: Double, g: Double, b: Double)
    let strokeColor: (r: Double, g: Double, b: Double)
    let baseOpacityRange: (min: Double, max: Double)

    static func forMode(_ mode: Int) -> VoxelModeScene {
        let slate = StageIndustrialPalette.slate
        let signal = StageIndustrialPalette.signal
        let active = StageIndustrialPalette.active
        let amber = StageIndustrialPalette.amber
        let alert = StageIndustrialPalette.alert
        let dimSig = StageIndustrialPalette.dimSignal

        switch mode {
        case 0: // REVERB — warm, deep, rolling mounds
            return VoxelModeScene(
                cols: 18, rows: 14, maxHeight: 8,
                topColor: (slate.red * 1.8, slate.green * 1.8, slate.blue * 2.2),
                southColor: (slate.red * 1.2, slate.green * 1.2, slate.blue * 1.5),
                eastColor: (slate.red * 0.85, slate.green * 0.85, slate.blue * 1.1),
                strokeColor: (dimSig.red, dimSig.green, dimSig.blue),
                baseOpacityRange: (0.45, 0.88)
            )
        case 1: // STUTTER — sharp gated columns
            return VoxelModeScene(
                cols: 22, rows: 10, maxHeight: 10,
                topColor: (signal.red * 0.55, signal.green * 0.6, signal.blue * 0.55),
                southColor: (slate.red * 1.5, slate.green * 1.6, slate.blue * 1.5),
                eastColor: (slate.red * 1.0, slate.green * 1.1, slate.blue * 1.0),
                strokeColor: (dimSig.red, dimSig.green, dimSig.blue),
                baseOpacityRange: (0.40, 0.92)
            )
        case 2: // GRAIN — sparse scatter, amber dust
            return VoxelModeScene(
                cols: 16, rows: 12, maxHeight: 5,
                topColor: (amber.red * 0.45, amber.green * 0.42, amber.blue * 0.3),
                southColor: (slate.red * 1.4, slate.green * 1.3, slate.blue * 1.0),
                eastColor: (slate.red * 1.0, slate.green * 0.9, slate.blue * 0.7),
                strokeColor: (dimSig.red, dimSig.green, dimSig.blue),
                baseOpacityRange: (0.35, 0.80)
            )
        case 3: // CRUSH — heavy, dense, compressed center mass
            return VoxelModeScene(
                cols: 14, rows: 12, maxHeight: 7,
                topColor: (alert.red * 0.4, alert.green * 0.28, alert.blue * 0.28),
                southColor: (slate.red * 1.6, slate.green * 1.2, slate.blue * 1.2),
                eastColor: (slate.red * 1.2, slate.green * 0.85, slate.blue * 0.85),
                strokeColor: (dimSig.red * 1.2, dimSig.green * 0.8, dimSig.blue * 0.8),
                baseOpacityRange: (0.50, 0.92)
            )
        case 4: // SAMPLER — terraced layers, stacked
            return VoxelModeScene(
                cols: 16, rows: 14, maxHeight: 9,
                topColor: (active.red * 0.35, active.green * 0.40, active.blue * 0.28),
                southColor: (slate.red * 1.4, slate.green * 1.6, slate.blue * 1.3),
                eastColor: (slate.red * 1.0, slate.green * 1.3, slate.blue * 0.95),
                strokeColor: (dimSig.red, dimSig.green, dimSig.blue),
                baseOpacityRange: (0.45, 0.88)
            )
        case 5: // MIDI/WET — tall corridors, signal routing
            return VoxelModeScene(
                cols: 20, rows: 10, maxHeight: 10,
                topColor: (active.red * 0.32, active.green * 0.38, active.blue * 0.25),
                southColor: (slate.red * 1.3, slate.green * 1.7, slate.blue * 1.3),
                eastColor: (slate.red * 0.95, slate.green * 1.35, slate.blue * 0.95),
                strokeColor: (dimSig.red * 0.9, dimSig.green * 1.1, dimSig.blue * 0.9),
                baseOpacityRange: (0.42, 0.85)
            )
        case 6: // MIDI/DRY — minimal, quiet, subtle ridges
            return VoxelModeScene(
                cols: 14, rows: 10, maxHeight: 3,
                topColor: (slate.red * 1.7, slate.green * 1.7, slate.blue * 1.8),
                southColor: (slate.red * 1.2, slate.green * 1.2, slate.blue * 1.3),
                eastColor: (slate.red * 0.85, slate.green * 0.85, slate.blue * 0.95),
                strokeColor: (dimSig.red, dimSig.green, dimSig.blue),
                baseOpacityRange: (0.30, 0.60)
            )
        case 7: // BUCKETS — three fill zones
            return VoxelModeScene(
                cols: 18, rows: 12, maxHeight: 8,
                topColor: (amber.red * 0.40, amber.green * 0.38, amber.blue * 0.22),
                southColor: (slate.red * 1.5, slate.green * 1.4, slate.blue * 1.05),
                eastColor: (slate.red * 1.1, slate.green * 1.0, slate.blue * 0.75),
                strokeColor: (dimSig.red, dimSig.green, dimSig.blue),
                baseOpacityRange: (0.45, 0.88)
            )
        case 8: // SPACE — ring/donut, orbital
            return VoxelModeScene(
                cols: 16, rows: 16, maxHeight: 6,
                topColor: (signal.red * 0.40, signal.green * 0.42, signal.blue * 0.45),
                southColor: (slate.red * 1.3, slate.green * 1.4, slate.blue * 1.6),
                eastColor: (slate.red * 0.95, slate.green * 1.05, slate.blue * 1.25),
                strokeColor: (dimSig.red * 0.9, dimSig.green * 0.95, dimSig.blue * 1.1),
                baseOpacityRange: (0.40, 0.85)
            )
        case 9: // PARTICLE — explosive radial scatter
            return VoxelModeScene(
                cols: 18, rows: 14, maxHeight: 10,
                topColor: (alert.red * 0.35, alert.green * 0.32, alert.blue * 0.22),
                southColor: (slate.red * 1.7, slate.green * 1.3, slate.blue * 1.05),
                eastColor: (slate.red * 1.3, slate.green * 0.95, slate.blue * 0.75),
                strokeColor: (dimSig.red * 1.1, dimSig.green * 0.9, dimSig.blue * 0.8),
                baseOpacityRange: (0.48, 0.92)
            )
        case 10: // SCENES — shifting checker blocks
            return VoxelModeScene(
                cols: 16, rows: 12, maxHeight: 7,
                topColor: (amber.red * 0.36, amber.green * 0.32, amber.blue * 0.20),
                southColor: (slate.red * 1.5, slate.green * 1.3, slate.blue * 1.05),
                eastColor: (slate.red * 1.15, slate.green * 0.95, slate.blue * 0.75),
                strokeColor: (dimSig.red, dimSig.green, dimSig.blue),
                baseOpacityRange: (0.45, 0.88)
            )
        default:
            return Self.forMode(0)
        }
    }
}

// MARK: - Height Map Builder

enum VoxelHeightMap {
    static func build(
        scene: VoxelModeScene,
        mode: Int,
        audio: StageAudioSnapshot,
        field: StageRenderField,
        prng: StagePRNG,
        t: Double
    ) -> VoxelGrid {
        var grid = VoxelGrid(cols: scene.cols, rows: scene.rows)

        for row in 0..<scene.rows {
            let rowN = Double(row) / Double(max(1, scene.rows - 1))
            for col in 0..<scene.cols {
                let colN = Double(col) / Double(max(1, scene.cols - 1))

                let cellSeed = abs(col &* 31 &+ row &* 17 &+ mode &* 7)
                let cellRand = prng.value(at: cellSeed)

                let raw = cellHeight(
                    mode: mode, colN: colN, rowN: rowN,
                    cellRand: cellRand, cellSeed: cellSeed,
                    audio: audio, field: field, prng: prng, t: t
                )

                // Threshold: cells need enough energy to appear (voxels come in/out)
                let threshold = 0.15 + cellRand * 0.25
                let h: Int
                if raw < threshold {
                    h = 0
                } else {
                    h = max(1, min(scene.maxHeight, Int(raw * Double(scene.maxHeight))))
                }
                grid.setHeight(col: col, row: row, h)
            }
        }

        return grid
    }

    private static func cellHeight(
        mode: Int, colN: Double, rowN: Double,
        cellRand: Double, cellSeed: Int,
        audio: StageAudioSnapshot, field: StageRenderField,
        prng: StagePRNG, t: Double
    ) -> Double {
        // Band blend: left=low, center=mid, right=high
        let band = bandBlend(colN: colN, low: audio.lowBand, mid: audio.midBand, high: audio.highBand)

        // Transient spikes: random cells surge
        let spike: Double
        if audio.transientFlux > 0.3 && prng.value(at: cellSeed + 200) < 0.3 {
            spike = audio.transientFlux * 1.2
        } else {
            spike = 0
        }

        // RMS baseline
        let rms = audio.rms * 0.4

        // Mode-specific shaping
        let shape = modeShape(mode: mode, colN: colN, rowN: rowN, cellRand: cellRand, t: t, audio: audio, field: field, prng: prng, cellSeed: cellSeed)

        return (band * 0.35 + spike + rms + shape)
    }

    private static func bandBlend(colN: Double, low: Double, mid: Double, high: Double) -> Double {
        if colN < 0.35 {
            let t = colN / 0.35
            return low * (1 - t * 0.4) + mid * (t * 0.4)
        } else if colN < 0.65 {
            return mid
        } else {
            let t = (colN - 0.65) / 0.35
            return mid * (1 - t * 0.4) + high * (t * 0.4)
        }
    }

    private static func modeShape(
        mode: Int, colN: Double, rowN: Double, cellRand: Double,
        t: Double, audio: StageAudioSnapshot, field: StageRenderField,
        prng: StagePRNG, cellSeed: Int
    ) -> Double {
        switch mode {
        case 0: // REVERB — smooth concentric mounds from center, low-end driven
            let cx = colN - 0.5, rz = rowN - 0.5
            let dist = sqrt(cx * cx + rz * rz)
            let mound = max(0, 0.8 - dist * 2.0)
            return mound * audio.lowBand * 0.9

        case 1: // STUTTER — gated columns, rows activate/deactivate in steps
            let rowStep = floor(rowN * 5) / 5
            let gate = sin(t * 3.0 + rowStep * .pi * 2) > -0.1 ? 1.0 : 0.0
            let colGate = (Int(floor(colN * Double(22))) % 3 == 0) ? 1.0 : 0.4
            return gate * colGate * audio.transientFlux * 0.8

        case 2: // GRAIN — sparse scattered cells, only some activate
            let eligible = cellRand > 0.60
            return eligible ? audio.rms * 0.65 : 0

        case 3: // CRUSH — dense center mass, compresses outward
            let cx = abs(colN - 0.5), rz = abs(rowN - 0.5)
            let inBlock = (cx < 0.32 && rz < 0.38) ? 1.0 : 0.0
            let fringe = (cx < 0.42 && rz < 0.48) ? 0.35 : 0.0
            let energy = audio.midBand + audio.zeroCrossDensity * 0.15
            return (inBlock + fringe) * energy * 0.85

        case 4: // SAMPLER — stepped terraces, quantized height bands
            let terrace = floor(rowN * 4) / 4
            let step = floor(colN * 3) / 3
            let layered = (terrace + step) * 0.35
            return layered * audio.peak * 0.7

        case 5: // MIDI/WET — vertical corridors, alternating columns active
            let corridor = sin(colN * .pi * 5) > 0.2 ? 1.0 : 0.0
            let depth = (1.0 - rowN) * 0.3 // Taller in front rows
            return corridor * (audio.lowBand * 0.7 + depth)

        case 6: // MIDI/DRY — barely there, subtle undulation
            let wave = sin(colN * .pi * 2 + t * 0.3) * 0.5 + 0.5
            return wave * audio.rms * 0.22

        case 7: // BUCKETS — three distinct fill zones
            let zone: Double
            if colN < 0.30 { zone = audio.lowBand }
            else if colN < 0.70 { zone = audio.midBand }
            else { zone = audio.highBand }
            let inBucket = (abs(rowN - 0.5) < 0.38) ? 1.0 : 0.0
            // Gaps between zones
            let gapCol = (colN > 0.28 && colN < 0.32) || (colN > 0.68 && colN < 0.72)
            return gapCol ? 0 : inBucket * zone * 0.85

        case 8: // SPACE — ring/donut, radial pattern
            let cx = colN - 0.5, rz = rowN - 0.5
            let dist = sqrt(cx * cx + rz * rz)
            let ring = (dist > 0.18 && dist < 0.40) ? 1.0 : 0.0
            let ringHeight = max(0, 1.0 - abs(dist - 0.29) * 8)
            return ring * ringHeight * audio.brightness * 0.8

        case 9: // PARTICLE — radial blast outward on transients
            let cx = colN - 0.5, rz = rowN - 0.5
            let dist = sqrt(cx * cx + rz * rz)
            let waveFront = fmod(t * 0.25, 0.55)
            let wave = max(0, 1.0 - abs(dist - waveFront) * 6)
            let scatter = cellRand > 0.55 ? 1.2 : 0.5
            return wave * scatter * field.splat * 0.9

        case 10: // SCENES — checker/block pattern that shifts with disruption
            let shiftedCol = fmod(colN + field.disruption * 0.25, 1.0)
            let blockX = Int(floor(shiftedCol * 5))
            let blockZ = Int(floor(rowN * 4))
            let checker = (blockX + blockZ) % 2 == 0 ? 1.0 : 0.15
            return checker * audio.rms * 0.65

        default:
            return audio.rms * 0.3
        }
    }
}

// MARK: - Draw Function

func drawVoxelStructures(
    context: inout GraphicsContext,
    size: CGSize,
    field: StageRenderField,
    snapshot: VideoStageSnapshot,
    now: Date
) {
    guard snapshot.isRunning else { return }

    let mode = snapshot.mode
    let audio = snapshot.stageAudio
    let prng = StagePRNG(seed: snapshot.joltSeed ^ 0xAABB)
    let t = now.timeIntervalSinceReferenceDate
    let scene = VoxelModeScene.forMode(mode)

    // Build height map
    let grid = VoxelHeightMap.build(
        scene: scene, mode: mode, audio: audio, field: field, prng: prng, t: t
    )

    // Diamond isometric projection — TRUE top-down view.
    // Col axis → upper-right on screen, row axis → lower-right on screen.
    // This creates the classic diamond tile grid seen from directly above.
    // Height pops blocks straight UP toward the viewer.
    // Grid overflows the canvas on all sides for an immersive close-up feel.

    let totalAxes = CGFloat(scene.cols + scene.rows)
    let tileW = max(size.width, size.height) * 2.5 / totalAxes
    let halfW = tileW * 0.5
    let halfH = tileW * 0.25   // 2:1 diamond ratio → top-down

    let colDX = halfW            // col: right
    let colDY = -halfH           // col: UP (upper-right diagonal)
    let rowDX = halfW            // row: right
    let rowDY = halfH            // row: DOWN (lower-right diagonal)
    let heightScale = tileW * 0.38  // height: straight UP

    // Center grid on canvas — overflow is intentional
    let midC = CGFloat(scene.cols) * 0.5
    let midR = CGFloat(scene.rows) * 0.5
    let originX = size.width * 0.5 - (midC + midR) * halfW
    let originY = size.height * 0.5 - (midR - midC) * halfH + CGFloat(scene.maxHeight) * heightScale * 0.2

    let projection = VoxelProjection(
        colDX: colDX, colDY: colDY,
        rowDX: rowDX, rowDY: rowDY,
        heightScale: heightScale,
        origin: CGPoint(x: originX, y: originY)
    )

    // Generate face paths
    let (topPath, southPath, westPath) = grid.buildFaces(projection: projection)

    // Opacity driven by audio energy
    let opMin = scene.baseOpacityRange.min
    let opMax = scene.baseOpacityRange.max
    let energyOp = opMin + (opMax - opMin) * min(1.0, audio.rms * 1.5 + audio.peak * 0.3)

    // Overload tint
    let olBlend = audio.overloadPulse > 0.3 ? audio.overloadPulse * 0.4 : 0.0
    let transBoost = audio.transientFlux > 0.5 ? 0.12 : 0.0

    // Draw order: sides FIRST, then top LAST (top-down: tops always closest to viewer)

    // South faces (right side, facing lower-right) — medium shade
    let sc = scene.southColor
    let sR = min(1.0, sc.r + olBlend * 0.2)
    let sG = min(1.0, sc.g * (1.0 - olBlend * 0.3))
    let sB = min(1.0, sc.b * (1.0 - olBlend * 0.3))
    context.fill(southPath, with: .color(Color(red: sR, green: sG, blue: sB, opacity: energyOp * 0.82)))

    // West faces (left side, facing lower-left) — darkest shade
    let ec = scene.eastColor
    let wR = min(1.0, ec.r + olBlend * 0.15)
    let wG = min(1.0, ec.g * (1.0 - olBlend * 0.2))
    let wB = min(1.0, ec.b * (1.0 - olBlend * 0.2))
    context.fill(westPath, with: .color(Color(red: wR, green: wG, blue: wB, opacity: energyOp * 0.68)))

    // Top faces (brightest — direct overhead light, always on top)
    let tc = scene.topColor
    let tR = min(1.0, tc.r + olBlend * 0.3)
    let tG = min(1.0, tc.g * (1.0 - olBlend * 0.5))
    let tB = min(1.0, tc.b * (1.0 - olBlend * 0.5))
    context.fill(topPath, with: .color(Color(red: tR, green: tG, blue: tB, opacity: energyOp + transBoost)))

    // Edge strokes
    let stk = scene.strokeColor
    let strokeOp = 0.12 + field.activity * 0.18
    let strokeCol = Color(red: stk.r, green: stk.g, blue: stk.b, opacity: strokeOp)
    context.stroke(southPath, with: .color(strokeCol), lineWidth: 0.6)
    context.stroke(westPath, with: .color(strokeCol), lineWidth: 0.5)
    context.stroke(topPath, with: .color(strokeCol), lineWidth: 0.8)
}
