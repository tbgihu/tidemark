import AppKit
import SwiftUI

/// The provider tabs' selection on the move, as the system's own tab bars move theirs: the shaded highlight lifts into
/// Liquid Glass, glides to the new tab, squashing wider and flatter with its speed, and fades back to shaded over the
/// same time before it arrives, so it lands shaded. Its centre comes in on a critically damped spring, never past the
/// tab; the shape follows the speed on a softer spring of its own, so as it brakes it eases just past its width and
/// settles back, as liquid comes to rest. The highlight itself makes the move, frame by frame under the
/// labels, and the glass follows it on top, so it rests exactly where it lands.
struct Glide {
    /// The centre's spring: critically damped, a response of 0.32 s, so 98.5% of the way in about 0.32 s.
    static let response = 0.32
    static let omega = 2 * Double.pi / response
    /// The shape's spring: damped just enough to settle, not ring, so as the speed falls it eases a fraction of a point
    /// past its width and floats back to rest by about half a second.
    static let jellyOmega = 2 * Double.pi / 0.24
    static let jellyDamping = 0.45
    /// How long the lift into glass takes, and the return to shaded: short, so the glass is whole for most of the way.
    static let fade = 0.12
    /// The centre's speed at its fastest on a move from rest (at 1/ω), where the squash is at its widest.
    static let peak = omega / M_E

    let from: CGRect, to: CGRect
    /// Whether it starts already in glass: a move that redirects one under way doesn't lift again.
    let lifted: Bool
    /// When the return to shaded begins: so it ends as the centre is within 1.5% of the tab, before it settles.
    let fadeOutAt: Double
    private let b: Double
    /// The shape: its squash (wider and flatter above 0, narrower and taller below), how fast that changes, and the
    /// time it was worked out for.
    private(set) var squash: Double, squashSpeed: Double
    private var time = 0.0

    /// A move from `from` to `to`, its centre starting at `velocity` (of the whole way, per second) and its shape
    /// where a move it redirects left it.
    init(from: CGRect = .zero, to: CGRect = .zero, velocity: Double, lifted: Bool = false,
         squash: Double = 0, squashSpeed: Double = 0) {
        self.from = from
        self.to = to
        self.lifted = lifted
        b = velocity - Self.omega
        self.squash = squash
        self.squashSpeed = squashSpeed
        let b = b
        let near = stride(from: 0.0, to: 1.0, by: 0.004).first { Self.centre(b, $0).x >= 0.985 } ?? 0.3
        fadeOutAt = max(near - Self.fade, lifted ? 0 : Self.fade)
    }

    /// The centre at `t`: from 0 to 1, never past it.
    private static func centre(_ b: Double, _ t: Double) -> (x: Double, v: Double) {
        let decay = exp(-omega * t), y = (-1 + b * t) * decay
        let x = 1 + y, v = (b - omega * (-1 + b * t)) * decay
        return x >= 1 ? (1, 0) : (x, v)
    }

    /// Works the move out to `t`: how far along the centre is, how fast it moves, the shape's squash, and whether it
    /// all rests (the centre within a hundredth of a point of the tab, the shape still).
    mutating func advance(to t: Double) -> (position: Double, velocity: Double, squash: Double, resting: Bool) {
        let dt = 0.001
        while time + dt <= t {
            time += dt
            let speed = min(max(Self.centre(b, time).v / Self.peak, 0), 1)
            let pull = Self.jellyOmega * Self.jellyOmega * (speed - squash) - 2 * Self.jellyDamping * Self.jellyOmega * squashSpeed
            squashSpeed += pull * dt
            squash += squashSpeed * dt
        }
        let (x, v) = Self.centre(b, t)
        return (x, v, squash, t > 0.2 && 1 - x < 0.0002 && abs(squash) < 0.002 && abs(squashSpeed) < 0.05)
    }

    /// The shaded highlight's opacity at `t`: out as the glass lifts, back as it settles, on the same curve.
    func shade(at t: Double) -> Double {
        func ease(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
        return (lifted ? 0 : 1 - ease(t / Self.fade)) + ease((t - fadeOutAt) / Self.fade)
    }

    /// The shape with its centre at `position` and its `squash`: wider and flatter by up to two fifths of a tab, or,
    /// below 0, narrower and taller, about its centre.
    func frame(position: Double, squash: Double) -> CGRect {
        let t = CGFloat(position), along = min(max(t, 0), 1)
        let x = from.midX + (to.midX - from.midX) * t, y = from.midY + (to.midY - from.midY) * t
        var width = from.width + (to.width - from.width) * along, height = from.height + (to.height - from.height) * along
        let squash = CGFloat(min(max(squash, -0.6), 1.2))
        width += min(abs(to.midX - from.midX) * 0.32, to.width * 0.4) * squash
        height -= height * 0.08 * squash
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }
}

/// The glass over the moving highlight: clear Liquid Glass of the highlight's shape, which materializes and
/// dematerializes as the system's glass does (glass can't fade by opacity). In the window only while a move is under
/// way; clicks pass through it.
@MainActor
final class GlideLens {
    private let model = Model()
    let view: NSView

    init() {
        let view = PassThrough(rootView: Lens(model: model))
        view.sizingOptions = []
        view.setAccessibilityElement(false)
        self.view = view
    }

    /// The glass's shape, in `view`'s coordinates.
    var frame: CGRect {
        get { model.frame }
        set {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.frame = newValue }
        }
    }

    /// Lifts into glass (true) or settles back out of it (false), over `Glide.fade`.
    func glass(_ on: Bool) {
        guard model.glass != on else { return }
        withAnimation(.smooth(duration: Glide.fade)) { model.glass = on }
    }

    func reset() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { model.glass = false }
        view.removeFromSuperview()
    }

    @MainActor @Observable
    final class Model {
        var frame = CGRect.zero
        var glass = false
    }

    struct Lens: View {
        let model: Model
        var body: some View {
            let frame = model.frame
            GlassEffectContainer {
                Color.clear
                    .frame(width: frame.width, height: frame.height)
                    .glassEffect(model.glass ? .clear : .identity, in: .rect(cornerRadius: 11, style: .continuous))
                    .offset(x: frame.minX, y: frame.minY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    final class PassThrough: NSHostingView<Lens> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
