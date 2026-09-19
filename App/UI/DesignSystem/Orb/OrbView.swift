import SwiftUI

/// What the orb expresses. The assistant layer maps `AgentState` onto these modes
/// (see `AgentState.orbMode`).
enum OrbMode: String, CaseIterable, Sendable, Identifiable {
    /// Starting, downloading or warming the models.
    case preparing
    /// Ready: gentle breathing.
    case idle
    /// Hearing the person: contours ripple with the microphone level.
    case listening
    /// Endpointing, transcribing, thinking: a calm rotating shimmer.
    case understanding
    /// Speaking or reporting a result: contours pulse outward with the voice.
    case speaking
    /// Waiting for confirmation of a consequential action: warm amber ring.
    case confirming
    /// Waiting for an answer to a question: soft blue ring.
    case clarifying
    /// Running a confirmed action: a progress sweep.
    case executing
    /// A permission is missing: muted and still.
    case blocked
    /// Something went wrong: red.
    case failed

    var id: String { rawValue }

    var tone: Tone {
        switch self {
        case .confirming: .amber
        case .clarifying: .sky
        case .failed: .danger
        case .blocked, .preparing: .neutral
        default: .jade
        }
    }

    /// The glyph drawn in the core. With motion, only the still states carry one; under
    /// Reduce Motion every active state does, so the orb reads without animation.
    func glyph(reduceMotion: Bool) -> String? {
        switch self {
        case .blocked: return "lock.fill"
        case .failed: return "exclamationmark"
        default: break
        }
        guard reduceMotion else { return nil }
        switch self {
        case .preparing: return "hourglass"
        case .idle: return nil
        case .listening: return "waveform"
        case .understanding: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .confirming: return "hand.raised.fill"
        case .clarifying: return "questionmark"
        case .executing: return "gearshape.fill"
        case .blocked, .failed: return nil
        }
    }

    /// Motion parameters the orb eases toward in this mode.
    var style: OrbStyle {
        switch self {
        case .preparing:
            OrbStyle(amplitude: 0.012, levelGain: 0, speed: 0.25, breath: 0.4, pulse: 0, shimmer: 0.7, sweep: 0, ring: 0, glow: 0.25, spread: 0)
        case .idle:
            OrbStyle(amplitude: 0.018, levelGain: 0, speed: 0.35, breath: 1, pulse: 0, shimmer: 0, sweep: 0, ring: 0, glow: 0.45, spread: 0)
        case .listening:
            OrbStyle(amplitude: 0.022, levelGain: 0.17, speed: 0.85, breath: 0.25, pulse: 0, shimmer: 0, sweep: 0, ring: 0, glow: 0.75, spread: 1)
        case .understanding:
            OrbStyle(amplitude: 0.014, levelGain: 0, speed: 0.45, breath: 0.2, pulse: 0, shimmer: 1, sweep: 0, ring: 0, glow: 0.6, spread: 0)
        case .speaking:
            OrbStyle(amplitude: 0.016, levelGain: 0.06, speed: 0.7, breath: 0.2, pulse: 1, shimmer: 0, sweep: 0, ring: 0, glow: 0.8, spread: 0.6)
        case .confirming:
            OrbStyle(amplitude: 0.012, levelGain: 0, speed: 0.3, breath: 0.6, pulse: 0, shimmer: 0, sweep: 0, ring: 1, glow: 0.55, spread: 0)
        case .clarifying:
            OrbStyle(amplitude: 0.014, levelGain: 0, speed: 0.35, breath: 0.6, pulse: 0, shimmer: 0, sweep: 0, ring: 1, glow: 0.5, spread: 0)
        case .executing:
            OrbStyle(amplitude: 0.01, levelGain: 0, speed: 0.4, breath: 0.1, pulse: 0, shimmer: 0.3, sweep: 1, ring: 0, glow: 0.6, spread: 0)
        case .blocked:
            OrbStyle(amplitude: 0.006, levelGain: 0, speed: 0.12, breath: 0.3, pulse: 0, shimmer: 0, sweep: 0, ring: 0, glow: 0.15, spread: 0)
        case .failed:
            OrbStyle(amplitude: 0.03, levelGain: 0, speed: 0.15, breath: 0.2, pulse: 0, shimmer: 0, sweep: 0, ring: 0, glow: 0.35, spread: 0)
        }
    }

