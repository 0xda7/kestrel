// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum AudioStudioOperation: String, CaseIterable, Identifiable {
    case transcribe
    case translateEnglish
    case translateLocal

    var id: String { rawValue }
}
