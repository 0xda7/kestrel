// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import os

/// How burned-in subtitles look. Sizes are fractions of the frame height so one
/// setting reads the same on a 720p clip and a 4K one.
struct SubtitleStyle: Codable, Equatable {
    enum Background: String, Codable, CaseIterable, Identifiable, Hashable {
        case box, outline, none
        var id: String { rawValue }
    }

    enum Position: String, Codable, CaseIterable, Identifiable, Hashable {
        case bottom, top
        var id: String { rawValue }
    }

    var fontName = "Helvetica-Bold"
    var relativeSize = 0.038
    var textColor = RGBA(r: 1, g: 1, b: 1, a: 1)
    var background = Background.box
    var backgroundOpacity = 0.72
    var position = Position.bottom
    /// Fraction of the frame height between the text and its edge.
    var margin = 0.06
    /// Fraction of the frame width the text may occupy.
    var maxWidth = 0.86
    /// Floor for the shrink-to-fit, also a fraction of the height: an absolute
    /// point size would mean something different on a still than on the video.
    var minRelativeSize = 0.012

    static let `default` = SubtitleStyle()

    struct RGBA: Codable, Equatable {
        var r, g, b, a: Double
        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

        init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(_ color: Color) {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
            self.init(r: ns.redComponent, g: ns.greenComponent,
                      b: ns.blueComponent, a: ns.alphaComponent)
        }
    }

    // MARK: persistence

    /// Census W8 SubtitleStyle:56 (T2-3 chunk C): an undecodable saved style
    /// used to reset to the default silently. The fallback stays — the style
    /// sheet needs a usable style either way — but the reset is surfaced: the
    /// returned notice is non-nil exactly when a payload existed and could
    /// not be decoded, and load() logs it. Absent data (first launch, nothing
    /// saved yet) is not a failure and stays quiet. Pure so checks can pin
    /// the distinction (D3).
    static func style(from data: Data?) -> (style: SubtitleStyle, unreadable: String?) {
        guard let data else { return (.default, nil) }
        do {
            return (try JSONDecoder().decode(SubtitleStyle.self, from: data), nil)
        } catch {
            return (.default, "Saved subtitle style unreadable; using the default style: \(error.localizedDescription)")
        }
    }

    static func load() -> SubtitleStyle {
        let (style, unreadable) = style(from: UserDefaults.standard.data(forKey: SettingsKeys.subtitleStyle))
        if let unreadable {
            AppLog.app.warning("\(unreadable, privacy: .public)")
        }
        return style
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: SettingsKeys.subtitleStyle)
        } catch {
            // Census W8 SubtitleStyle:63 (T2-3 chunk C): a failed encode used
            // to skip the save silently. Encoding this plain Codable structure
            // effectively cannot fail, but if it ever does, the skip is loud.
            AppLog.app.error("could not encode the subtitle style: \(error.localizedDescription) — the change will not persist")
        }
    }

    /// Faces that ship with macOS and read well over moving pictures.
    static let fontChoices: [(name: String, label: String)] = [
        ("Helvetica-Bold", "Helvetica Bold"),
        ("HelveticaNeue-Medium", "Helvetica Neue"),
        ("Avenir-Heavy", "Avenir Heavy"),
        ("ArialRoundedMTBold", "Arial Rounded"),
        ("Georgia-Bold", "Georgia Bold"),
        ("Menlo-Bold", "Menlo Bold"),
    ]
}
