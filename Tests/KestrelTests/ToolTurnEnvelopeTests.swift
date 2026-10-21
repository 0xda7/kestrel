// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission C1 Phase C pins: the tool-turn envelope — the response_format
/// schema bound to every tools-carrying request on the local bundled engine
/// (generic-path templates get it grammar-enforced; named families keep
/// their own channel grammar) — and its completion-time unwrap.
final class ToolTurnEnvelopeTests: CheckCase {
    private let offeredTools: Set<String> = ["read_file", "get_datetime"]

    private func definition(name: String,
                            parameters: [String: Any]?) -> [String: Any] {
        var function: [String: Any] = [
            "name": name,
            "description": "test tool",
        ]
        if let parameters { function["parameters"] = parameters }
        return ["type": "function", "function": function]
    }

    // MARK: Envelope shape

    /// The envelope carries exactly one branch per offered tool, in offer
    /// order, each with the tool's own name constant and parameters schema
    /// verbatim — plus the free-text reply branch that keeps prose legal.
    func testEnvelopeCarriesOneBranchPerToolPlusReply() throws {
        let parameters: [String: Any] = [
            "type": "object",
            "properties": ["path": ["type": "string"]],
            "required": ["path"],
        ]
        let format = try XCTUnwrap(
            ToolTurnEnvelope.responseFormat(definitions: [
                definition(name: "read_file", parameters: parameters),
                definition(name: "get_datetime", parameters: [:]),
            ]))

        XCTAssertEqual(format["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "kestrelToolTurn")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, false)
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        let branches = try XCTUnwrap(schema["oneOf"] as? [[String: Any]])
        XCTAssertEqual(branches.count, 3, "two tool branches plus the reply branch")

        let readFile = try XCTUnwrap(branches[0])
        XCTAssertEqual(readFile["type"] as? String, "object")
        let readProps = try XCTUnwrap(readFile["properties"] as? [String: Any])
        XCTAssertEqual((readProps["name"] as? [String: Any])?["const"] as? String, "read_file")
        // The tool's own parameters schema rides verbatim: the grammar
        // enforces argument shapes, not just JSON syntax.
        XCTAssertEqual(readProps["arguments"] as? NSDictionary,
                       parameters as NSDictionary)
        XCTAssertEqual(readFile["required"] as? [String], ["name", "arguments"])

        // A tool with an empty parameters schema gets a bare object.
        let datetime = try XCTUnwrap(branches[1])
        let dtProps = try XCTUnwrap(datetime["properties"] as? [String: Any])
        XCTAssertEqual((dtProps["name"] as? [String: Any])?["const"] as? String, "get_datetime")
        XCTAssertEqual(dtProps["arguments"] as? NSDictionary, ["type": "object"] as NSDictionary)

        // The reply branch keeps free text legal under the constraint.
        let reply = try XCTUnwrap(branches[2])
        let replyProps = try XCTUnwrap(reply["properties"] as? [String: Any])
        XCTAssertEqual(replyProps["reply"] as? NSDictionary, ["type": "string"] as NSDictionary)
        XCTAssertEqual(reply["required"] as? [String], ["reply"])
    }

    /// No surviving tool definitions → no envelope (a blocked or tool-less
    /// turn never binds the schema).
    func testEnvelopeRequiresOfferedTools() {
        XCTAssertNil(ToolTurnEnvelope.responseFormat(definitions: []))
        XCTAssertNil(ToolTurnEnvelope.responseFormat(definitions: [
            ["type": "function", "function": ["description": "nameless"]],
        ]))
    }

    // MARK: Constraint gate

    /// The constraint binds only for a local request on the bundled engine
    /// with tools actually offered: remote providers keep their native
    /// paths, custom engine binaries (which may predate json_schema) and
    /// blocked/tool-less turns keep the legacy unconstrained path.
    func testConstraintGates() {
        XCTAssertTrue(ToolTurnEnvelope.shouldConstrain(remote: false, engineKind: "bundled",
                                                       toolCount: 1))
        XCTAssertFalse(ToolTurnEnvelope.shouldConstrain(remote: true, engineKind: "bundled",
                                                        toolCount: 1))
        XCTAssertFalse(ToolTurnEnvelope.shouldConstrain(remote: false, engineKind: "custom",
                                                        toolCount: 1))
        XCTAssertFalse(ToolTurnEnvelope.shouldConstrain(remote: false, engineKind: "bundled",
                                                        toolCount: 0))
    }

    // MARK: Completion-time unwrap

    /// A name branch becomes exactly one pending call with the arguments
    /// re-serialized — the same shape a rescued call has, so permissions,
    /// execution, and history flow unchanged.
    func testUnwrapNameBranchBecomesAPendingCall() throws {
        let outcome = try XCTUnwrap(ToolTurnEnvelope.unwrap(
            text: "{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.txt\"}}",
            toolNames: offeredTools))

        guard case .calls(let calls) = outcome else {
            return XCTFail("expected a call, got \(outcome)")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.serverID, nil)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.arguments, "{\"path\":\"a.txt\"}")
    }

    /// A reply branch becomes the displayed answer text — the envelope JSON
    /// itself never reaches the transcript.
    func testUnwrapReplyBranchBecomesDisplayedText() throws {
        let outcome = try XCTUnwrap(ToolTurnEnvelope.unwrap(
            text: "{\"reply\": \"The sky looks blue today.\"}",
            toolNames: offeredTools))

        XCTAssertEqual(outcome, .reply("The sky looks blue today."))
    }

    /// Anything that is not a recognized envelope unwraps to nil: prose
    /// (the expected shape for named-family templates whose own grammar
    /// wins over the schema), an unoffered tool name, whitespace, empty
    /// text. The caller displays nil outcomes untouched and never invents
    /// a call.
    func testUnwrapReturnsNilForNonEnvelopes() {
        XCTAssertNil(ToolTurnEnvelope.unwrap(text: "I will just answer in prose.",
                                             toolNames: offeredTools))
        XCTAssertNil(ToolTurnEnvelope.unwrap(
            text: "{\"name\": \"rm_rf_everything\", \"arguments\": {}}",
            toolNames: offeredTools))
        XCTAssertNil(ToolTurnEnvelope.unwrap(text: "   \n\t ", toolNames: offeredTools))
        XCTAssertNil(ToolTurnEnvelope.unwrap(text: "", toolNames: offeredTools))
        XCTAssertNil(ToolTurnEnvelope.unwrap(text: "[1, 2, 3]", toolNames: offeredTools))
    }
}

// MARK: - Generated registration (port from XCTest)
extension ToolTurnEnvelopeTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ToolTurnEnvelopeTests",
        instance: { ToolTurnEnvelopeTests() },
        checks: [
            .init(name: "testEnvelopeCarriesOneBranchPerToolPlusReply") { try $0.testEnvelopeCarriesOneBranchPerToolPlusReply() },
            .init(name: "testEnvelopeRequiresOfferedTools") { $0.testEnvelopeRequiresOfferedTools() },
            .init(name: "testConstraintGates") { $0.testConstraintGates() },
            .init(name: "testUnwrapNameBranchBecomesAPendingCall") { try $0.testUnwrapNameBranchBecomesAPendingCall() },
            .init(name: "testUnwrapReplyBranchBecomesDisplayedText") { try $0.testUnwrapReplyBranchBecomesDisplayedText() },
            .init(name: "testUnwrapReturnsNilForNonEnvelopes") { $0.testUnwrapReturnsNilForNonEnvelopes() },
        ]
    )
}
