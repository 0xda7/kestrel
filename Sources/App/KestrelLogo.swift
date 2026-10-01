// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Uses the exact icon shipped by the running application. Keeping this in one
/// component prevents the sidebar, onboarding and About views from drifting to
/// unrelated SF Symbols.
struct KestrelLogo: View {
    var size: CGFloat = 38

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Kestrel")
    }
}
