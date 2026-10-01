// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared navigation affordance used by every server configuration screen.
struct ServerConfigurationBackButton: View {
    @EnvironmentObject private var loc: Localizer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(loc.t("Volver al resumen", "Back to overview"), systemImage: "chevron.left")
        }
        .glassButton()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