    /// Which audio level drives the orb in this mode.
    func level(input: Float, output: Float) -> Double {
        switch self {
        case .listening: Double(input)
        case .speaking: Double(output)
        default: 0
        }
    }
}

/// Numeric motion parameters (all 0...1 unless noted).
struct OrbStyle: Sendable, Equatable {
    /// Base contour deformation, as a fraction of the radius.
    var amplitude: Double
    /// Extra deformation per unit of audio level.
    var levelGain: Double
    /// Contour drift speed (radians per second).
    var speed: Double
    var breath: Double
    /// Outward travelling wave while speaking (scaled by level).
    var pulse: Double
    /// Rotating highlight while understanding.
    var shimmer: Double
    /// Progress sweep while executing.
    var sweep: Double
    /// Accent ring while waiting for the person.
    var ring: Double
    var glow: Double
    /// Contours spread apart with the audio level.
    var spread: Double
}

/// The central state indicator: fine concentric contours that behave like ripples of sound.
///
/// Drawn with `Canvas` inside a `TimelineView`; all parameters ease between modes, so state
/// changes read as one continuous gesture. Under Reduce Motion it is a still drawing with a
/// glyph in its core. The orb is decorative for VoiceOver — the state label beneath it
/// carries the meaning.
struct OrbView: View {
    var mode: OrbMode
    var inputLevel: Float = 0
    var outputLevel: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var dynamics = OrbDynamics()

    var body: some View {
        let tint = mode.tone.color.resolve(in: environment)
        let isDark = colorScheme == .dark
        let target = OrbTarget(
            style: mode.style,
            level: OrbDynamics.shape(mode.level(input: inputLevel, output: outputLevel)),
            color: tint
        )

        ZStack {
            if reduceMotion {
                let frame = OrbFrame.still(target: target)
                Canvas { context, size in
                    OrbRenderer.draw(frame, in: &context, size: size, isDark: isDark)
                }
            } else {
                TimelineView(.animation(minimumInterval: mode == .idle || mode == .blocked ? 1.0 / 30 : nil)) { timeline in
                    let frame = dynamics.advance(to: timeline.date.timeIntervalSinceReferenceDate, target: target)
                    Canvas { context, size in
                        OrbRenderer.draw(frame, in: &context, size: size, isDark: isDark)
                    }
                }
            }

            if let glyph = mode.glyph(reduceMotion: reduceMotion) {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    Image(systemName: glyph)
                        .font(.system(size: max(11, side * 0.085), weight: .bold))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: mode)
        .accessibilityHidden(true)
    }
}

// MARK: - Dynamics

struct OrbTarget {
    var style: OrbStyle
    var level: Double
    var color: Color.Resolved
}

/// One rendered frame's worth of parameters (plain values, safe to hand to the renderer).
struct OrbFrame: Sendable {
    var color: Color.Resolved
    var amplitude: Double
    var levelGain: Double
    var level: Double
    var breathScale: Double
    var pulse: Double
    var pulsePhase: Double
    var phase: Double
    var shimmer: Double
    var shimmerAngle: Double
    var sweep: Double
    var sweepAngle: Double
    var ring: Double
    var ringPulse: Double
    var glow: Double
    var spread: Double

    /// A composed still frame for Reduce Motion.
    static func still(target: OrbTarget) -> OrbFrame {
        let style = target.style
        return OrbFrame(
            color: target.color, amplitude: style.amplitude, levelGain: 0, level: 0, breathScale: 1,
            pulse: 0, pulsePhase: 0, phase: 0.8, shimmer: style.shimmer, shimmerAngle: -.pi / 2,
            sweep: style.sweep, sweepAngle: -.pi / 2, ring: style.ring, ringPulse: 0.5,
            glow: style.glow, spread: 0
        )
    }
}

/// Eases the orb's parameters toward the current mode and integrates its phases.
/// Owned by the view as `@State`; mutated only while rendering, never observed.
@MainActor
final class OrbDynamics {
    private var style: OrbStyle?
    private var level: Double = 0
    private var color: SIMD4<Float>?
    private var lastTime: TimeInterval?
    private var phase: Double = 0
    private var pulsePhase: Double = 0
    private var shimmerAngle: Double = -.pi / 2
    private var sweepAngle: Double = -.pi / 2
    private var ringPhase: Double = 0
    private var breathPhase: Double = 0

