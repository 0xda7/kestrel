// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Support popup: routes to the project's sponsor page.
struct DonateView: View {
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(spacing: 12) {
            Label(loc.t("Apoya el proyecto", "Support the project"), systemImage: "heart.fill")
                .font(.headline).foregroundStyle(Color.appAccent)
            Text(AppInfo.donateNoteEN)
                .font(.callout).multilineTextAlignment(.center)
                .frame(width: 300)

            // The sponsor page is the easiest path, so it leads.
            Button {
                if let url = URL(string: AppInfo.sponsorURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gift.fill").font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loc.t("Conviértete en patrocinador", "Become a sponsor"))
                            .fontWeight(.semibold)
                        Text(loc.t("Apoya el desarrollo de Kestrel",
                                   "Support Kestrel development"))
                            .font(.caption2).opacity(0.85)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.forward").font(.caption)
                }
                .padding(.vertical, 5).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Color.appAccent).controlSize(.large)
            .frame(width: 300)
        }
        .padding(16)
        .frame(width: 340)
    }
}
