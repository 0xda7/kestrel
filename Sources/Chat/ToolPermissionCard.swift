// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ToolPermissionCard: View {
    let request: PendingToolPermission
    let decide: (ToolPermissionDecision) -> Void
    @EnvironmentObject private var loc: Localizer
    @State private var showingArguments = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: request.writesData ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .foregroundStyle(request.writesData ? .orange : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.displayName).font(.callout.weight(.semibold))
                    Text(request.writesData
                         ? loc.t("Puede modificar archivos o ejecutar acciones.",
                                 "Can modify files or run actions.")
                         : loc.t("Solicita acceso de lectura.", "Requests read access."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(loc.t("Ver argumentos", "Show arguments"), systemImage: "chevron.down") {
                    showingArguments.toggle()
                }
                    .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            if showingArguments {
                Text(request.arguments.isEmpty ? "{}" : request.arguments)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            }
            if request.name == ChatToolsService.execShellToolName {
                // KES-05: shell execution confirms every call — there is no
                // standing consent for arbitrary commands on this account.
                Text(loc.t("Los comandos del shell piden confirmación cada vez.",
                           "Shell commands ask for confirmation every time."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button(loc.t("Denegar", "Deny"), role: .destructive) { decide(.deny) }
                Spacer()
                if request.name != ChatToolsService.execShellToolName {
                    if request.serverID != nil {
                        Button(loc.t("Siempre este servidor", "Always this server")) { decide(.alwaysServer) }
                    }
                    Button(loc.t("Permitir siempre en esta sesión", "Always for this session")) { decide(.always) }
                }
                Button(loc.t("Permitir una vez", "Allow once")) { decide(.once) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}
