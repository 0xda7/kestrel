// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

enum AudioTranscriptMode: String, CaseIterable, Identifiable {
    case original
    case translated
    case bilingual

    var id: String { rawValue }
}
