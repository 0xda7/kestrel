// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Guardian slice (2026-10-23): a failed local file transcription must
/// surface, never silently delete, the user's attachment. The chip stays
/// with a visible failure note where the transcript would have gone, and a
/// typed error naming the file joins attachError — the same surfacing
/// shape as the scanned-PDF OCR branch. Pure so the check suite can pin
/// the disposition without rendering SwiftUI.
enum FailedTranscriptionDisposition {
    /// Returns the attachments with the failed chip's "transcribing…"
    /// placeholder swapped for the failure note. A chip the operator
    /// already removed stays removed.
    static func settle(_ attachments: [ChatAttachment], attachmentID: UUID,
                       loc: Localizer) -> [ChatAttachment] {
        guard let idx = attachments.firstIndex(where: { $0.id == attachmentID }) else {
            return attachments
        }
        var out = attachments
        out[idx].content = note(loc)
        return out
    }

    /// The note left where the transcript would have gone.
    static func note(_ loc: Localizer) -> String {
        loc.t("(no se pudo transcribir localmente)", "(couldn't transcribe it locally)")
    }

    /// The typed error line naming the file, appended to any prior
    /// attachError exactly like the OCR branch joins its failures.
    static func errorLine(naming name: String, after previous: String?,
                          loc: Localizer) -> String {
        (previous.map { $0 + "\n" } ?? "")
            + loc.t("%@: falló la transcripción local", "%@: local transcription failed", name)
    }
}
