//
//  SheetGrabber.swift
//  kebab
//

import SwiftUI

/// Standard grabber capsule shown at the top of every floating bottom sheet
/// (never on full-screen flows, whose affordance is the X/✓ header).
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Style.Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
    }
}
