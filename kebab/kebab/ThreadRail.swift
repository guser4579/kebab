//
//  ThreadRail.swift
//  kebab
//

import SwiftUI

/// How one row participates in the thread spine.
///
/// The thread is drawn as a *focus* hierarchy, not an absolute-depth one.
/// Exactly two horizontal planes exist on any thread screen: the focal object
/// — whatever the user navigated to — owns the full-width content plane and
/// carries no gutter at all, and everything around it (the context above, the
/// subordinate replies below) sits in the single shared gutter column with the
/// spine. Because there are only ever two planes, depth 1 and depth 20 have
/// identical geometry and the usable content column never shrinks.
///
/// Every row that sits in the gutter carries a node — that group reads as one
/// structure, never as decorations that appear on some rows and not others.
/// Rails connect those nodes; they never run *through* the focal row, which is
/// what keeps the focal object from flattening into its own context.
enum ThreadRail {
    /// Node + rail flowing down; nothing rendered above — the root Entry, or
    /// an anchor with no parent context on screen.
    case origin
    /// Incoming rail + node + outgoing rail — a mid-chain row.
    case link
    /// Incoming rail + node, and the rail stops there: the last visible row
    /// of the chain. Ends on the node, so the chain closes on a point rather
    /// than trailing off.
    case terminus
    /// Short incoming lead-in with no node: context above the focal object.
    /// The spine ends cleanly before the focal row begins, which is what makes
    /// "context above / the thing I landed on" legible.
    case stub
}

extension ThreadRail {
    /// Rail state for row `index` of a `count`-row subordinate group hanging
    /// beneath a focal object. The group owns its own spine run: it closes on
    /// a node rather than trailing off, and it never runs a rail through the
    /// focal row above it.
    ///
    /// A group of one is just a terminus with nothing before it: the rail
    /// descends from the row's top edge — where the focal object's hairline
    /// closes that plane — into the node and stops. That short run is what
    /// ties the lone subordinate to the object it belongs to; a bare node
    /// reads as a bullet, not as thread language.
    static func forChild(index: Int, of count: Int) -> ThreadRail {
        if index == count - 1 { return .terminus }
        if index == 0 { return .origin }
        return .link
    }
}

/// Gutter graphics for one row, drawn in an `.overlay(alignment: .topLeading)`.
///
/// Horizontal geometry is derived, not chosen: the threaded content column
/// starts at 40, so the spine axis is exactly halfway between the screen edge
/// and that column — x = 20. The node (8pt) and the rail (1pt) are both
/// centered on that axis, and horizontal dividers begin at the rail's right
/// edge so they meet the spine with no gap and no crossing.
///
/// Vertical geometry is equally fixed: every participating row places its
/// meta line after a 16pt top inset, and the meta line is a constant 24pt
/// tall, so its centerline is always y=28. The node is placed at that same
/// centerline (top y=24, height 8) — alignment is by construction, never by
/// measurement.
struct ThreadRailOverlay: View {

    let rail: ThreadRail

    /// Content column start for rows beside the gutter.
    static let contentLeading: CGFloat = 40
    /// The spine axis: halfway between the screen edge and the content column.
    static let axis: CGFloat = contentLeading / 2
    private static let nodeSize: CGFloat = 8
    private static let railWidth: CGFloat = 1
    /// Left inset for a 1pt rail centered on the axis.
    private static let railLeading: CGFloat = axis - railWidth / 2
    /// Left inset for the node, centered on the same axis.
    private static let nodeLeading: CGFloat = axis - nodeSize / 2
    /// Meta-line centerline: 16pt top inset + half of the 24pt meta row.
    private static let nodeCenterY: CGFloat = 28
    private static let nodeTop: CGFloat = nodeCenterY - nodeSize / 2
    private static let nodeBottom: CGFloat = nodeCenterY + nodeSize / 2

    /// Where a horizontal divider starts so it meets the spine exactly: the
    /// rail's right edge — touching, never crossing, never short.
    static let dividerLeading: CGFloat = axis + railWidth / 2

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch rail {
            case .origin:
                railBelowNode
            case .link:
                railSegment(height: Self.nodeTop)
                railBelowNode
            case .terminus:
                railSegment(height: Self.nodeTop)
            case .stub:
                railSegment(height: 12)
            }

            if showsNode {
                Circle()
                    .fill(Style.Color.primaryText)
                    .frame(width: Self.nodeSize, height: Self.nodeSize)
                    .offset(x: Self.nodeLeading, y: Self.nodeTop)
            }
        }
    }

    /// Every gutter row shows a node; only the context stub does not.
    private var showsNode: Bool {
        switch rail {
        case .origin, .link, .terminus: return true
        case .stub: return false
        }
    }

    /// A rail run starting at the row's top edge.
    private func railSegment(height: CGFloat) -> some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(width: Self.railWidth, height: height)
            .padding(.leading, Self.railLeading)
    }

    /// From the node's bottom edge to the bottom of the row.
    private var railBelowNode: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: Self.railWidth, height: Self.nodeBottom)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity)
        }
        .padding(.leading, Self.railLeading)
    }
}
