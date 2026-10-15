// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Pins the shared engine control-plane session every former ad-hoc
/// URLRequest path (health probe, slot save/restore, stream stop, compaction
/// summarize) now rides on: sane fail-fast timeouts, one request shape, and
/// one slot request shared by the server controller and the chat store.
final class EngineHTTPTests: CheckCase {
    /// The control session fails fast: a wedged engine must not hold a health
    /// probe (or any control request) open — the poll loop runs every 2 s.
    func testSessionCarriesSaneControlTimeouts() {
        XCTAssertEqual(EngineHTTP.session.configuration.timeoutIntervalForRequest, 10,
                       "a control request with no bytes for 10 s is a wedged engine")
        XCTAssertEqual(EngineHTTP.session.configuration.timeoutIntervalForResource, 60)
    }

    /// The one slot request both call sites issue: loopback /slots/0, POST,
    /// action in the query, filename in the JSON body, explicit per-request
    /// timeout overriding the session's 10 s default, and no Authorization
    /// header when the engine is unprotected.
    func testSlotRequestShapeIsShared() throws {
        let key = SettingsKeys.apiKeyEnabled
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let req = try XCTUnwrap(EngineHTTP.slotRequest(port: 8080, action: "save",
                                                       filename: "x.bin", timeout: 30))
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8080/slots/0?action=save")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.timeoutInterval, 30)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(req.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(obj["filename"], "x.bin")
    }

    /// The stop/DELETE builder: method and explicit short timeout carried,
    /// bearer key attached only when one is actually configured.
    func testRequestBuilderCarriesMethodTimeoutAndConditionalAuth() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1/stop/x"))
        let req = EngineHTTP.request(url: url, method: "DELETE", timeout: 5, apiKey: nil)
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.timeoutInterval, 5)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let keyed = EngineHTTP.request(url: url, method: "DELETE", timeout: 5, apiKey: "k")
        XCTAssertEqual(keyed.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }
}

// MARK: - Generated registration (port from XCTest)
extension EngineHTTPTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "EngineHTTPTests",
        instance: { EngineHTTPTests() },
        checks: [
            .init(name: "testSessionCarriesSaneControlTimeouts") { $0.testSessionCarriesSaneControlTimeouts() },
            .init(name: "testSlotRequestShapeIsShared") { try $0.testSlotRequestShapeIsShared() },
            .init(name: "testRequestBuilderCarriesMethodTimeoutAndConditionalAuth") { try $0.testRequestBuilderCarriesMethodTimeoutAndConditionalAuth() },
        ])
}
