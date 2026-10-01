// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct PendingAgentContinuation: Identifiable, Equatable {
    let conversationID: UUID
    var turnsUsed: Int
    var toolsExecuted: Int
    var id: UUID { conversationID }
}
