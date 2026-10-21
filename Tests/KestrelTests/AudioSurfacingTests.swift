// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-3 chunk B: the census §2.8.3 Audio-group silent catches are
/// surfaced. Pinned here: an SRT read failure no longer reads as the
/// "no speech" verdict (AudioStudioController:482), the JSON export is typed
/// (AudioStudioController:364), an unreadable recording surfaces on the
/// recorder's error channel (AudioRecorder:67), dictation response/output
/// parse failures surface (SpeechDictation:408/:436/:439), and
/// WhisperTranscript distinguishes parsed from unparseable (WhisperModel:59).
final class AudioSurfacingTests: CheckCase {
    // MARK: - AudioStudioController:482 — IO read failure vs no-speech verdict

    /// A genuinely missing SRT (real Foundation read failure) must produce
    /// the read-failure message, never the upstream no-speech verdict.
    func testUnreadableSRTSurfacesTheReadFailureNotNoSpeech() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kestrel-check-\(UUID().uuidString).srt")
        let read = Result<String, Error> { try String(contentsOf: missing, encoding: .utf8) }
        guard case .failure = read else {
            return XCTFail("a missing SRT must be a read failure")
        }
        let message = try XCTUnwrap(
            AudioStudioController.transcriptionFailure(read: read, parsedCues: []),
            "a read failure must produce a failure message")
        XCTAssertTrue(message.contains("could not be read"),
                      "the message must name the read failure: \(message)")
        XCTAssertFalse(message.contains("no speech"),
                       "an IO failure must never read as the no-speech verdict: \(message)")
    }

    /// An empty-but-readable transcript keeps the existing bilingual
    /// no-speech verdict, exactly as before the conversion.
    func testEmptyButReadableSRTKeepsTheNoSpeechVerdict() {
        XCTAssertEqual(AudioStudioController.transcriptionFailure(read: .success(""), parsedCues: []),
                       "No se detectó voz / no speech was detected.",
                       "the bilingual no-speech verdict is preserved exactly for an empty parse")
    }

    func testReadableCuesProduceNoFailure() {
        let raw = "1\n00:00:01,250 --> 00:00:03,500\nPrimera línea\n"
        let parsed = SubtitleCue.parseSRT(raw)
        XCTAssertFalse(parsed.isEmpty, "the planted SRT must parse")
        XCTAssertNil(AudioStudioController.transcriptionFailure(read: .success(raw), parsedCues: parsed),
                     "a healthy transcription must not fail")
    }

    // MARK: - AudioStudioController:364 — typed JSON export

    /// An unserializable segments payload (NaN timing) surfaces on the
    /// controller's error channel instead of producing a silent empty export.
    @MainActor func testUnserializableJSONExportSurfacesOnTheErrorChannel() {
        let studio = AudioStudioController()
        let nanCue = SubtitleCue(id: 1, start: .nan, end: 1, text: "hola")
        let content = studio.exportContent(for: .json, cues: [nanCue])
        XCTAssertEqual(content, "", "an unserializable export must not fabricate content")
        let message = studio.error ?? ""
        XCTAssertTrue(message.contains("could not be exported as JSON"),
                      "the failure must reach the controller's error channel: \(message)")
    }

    @MainActor func testHealthyJSONExportIsByteIdentical() throws {
        let studio = AudioStudioController()
        let cues = [SubtitleCue(id: 1, start: 1.25, end: 3.5, text: "hola mundo")]
        let content = studio.exportContent(for: .json, cues: cues)
        let rows: [[String: Any]] = cues.map {
            ["id": $0.id, "start": $0.start, "end": $0.end, "text": $0.text]
        }
        let expected = String(
            decoding: try JSONSerialization.data(withJSONObject: ["segments": rows],
                                                 options: [.prettyPrinted, .sortedKeys]),
            as: UTF8.self) + "\n"
        XCTAssertEqual(content, expected, "the happy-path JSON export is unchanged")
        XCTAssertNil(studio.error, "a healthy export must not raise the error channel")
    }

    // MARK: - AudioRecorder:67 — unreadable WAV surfaces, readable WAV attaches

    @MainActor func testRecorderStopWithUnreadableWAVSurfacesTheErrorAndReturnsNil() {
        let recorder = AudioRecorderController()
        recorder.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kestrel-check-\(UUID().uuidString).wav")
        XCTAssertNil(recorder.stop(), "an unreadable recording must not fabricate an attachment")
        let message = recorder.error ?? ""
        XCTAssertTrue(message.contains("could not be read back"),
                      "the recorder must surface the read failure: \(message)")
    }

    @MainActor func testRecorderStopWithReadableWAVStillAttaches() throws {
        let recorder = AudioRecorderController()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kestrel-check-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        recorder.outputURL = url
        let attachment = try XCTUnwrap(recorder.stop(), "a readable recording still attaches")
        XCTAssertTrue(attachment.dataURI?.hasPrefix("data:audio/wav;base64,") == true,
                      "the attachment rides the same data-URI channel as before")
        XCTAssertEqual(attachment.byteCount, 4)
        XCTAssertNil(recorder.error, "a readable recording must not raise the error channel")
    }

    // MARK: - SpeechDictation:408 — persistent-server response parse

    func testUnparseableServerResponseIsAFailureNotAnEmptyTranscript() {
        for payload in [Data("not json {".utf8), Data("[1, 2]".utf8)] {
            let result = SpeechDictationController.serverTranscript(data: payload, timestamped: false)
            guard case .failure = result else {
                return XCTFail("an unparseable server response must fail, not read as \"\"")
            }
        }
        let timestamped = SpeechDictationController.serverTranscript(data: Data("not json {".utf8),
                                                                     timestamped: true)
        guard case .failure = timestamped else {
            return XCTFail("an unparseable timestamped response must fail, not read as \"\"")
        }
    }

    func testHealthyServerResponseStillParses() {
        let plain = SpeechDictationController.serverTranscript(
            data: Data(#"{"text": " Hola mundo. "}"#.utf8), timestamped: false)
        guard case .success(let text) = plain else {
            return XCTFail("a healthy plain response must parse")
        }
        XCTAssertEqual(text, " Hola mundo. ")
        let segments = SpeechDictationController.serverTranscript(
            data: Data(#"{"segments":[{"start":62.5,"text":" Hola desde la GPU. "}]}"#.utf8),
            timestamped: true)
        guard case .success(let timestamped) = segments else {
            return XCTFail("a healthy segments response must parse")
        }
        XCTAssertEqual(timestamped, "[00:01:02] Hola desde la GPU.")
    }

    // MARK: - SpeechDictation:436/:439 — transcript output file read

    func testUnreadableTranscriptOutputFileIsAFailureNotAnEmptyTranscript() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kestrel-check-\(UUID().uuidString).txt")
        guard case .failure = SpeechDictationController.transcriptOutput(url: missing, timestamped: false) else {
            return XCTFail("a missing output file must fail, not read as \"\"")
        }
        let garbageJSON = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kestrel-check-\(UUID().uuidString).json")
        try Data("not json {".utf8).write(to: garbageJSON)
        defer { try? FileManager.default.removeItem(at: garbageJSON) }
        guard case .failure(let error) = SpeechDictationController.transcriptOutput(url: garbageJSON,
                                                                                    timestamped: true) else {
            return XCTFail("an unparseable output file must fail, not read as \"\"")
        }
        XCTAssertTrue(error.localizedDescription.contains("not a readable transcript payload"),
                      "the typed parse error must carry the English reason: \(error.localizedDescription)")
    }

    func testReadableTranscriptOutputFileStillParses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kestrel-check-\(UUID().uuidString).txt")
        try "Hola mundo.".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let raw) = SpeechDictationController.transcriptOutput(url: url, timestamped: false) else {
            return XCTFail("a readable output file must parse")
        }
        XCTAssertEqual(raw, "Hola mundo.")
    }

    // MARK: - WhisperModel:59 — parsed vs unparseable timestamped payload

    /// Garbage, a non-object root, and a payload with neither "segments" nor
    /// "transcription" are all typed failures — never a silent nil.
    func testTimestampedParseThrowsTypedErrorOnUnparseablePayloads() {
        let payloads = [Data("garbage".utf8), Data("[1, 2]".utf8), Data(#"{"other": 1}"#.utf8)]
        for payload in payloads {
            XCTAssertThrowsError(try WhisperTranscript.parsedTimestamped(jsonData: payload),
                                 "an unparseable payload must throw, not silently nil") { error in
                guard error is WhisperTranscript.ParseError else {
                    return XCTFail("the failure must be typed: \(error)")
                }
            }
        }
    }

    func testTimestampedOutputIsIdenticalForParseablePayloads() throws {
        let segments = #"{"segments":[{"start":62.5,"text":" Hola desde la GPU. "}]}"#
        XCTAssertEqual(try WhisperTranscript.parsedTimestamped(jsonData: Data(segments.utf8)),
                       "[00:01:02] Hola desde la GPU.")
        let transcription = #"{"transcription":[{"timestamps":{"from":"00:01:02,500"},"text":" Hola mundo. "}]}"#
        XCTAssertEqual(try WhisperTranscript.parsedTimestamped(jsonData: Data(transcription.utf8)),
                       "[00:01:02] Hola mundo.")
        // The optional form keeps its contract: nil only for unparseable.
        XCTAssertNil(WhisperTranscript.timestamped(jsonData: Data("garbage".utf8)),
                     "the optional form still maps unparseable payloads to nil")
        XCTAssertEqual(WhisperTranscript.timestamped(jsonData: Data(segments.utf8)),
                       "[00:01:02] Hola desde la GPU.")
    }
}

// MARK: - Generated registration (port from XCTest)
extension AudioSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "AudioSurfacingTests",
        instance: { AudioSurfacingTests() },
        checks: [
            .init(name: "testUnreadableSRTSurfacesTheReadFailureNotNoSpeech") { try $0.testUnreadableSRTSurfacesTheReadFailureNotNoSpeech() },
            .init(name: "testEmptyButReadableSRTKeepsTheNoSpeechVerdict") { $0.testEmptyButReadableSRTKeepsTheNoSpeechVerdict() },
            .init(name: "testReadableCuesProduceNoFailure") { $0.testReadableCuesProduceNoFailure() },
            .init(name: "testUnserializableJSONExportSurfacesOnTheErrorChannel") { $0.testUnserializableJSONExportSurfacesOnTheErrorChannel() },
            .init(name: "testHealthyJSONExportIsByteIdentical") { try $0.testHealthyJSONExportIsByteIdentical() },
            .init(name: "testRecorderStopWithUnreadableWAVSurfacesTheErrorAndReturnsNil") { $0.testRecorderStopWithUnreadableWAVSurfacesTheErrorAndReturnsNil() },
            .init(name: "testRecorderStopWithReadableWAVStillAttaches") { try $0.testRecorderStopWithReadableWAVStillAttaches() },
            .init(name: "testUnparseableServerResponseIsAFailureNotAnEmptyTranscript") { $0.testUnparseableServerResponseIsAFailureNotAnEmptyTranscript() },
            .init(name: "testHealthyServerResponseStillParses") { $0.testHealthyServerResponseStillParses() },
            .init(name: "testUnreadableTranscriptOutputFileIsAFailureNotAnEmptyTranscript") { try $0.testUnreadableTranscriptOutputFileIsAFailureNotAnEmptyTranscript() },
            .init(name: "testReadableTranscriptOutputFileStillParses") { try $0.testReadableTranscriptOutputFileStillParses() },
            .init(name: "testTimestampedParseThrowsTypedErrorOnUnparseablePayloads") { $0.testTimestampedParseThrowsTypedErrorOnUnparseablePayloads() },
            .init(name: "testTimestampedOutputIsIdenticalForParseablePayloads") { try $0.testTimestampedOutputIsIdenticalForParseablePayloads() },
        ])
}
