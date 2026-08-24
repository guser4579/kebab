//
//  MetaballBackground.swift
//  kebab
//
//  Ambient monochrome metaball field behind the welcome screen: a handful
//  of large drifting masses are drawn into a Canvas layer, blurred into one
//  another, then cut by an alpha threshold so they read as a single viscous
//  silhouette that slowly merges and pinches apart — the matter inside a
//  lava lamp, never circles bouncing in a box. Purely decorative: it takes
//  no touches, participates in no layout, and is trivial to unmount.
//
//  Motion is a sum of fixed sine waves — two incommensurate components per
//  axis per mass, with no two periods shared anywhere in the field — so the
//  drift never visibly loops, never jumps, and stays smooth indefinitely.
//

import SwiftUI

struct MetaballBackground: View {

    // MARK: - Tuning knobs

    /// How many of the authored control masses render (capped at the table).
    var massCount: Int = 6
    /// Global time multiplier over the authored 14–54s periods. 1 = shipped
    /// pace; 2 = twice as fast. Useful for quickly auditioning the motion.
    var speed: Double = 1
    /// Multiplies every mass radius. The authored table is drawn at 0.95 —
    /// masses run 5% under their listed radii.
    var sizeScale: CGFloat = 0.95
    /// Multiplies the merge blur — higher = gooier, bridges form earlier
    /// and pinch apart later.
    var softness: CGFloat = 1
    /// THE visibility knob: opacity of the whole field over the app
    /// background. Raise/lower this first when tuning presence.
    var intensity: Double = 0.12
    /// Stops the timeline entirely (the field holds its current frame).
    /// For always-mounted hosts that park offscreen — no ticking while the
    /// surface can't be seen. Resuming picks the wall clock back up, so the
    /// field continues rather than restarting.
    var paused: Bool = false