    /// Perceptual shaping of a 0...1 audio level.
    nonisolated static func shape(_ level: Double) -> Double {
        min(1, pow(max(0, level), 0.65))
    }

    func advance(to time: TimeInterval, target: OrbTarget) -> OrbFrame {
        let dt = lastTime.map { min(max(time - $0, 0), 1.0 / 20) } ?? 0
        lastTime = time

        let ease = 1 - exp(-dt * 4.5)
        var current = style ?? target.style
        let goal = target.style
        current.amplitude += (goal.amplitude - current.amplitude) * ease
        current.levelGain += (goal.levelGain - current.levelGain) * ease
        current.speed += (goal.speed - current.speed) * ease
        current.breath += (goal.breath - current.breath) * ease
        current.pulse += (goal.pulse - current.pulse) * ease
        current.shimmer += (goal.shimmer - current.shimmer) * ease
        current.sweep += (goal.sweep - current.sweep) * ease
        current.ring += (goal.ring - current.ring) * ease
        current.glow += (goal.glow - current.glow) * ease
        current.spread += (goal.spread - current.spread) * ease
        style = current

        // Fast attack, slower release: the orb jumps with a syllable and settles gently.
        let levelRate = target.level > level ? 18.0 : 6.0
        level += (target.level - level) * (1 - exp(-dt * levelRate))

        let goalColor = SIMD4<Float>(target.color.linearRed, target.color.linearGreen, target.color.linearBlue, target.color.opacity)
        var mixed = color ?? goalColor
        mixed += (goalColor - mixed) * Float(1 - exp(-dt * 5))
        color = mixed

        phase += dt * current.speed * (1 + 2.4 * level)
        pulsePhase += dt * (4.0 + 3.0 * level)
        shimmerAngle += dt * (2 * .pi / 2.2)
        sweepAngle += dt * (2 * .pi / 1.15)
        ringPhase += dt * (2 * .pi / 2.8)
        breathPhase += dt * (2 * .pi / 5.2)

        return OrbFrame(
            color: Color.Resolved(colorSpace: .sRGBLinear, red: mixed.x, green: mixed.y, blue: mixed.z, opacity: mixed.w),
            amplitude: current.amplitude,
            levelGain: current.levelGain,
            level: level,
            breathScale: 1 + 0.028 * current.breath * sin(breathPhase),
            pulse: current.pulse,
            pulsePhase: pulsePhase,
            phase: phase,
            shimmer: current.shimmer,
            shimmerAngle: shimmerAngle,
            sweep: current.sweep,
            sweepAngle: sweepAngle,
            ring: current.ring,
            ringPulse: 0.5 + 0.5 * sin(ringPhase),
            glow: current.glow,
            spread: current.spread
        )
    }
}

// MARK: - Rendering

enum OrbRenderer {
    static let contourCount = 7
    static let segments = 120

