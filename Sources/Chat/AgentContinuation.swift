// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct PendingAgentContinuation: Identifiable, Equatable {
    let conversationID: UUID
    var turnsUsed: Int
    /// The configured budget the run exhausted, so the card names the real
    /// limit instead of a hardcoded turn count.
    var turnLimit: Int
    var toolsExecuted: Int
    var id: UUID { conversationID }
}
