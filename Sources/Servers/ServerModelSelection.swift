// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension Profile {
    mutating func selectInstanceModel(path: String, ncmoe: Int, threads: Int? = nil) {
        modelPath = path
        self.ncmoe = ncmoe
        // A measured-best thread count pre-fills; nil keeps the current setting.
        if let threads { self.threads = threads }
        // nil is a legacy full snapshot; retain all its other overrides.
        if var pins = pinned, !pins.contains(Pin.model) {
            pins.append(Pin.model)
            pinned = pins
        }
    }
}

extension ServerController {
    /// Shared by the overview and expanded configuration. Never mutate another
    /// instance, and never change the displayed model underneath a running engine.
    func selectModel(path: String, ncmoe: Int, threads: Int? = nil) {
        guard state != .running && state != .starting else { return }
        if var profile {
            profile.selectInstanceModel(path: path, ncmoe: ncmoe, threads: threads)
            self.profile = profile
        } else {
            UserDefaults.standard.set(path, forKey: SettingsKeys.modelPath)
            UserDefaults.standard.set(ncmoe, forKey: SettingsKeys.ncmoe)
            if let threads { UserDefaults.standard.set(threads, forKey: SettingsKeys.threads) }
        }
    }
}
