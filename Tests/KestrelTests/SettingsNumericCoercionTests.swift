// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The operator's defaults contained `"chatTemp" = "0.564097973184848"` — a
/// String where @AppStorage(Double) expects a number, so the tuned value
/// silently never applied. Numeric chat keys must be written typed, mistyped
/// legacy strings coerced (or dropped to the declared default), and the
/// settings import must never store a String for them again.
final class SettingsNumericCoercionTests: CheckCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "settings-numeric-coercion-tests")
        suite.removePersistentDomain(forName: "settings-numeric-coercion-tests")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "settings-numeric-coercion-tests")
        super.tearDown()
    }

    func testStringDoubleIsRewrittenTyped() {
        suite.set("0.564097973184848", forKey: SettingsKeys.chatTemp)
        let touched = SettingsNumericCoercion.migrateMistypedNumerics(in: suite)
        XCTAssertTrue(touched.contains(SettingsKeys.chatTemp))
        XCTAssertFalse(suite.object(forKey: SettingsKeys.chatTemp) is String,
                       "chatTemp must never linger as a String after migration")
        XCTAssertEqual(suite.double(forKey: SettingsKeys.chatTemp), 0.564097973184848, accuracy: 1e-12,
                       "the tuned temperature must survive the rewrite bit-for-bit")
    }

    func testStringIntIsRewrittenTyped() {
        suite.set("4096", forKey: SettingsKeys.chatMaxTokens)
        suite.set("7", forKey: SettingsKeys.chatAgenticMaxTurns)
        suite.set("40.0", forKey: SettingsKeys.chatTopK)
        _ = SettingsNumericCoercion.migrateMistypedNumerics(in: suite)
        XCTAssertEqual(suite.object(forKey: SettingsKeys.chatMaxTokens) as? Int, 4096)
        XCTAssertEqual(suite.object(forKey: SettingsKeys.chatAgenticMaxTurns) as? Int, 7)
        XCTAssertEqual(suite.object(forKey: SettingsKeys.chatTopK) as? Int, 40,
                       "a float-formatted string for an Int key rounds through Double instead of being discarded")
    }

    func testGarbageStringFallsBackToDeclaredDefault() {
        suite.set("garbage", forKey: SettingsKeys.chatTemp)
        suite.set("not-a-number", forKey: SettingsKeys.chatTopK)
        _ = SettingsNumericCoercion.migrateMistypedNumerics(in: suite)
        XCTAssertNil(suite.object(forKey: SettingsKeys.chatTemp),
                     "an unparseable string is removed so @AppStorage applies its declared default")
        XCTAssertNil(suite.object(forKey: SettingsKeys.chatTopK))
    }

    func testTypedValuesAreLeftAlone() {
        suite.set(0.7, forKey: SettingsKeys.chatTemp)
        suite.set(512, forKey: SettingsKeys.chatMaxTokens)
        let touched = SettingsNumericCoercion.migrateMistypedNumerics(in: suite)
        XCTAssertFalse(touched.contains(SettingsKeys.chatTemp))
        XCTAssertFalse(touched.contains(SettingsKeys.chatMaxTokens))
        XCTAssertEqual(suite.double(forKey: SettingsKeys.chatTemp), 0.7, accuracy: 1e-12)
    }

    func testImportNeverStoresStringsForNumericKeys() throws {
        let json = #"{"format":"kestrel-settings","version":1,"config":{"chatTemp":"0.9","chatTopK":"40"}}"#
        let count = try SettingsArchive.importData(Data(json.utf8), defaults: suite)
        XCTAssertEqual(count, 2)
        XCTAssertFalse(suite.object(forKey: SettingsKeys.chatTemp) is String,
                       "the import path is the writer that produced the mistyped chatTemp; it must store Double")
        XCTAssertEqual(suite.double(forKey: SettingsKeys.chatTemp), 0.9, accuracy: 1e-12)
        XCTAssertEqual(suite.object(forKey: SettingsKeys.chatTopK) as? Int, 40)
    }

    func testImportGarbageStringDropsToDeclaredDefault() throws {
        let json = #"{"format":"kestrel-settings","version":1,"config":{"chatTemp":"garbage"}}"#
        _ = try SettingsArchive.importData(Data(json.utf8), defaults: suite)
        XCTAssertNil(suite.object(forKey: SettingsKeys.chatTemp),
                     "importing garbage must not write it back as a String")
    }
}

// MARK: - Generated registration (port from XCTest)
extension SettingsNumericCoercionTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SettingsNumericCoercionTests",
        instance: { SettingsNumericCoercionTests() },
        checks: [
            .init(name: "testStringDoubleIsRewrittenTyped") { $0.testStringDoubleIsRewrittenTyped() },
            .init(name: "testStringIntIsRewrittenTyped") { $0.testStringIntIsRewrittenTyped() },
            .init(name: "testGarbageStringFallsBackToDeclaredDefault") { $0.testGarbageStringFallsBackToDeclaredDefault() },
            .init(name: "testTypedValuesAreLeftAlone") { $0.testTypedValuesAreLeftAlone() },
            .init(name: "testImportNeverStoresStringsForNumericKeys") { try $0.testImportNeverStoresStringsForNumericKeys() },
            .init(name: "testImportGarbageStringDropsToDeclaredDefault") { try $0.testImportGarbageStringDropsToDeclaredDefault() },
        ])
}
