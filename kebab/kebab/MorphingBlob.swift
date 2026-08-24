//
//  MorphingBlob.swift
//  kebab
//
//  One small piece of the lava field, quietly alive: a single irregular
//  blob whose contour and size evolve very slowly. Used for the app-launch
//  loading state in place of a spinner.
//
//  Deliberately NOT the metaball renderer: one mass needs no blur or
//  alpha-threshold filter passes and no full-screen canvas — this draws a
//  single 48-segment path into a blob-sized Canvas, so a frame costs a
//  path fill instead of two full-screen filter passes. Same contour
//  principles as MetaballBackground's masses (low harmonics, slow phase
//  rotation, gentle breath), so it reads as the same material.
//

import SwiftUI

struct MorphingBlob: View {

    /// Diameter of the blob's neutral circle; the wobble stays within
    /// roughly ±12% of it.
    var size: CGFloat = 72
    /// Same visibility rule as the field: the app's text tone at low
    /// opacity over the app background.
    var intensity: Double = 0.12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Frozen instant for Reduce Motion — a static irregular blob.
    private static let frozenTime: Double = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion
                ? Self.frozenTime
                : timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, canvasSize in
                let cx = canvasSize.width / 2
                let cy = canvasSize.height / 2
                // Restrained breath (~6%) on a slow, non-looping pair of
                // periods; dents crawl around the contour by phase rotation,
                // exactly like the field's masses — smooth, never twitchy.
                let r = size / 2 * 0.86 * (1 + 0.06 * sin(t * 2 * .pi / 6.7))
                let p2 = t * 2 * .pi / 5.3
                let p3 = 2.1 + t * 2 * .pi / 7.9

                var path = Path()
                for i in 0..<48 {
                    let a = Double(i) / 48 * 2 * .pi
                    let f = 1
                        + 0.07 * sin(2 * a + p2)
                        + 0.05 * sin(3 * a + p3)
                    let pt = CGPoint(
                        x: cx + CGFloat(cos(a)) * r * f,
                        y: cy + CGFloat(sin(a)) * r * f
                    )
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                context.fill(path, with: .color(Style.Color.primaryText))
            }
        }
        .frame(width: size, height: size)
        .opacity(intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