    /// The quieter expression for ambient surfaces (the Menu panel): the
    /// same field, same shapes, same crisp edges — lower presence, slower
    /// pace. Auth keeps the defaults as the strongest branded expression.
    static func ambient(paused: Bool = false) -> MetaballBackground {
        MetaballBackground(speed: 0.65, intensity: 0.07, paused: paused)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Frame the field freezes on under Reduce Motion — the visual stays,
    /// the drift stops. An arbitrary but fixed instant so the static
    /// composition is the same on every launch.
    private static let frozenTime: Double = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || paused)) { timeline in
            let t = reduceMotion
                ? Self.frozenTime
                : timeline.date.timeIntervalSinceReferenceDate * speed

            Canvas { context, size in
                let minSide = min(size.width, size.height)
                // Ink in light mode, bone in dark — the app's own text tone,
                // so the field stays monochrome and theme-correct for free.
                let tone = Style.Color.primaryText

                // Filters apply to the layer inside-out: merge blur first,
                // then the threshold that turns the blurred influence field
                // into one hard silhouette. No post-threshold softening —
                // the silhouette edge renders crisp, cut-paper sharp.
                context.addFilter(.alphaThreshold(min: 0.5, color: tone))
                context.addFilter(.blur(radius: minSide * 0.125 * softness))
                context.drawLayer { layer in
                    for mass in Self.masses.prefix(max(0, massCount)) {
                        layer.fill(
                            mass.path(at: t, in: size, sizeScale: sizeScale),
                            with: .color(tone)
                        )
                    }
                }
            }
        }
        .opacity(intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Field model

    /// One sinusoidal motion component.
    private struct Wave {
        var amp: CGFloat
        var period: Double
        var phase: Double

        func value(at t: Double) -> CGFloat {
            amp * CGFloat(sin(t * 2 * .pi / period + phase))
        }
    }

    /// One control mass: a base anchor in unit screen coordinates (allowed
    /// to sit outside 0...1 so the composition feels larger than the
    /// viewport), a radius as a fraction of the screen's shorter side, a
    /// slow breathing cycle, a stretch cycle that trades width for height,
    /// two drift waves per axis, and two contour harmonics that dent and
    /// bulge the outline so the source form reads as hand-shaped rather
    /// than geometric — mostly round, never a true circle or ellipse.
    private struct Mass {
        var base: CGPoint
        var radius: CGFloat
        var breath: Wave
        var stretch: Wave
        var x1: Wave
        var x2: Wave
        var y1: Wave
        var y2: Wave
        /// Contour harmonics. `amp` is the radial deviation as a fraction of
        /// the radius; `period` is how long one dent takes to crawl once
        /// around the outline; `phase` offsets where it starts. Two low
        /// harmonics (2 and 3 lobes) at small amplitude keep the
        /// irregularity smooth and calm — asymmetry, not noise.
        var wobble2: Wave
        var wobble3: Wave

        func path(at t: Double, in size: CGSize, sizeScale: CGFloat) -> Path {
            let cx = (base.x + x1.value(at: t) + x2.value(at: t)) * size.width
            let cy = (base.y + y1.value(at: t) + y2.value(at: t)) * size.height
            let r = radius * min(size.width, size.height)
                * (1 + breath.value(at: t)) * sizeScale
            let e = stretch.value(at: t)
            let rx = r * (1 + e)
            let ry = r * (1 - e)
            // The dents advance around the contour by slow phase rotation —
            // the only motion the outline has, so it evolves without ever
            // jittering.
            let p2 = Double(wobble2.phase) + t * 2 * .pi / wobble2.period
            let p3 = Double(wobble3.phase) + t * 2 * .pi / wobble3.period

            // A polygon is plenty: 48 segments put facet detail far below
            // the merge blur, so the rendered edge is perfectly smooth.
            var path = Path()
            for i in 0..<48 {
                let a = Double(i) / 48 * 2 * .pi
                let f = 1
                    + wobble2.amp * CGFloat(sin(2 * a + p2))
                    + wobble3.amp * CGFloat(sin(3 * a + p3))
                let pt = CGPoint(
                    x: cx + CGFloat(cos(a)) * rx * f,
                    y: cy + CGFloat(sin(a)) * ry * f
                )
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.closeSubpath()
            return path
        }
    }

    /// The authored composition. Anchors spread across and beyond every
    /// screen edge; every period in the table is unique so no two motions
    /// ever synchronize.
    private static let masses: [Mass] = [
        // Broad mass anchored below the screen, slowly rising and sinking.
        Mass(base: CGPoint(x: 0.40, y: 1.04), radius: 0.42,
             breath: Wave(amp: 0.10, period: 47.0, phase: 0.9),
             stretch: Wave(amp: 0.10, period: 38.3, phase: 1.8),
             x1: Wave(amp: 0.10, period: 31.0, phase: 0.0),
             x2: Wave(amp: 0.04, period: 13.7, phase: 2.1),
             y1: Wave(amp: 0.075, period: 43.0, phase: 4.2),
             y2: Wave(amp: 0.03, period: 17.3, phase: 1.3),
             wobble2: Wave(amp: 0.07, period: 61.0, phase: 0.4),
             wobble3: Wave(amp: 0.035, period: 44.3, phase: 2.7)),
        // Right-edge mass leaning in and out of frame.
        Mass(base: CGPoint(x: 1.05, y: 0.36), radius: 0.34,
             breath: Wave(amp: 0.12, period: 53.0, phase: 2.0),
             stretch: Wave(amp: 0.14, period: 31.7, phase: 4.1),
             x1: Wave(amp: 0.11, period: 37.0, phase: 1.5),
             x2: Wave(amp: 0.05, period: 15.9, phase: 0.4),
             y1: Wave(amp: 0.12, period: 23.5, phase: 3.3),
             y2: Wave(amp: 0.03, period: 11.9, phase: 5.1),
             wobble2: Wave(amp: 0.08, period: 57.0, phase: 3.8),
             wobble3: Wave(amp: 0.040, period: 36.1, phase: 1.2)),
        // Upper-left mass, mostly offscreen.
        Mass(base: CGPoint(x: -0.06, y: 0.12), radius: 0.32,
             breath: Wave(amp: 0.14, period: 41.0, phase: 5.5),
             stretch: Wave(amp: 0.12, period: 26.9, phase: 0.6),
             x1: Wave(amp: 0.13, period: 29.0, phase: 3.9),
             x2: Wave(amp: 0.05, period: 19.1, phase: 0.7),
             y1: Wave(amp: 0.07, period: 47.5, phase: 2.6),
             y2: Wave(amp: 0.03, period: 14.3, phase: 4.4),
             wobble2: Wave(amp: 0.075, period: 66.0, phase: 5.9),
             wobble3: Wave(amp: 0.045, period: 40.9, phase: 0.1)),
        // Mid-field wanderer riding the seam between the bottom and right
        // masses — the connector whose drift forms and pinches bridges.
        Mass(base: CGPoint(x: 0.66, y: 0.66), radius: 0.24,
             breath: Wave(amp: 0.16, period: 37.7, phase: 1.1),
             stretch: Wave(amp: 0.18, period: 22.9, phase: 3.4),
             x1: Wave(amp: 0.13, period: 43.5, phase: 5.0),
             x2: Wave(amp: 0.05, period: 16.3, phase: 2.8),
             y1: Wave(amp: 0.10, period: 19.7, phase: 0.2),
             y2: Wave(amp: 0.04, period: 12.7, phase: 3.6),
             wobble2: Wave(amp: 0.09, period: 51.5, phase: 2.3),
             wobble3: Wave(amp: 0.050, period: 30.7, phase: 4.6)),
        // Top mass hanging over the status-bar region.
        Mass(base: CGPoint(x: 0.47, y: -0.05), radius: 0.27,
             breath: Wave(amp: 0.12, period: 49.0, phase: 3.2),
             stretch: Wave(amp: 0.15, period: 34.7, phase: 5.2),
             x1: Wave(amp: 0.15, period: 27.3, phase: 0.8),
             x2: Wave(amp: 0.05, period: 14.9, phase: 4.9),
             y1: Wave(amp: 0.08, period: 53.5, phase: 5.8),
             y2: Wave(amp: 0.03, period: 18.7, phase: 2.2),
             wobble2: Wave(amp: 0.08, period: 58.7, phase: 1.0),
             wobble3: Wave(amp: 0.045, period: 33.3, phase: 5.3)),
        // Left-mid mass drifting through the deck region.
        Mass(base: CGPoint(x: -0.05, y: 0.66), radius: 0.28,
             breath: Wave(amp: 0.11, period: 43.7, phase: 4.7),
             stretch: Wave(amp: 0.13, period: 24.7, phase: 2.9),
             x1: Wave(amp: 0.12, period: 33.9, phase: 2.4),
             x2: Wave(amp: 0.05, period: 17.7, phase: 5.7),
             y1: Wave(amp: 0.10, period: 25.6, phase: 1.7),
             y2: Wave(amp: 0.04, period: 13.1, phase: 0.5),
             wobble2: Wave(amp: 0.075, period: 63.5, phase: 4.2),
             wobble3: Wave(amp: 0.040, period: 42.1, phase: 2.0)),
        // Spare bottom-right mass, off by default (massCount 6).
        Mass(base: CGPoint(x: 0.90, y: 1.00), radius: 0.22,
             breath: Wave(amp: 0.13, period: 39.3, phase: 0.3),
             stretch: Wave(amp: 0.16, period: 29.3, phase: 1.2),
             x1: Wave(amp: 0.11, period: 35.5, phase: 4.4),
             x2: Wave(amp: 0.04, period: 15.1, phase: 1.9),
             y1: Wave(amp: 0.09, period: 28.9, phase: 5.4),
             y2: Wave(amp: 0.03, period: 16.9, phase: 3.0),
             wobble2: Wave(amp: 0.085, period: 55.1, phase: 0.8),
             wobble3: Wave(amp: 0.045, period: 38.9, phase: 3.5)),
    ]
}
