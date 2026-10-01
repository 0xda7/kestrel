// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SpeechInputMethod: String, CaseIterable, Identifiable {
    case apple
    case whisper

    var id: String { rawValue }
}

enum WhisperLoadPolicy: String, CaseIterable, Identifiable {
    case onDemand
    case alwaysLoaded

    var id: String { rawValue }
}
