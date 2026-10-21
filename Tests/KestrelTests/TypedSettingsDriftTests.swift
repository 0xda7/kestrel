// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The W4 type-drift class, pinned BEFORE conversion (census C2): a legacy or
/// imported String stored under a numeric/Bool key is non-nil, so every
/// `object == nil ? default : .integer/.bool(forKey:)` reader sails past its
/// nil-check and Foundation silently coerces what it recognizes ("4096" reads
/// as 4096, "true" as true — desyncing the engine from the @AppStorage UI,
/// which shows the declared default) and silently zeroes what it does not
/// ("on"/"garbage" read as false/0). Worst case first (W4-7, security): the
/// bool reader recognizes only true/yes/1, so a stored "on" — the classic
/// legacy-true spelling — reads false and un-arms the KES-01 key requirement
/// for LAN binds without telling anyone. These checks assert the
/// POST-conversion contract against the CURRENT readers, so they are RED on
/// pre-conversion code — that RED run is the drill that proves the
/// vulnerability is real — and the registry conversion turns them green.
final class TypedSettingsDriftTests: CheckCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "typed-settings-drift-tests")
        suite.removePersistentDomain(forName: "typed-settings-drift-tests")
    }

    override func tearDown() {
        // Drift seeds under .standard are cleaned per-check via defer; this is
        // the backstop for anything the body never reached.
        for key in [SettingsKeys.apiKeyEnabled, SettingsKeys.ctx, SettingsKeys.port,
                    SettingsKeys.loadVision] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        suite.removePersistentDomain(forName: "typed-settings-drift-tests")
        super.tearDown()
    }

    /// W4-7 drill: a String under the API-key gate key must keep the gate
    /// ARMED. The stored intent says protection is on; an unreadable value is
    /// corruption, never consent to un-arm.
    func testAPIKeyGateStaysArmedUnderDrift() {
        let d = UserDefaults.standard
        d.removeObject(forKey: SettingsKeys.apiKeyEnabled)
        defer { d.removeObject(forKey: SettingsKeys.apiKeyEnabled) }
        // "on": the classic legacy-true spelling. Foundation's bool(forKey:)
        // recognizes only true/yes/1, so current code reads false here.
        d.set("on", forKey: SettingsKeys.apiKeyEnabled)
        XCTAssertTrue(ServerSettings.fromDefaults().apiKeyEnabled,
                      "a String under apiKeyEnabled must not read as false — the KES-01 key requirement stays armed")
        XCTAssertNotNil(ServerSettings.activeAPIKey(),
                        "the chat's API-key gate stays armed under drift (Server.swift activeAPIKey)")
    }

    /// W4-1/W4-2: drift under an Int key yields the declared default — never a
    /// silent 0 (garbage: a zero context window), never a silent coercion
    /// ("9999": the engine runs it while the @AppStorage UI shows 8080).
    func testIntDriftYieldsDeclaredDefault() {
        let d = UserDefaults.standard
        for key in [SettingsKeys.ctx, SettingsKeys.port] { d.removeObject(forKey: key) }
        defer { for key in [SettingsKeys.ctx, SettingsKeys.port] { d.removeObject(forKey: key) } }
        d.set("garbage", forKey: SettingsKeys.ctx)
        d.set("9999", forKey: SettingsKeys.port)
        let s = ServerSettings.fromDefaults()
        XCTAssertEqual(s.ctx, 16384,
                       "a String under ctx must yield the declared 16384 default, not a silent 0")
        XCTAssertEqual(s.port, 8080,
                       "a String under port must yield the declared 8080 default, not a silently coerced 9999")
    }

    /// W4-4: drift under a VAD Double key falls back to the balanced profile's
    /// threshold, not a silently coerced value the @AppStorage UI never shows.
    func testVADThresholdDriftYieldsBalancedFallback() {
        suite.set(AudioVADProfile.custom.rawValue, forKey: SettingsKeys.audioVADProfile)
        suite.set("0.35", forKey: SettingsKeys.audioVADThreshold)
        XCTAssertEqual(AudioVADPreferences.calibration(defaults: suite).threshold, 0.5,
                       "a String under audioVADThreshold must yield the balanced fallback, not a silent coercion")
    }

    /// W4-5/W4-6 class: a Bool declared default of true survives drift — a
    /// stored String ("off") reads false today, silently disabling the thing.
    func testAbsentTrueBoolSurvivesDrift() {
        let d = UserDefaults.standard
        d.removeObject(forKey: SettingsKeys.loadVision)
        defer { d.removeObject(forKey: SettingsKeys.loadVision) }
        d.set("off", forKey: SettingsKeys.loadVision)
        XCTAssertTrue(ServerSettings.fromDefaults().loadVision,
                      "a String under loadVision must yield the declared true default, not a silent false")
    }
}

// MARK: - Generated registration (port from XCTest)
extension TypedSettingsDriftTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "TypedSettingsDriftTests",
        instance: { TypedSettingsDriftTests() },
        checks: [
            .init(name: "testAPIKeyGateStaysArmedUnderDrift") { $0.testAPIKeyGateStaysArmedUnderDrift() },
            .init(name: "testIntDriftYieldsDeclaredDefault") { $0.testIntDriftYieldsDeclaredDefault() },
            .init(name: "testVADThresholdDriftYieldsBalancedFallback") { $0.testVADThresholdDriftYieldsBalancedFallback() },
            .init(name: "testAbsentTrueBoolSurvivesDrift") { $0.testAbsentTrueBoolSurvivesDrift() },
        ])
}