    static func draw(_ frame: OrbFrame, in context: inout GraphicsContext, size: CGSize, isDark: Bool) {
        let side = min(size.width, size.height)
        guard side > 2 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side / 2 * 0.76 * frame.breathScale
        let tint = Color(frame.color)
        let lineScale = max(0.55, side / 220)

        // Glow behind the contours.
        if frame.glow > 0.01 {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.3))
                let glowRadius = radius * (0.62 + 0.2 * frame.level)
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                    with: .color(tint.opacity((isDark ? 0.5 : 0.26) * frame.glow))
                )
            }
        }

        // Contours, inner to outer: denser and brighter at the centre, fading into the air.
        for index in 0..<contourCount {
            let f = Double(index) / Double(contourCount - 1)
            var contourRadius = radius * (0.36 + 0.64 * f)
            contourRadius *= 1 + frame.spread * frame.level * 0.09 * f
            contourRadius *= 1 + frame.pulse * (0.25 + frame.level) * 0.055 * sin(frame.pulsePhase - f * 2.6)
            let amplitude = (frame.amplitude + frame.levelGain * frame.level) * (0.45 + 0.55 * f)
            let path = contour(center: center, radius: contourRadius, amplitude: amplitude, phase: frame.phase, seed: Double(index))
            let alpha = 0.95 - 0.6 * f
            let width = (1.9 - 0.85 * f) * lineScale

            let shading: GraphicsContext.Shading
            if frame.shimmer > 0.01 {
                let low = alpha * (1 - 0.72 * frame.shimmer)
                let high = min(1, alpha + 0.4 * frame.shimmer)
                shading = .conicGradient(
                    Gradient(stops: [
                        .init(color: tint.opacity(high), location: 0),
                        .init(color: tint.opacity(low), location: 0.3),
                        .init(color: tint.opacity(low), location: 0.82),
                        .init(color: tint.opacity(high), location: 1),
                    ]),
                    center: center,
                    angle: .radians(frame.shimmerAngle - f * 0.8)
                )
            } else {
                shading = .color(tint.opacity(alpha))
            }
            context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }

        // Core.
        let coreRadius = radius * (0.24 + 0.05 * frame.level)
        let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [tint.opacity(isDark ? 0.82 : 0.72), tint]),
                center: CGPoint(x: center.x - coreRadius * 0.35, y: center.y - coreRadius * 0.4),
                startRadius: 0,
                endRadius: coreRadius * 1.6
            )
        )

        let haloRadius = radius * 1.17
        let halo = Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2))

        // Accent ring: waiting for the person.
        if frame.ring > 0.01 {
            context.stroke(halo, with: .color(tint.opacity(0.16 * frame.ring * (0.55 + 0.45 * frame.ringPulse))), lineWidth: 11 * lineScale)
            context.stroke(halo, with: .color(tint.opacity(frame.ring)), lineWidth: 2.4 * lineScale)
        }

        // Progress sweep: executing.
        if frame.sweep > 0.01 {
            context.stroke(halo, with: .color(tint.opacity(0.16 * frame.sweep)), lineWidth: 3 * lineScale)
            var arc = Path()
            arc.addArc(center: center, radius: haloRadius, startAngle: .radians(frame.sweepAngle), endAngle: .radians(frame.sweepAngle + 1.7), clockwise: false)
            context.stroke(arc, with: .color(tint.opacity(frame.sweep)), style: StrokeStyle(lineWidth: 3 * lineScale, lineCap: .round))
        }
    }

    /// A closed, smooth contour whose radius wanders with a few low harmonics.
    static func contour(center: CGPoint, radius: Double, amplitude: Double, phase: Double, seed: Double) -> Path {
        var points: [CGPoint] = []
        points.reserveCapacity(segments)
        for step in 0..<segments {
            let theta = Double(step) / Double(segments) * 2 * .pi
            let wander = 0.55 * sin(3 * theta + phase + seed * 1.7)
                + 0.3 * sin(5 * theta - phase * 1.35 + seed * 0.9)
                + 0.15 * sin(2 * theta + phase * 0.6 + seed * 2.3)
            let r = radius * (1 + amplitude * wander)
            points.append(CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta)))
        }
        var path = Path()
        let count = points.count
        path.move(to: midpoint(points[count - 1], points[0]))
        for index in 0..<count {
            let next = points[(index + 1) % count]
            path.addQuadCurve(to: midpoint(points[index], next), control: points[index])
        }
        path.closeSubpath()
        return path
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

#Preview("Orb modes") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 24) {
            ForEach(OrbMode.allCases) { mode in
                VStack {
                    OrbView(mode: mode, inputLevel: 0.5, outputLevel: 0.5)
                        .frame(width: 140, height: 140)
                    Text(mode.rawValue).textStyle(.footnote).foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .padding()
    }
}
