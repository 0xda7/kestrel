// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

final class InlineMathDetectionTests: CheckCase {
    func testProseWithShellVariablesIsNotMath() {
        for prose in [
            "Set $HOME and then export $PATH before running the script.",
            "Run `$ pip install openai` and then `$ python demo.py` to try it.",
            "La variable $HOME identifica el directorio raiz, mientras que $PATH garantiza el resto.",
            "Use awk '{print $1}' on the log, then check $? for errors.",
            "Regex: match a literal paren with \\( and close it with \\) in POSIX.",
            "Exporta $PORT=$PORT2 antes de arrancar.",
        ] {
            XCTAssertFalse(RichText.containsInlineMath(prose), prose)
        }
    }

    func testPricesAreNotMath() {
        XCTAssertFalse(RichText.containsInlineMath("El coste pasa de $10 a $25 por millon de tokens."))
        XCTAssertFalse(RichText.containsInlineMath("Cuesta entre $10-$25 al mes."))
    }

    func testFormulasAreStillDetected() {
        for formula in [
            "The area is $A = \\pi r^2$ for a circle.",
            "Con $x_1$ y $x_2$ se resuelve la ecuacion.",
            "La complejidad es $O(n^2)$ en el peor caso.",
            "Escrito como \\(e^{i\\pi} + 1 = 0\\), la identidad de Euler.",
            "Sea $n$ el numero de capas.",
        ] {
            XCTAssertTrue(RichText.containsInlineMath(formula), formula)
        }
    }

    func testUnpairedDelimiterIsNotMath() {
        XCTAssertFalse(RichText.containsInlineMath("Revisa $LOG_FILE antes de continuar."))
    }

    func testSpanDoesNotCrossLines() {
        XCTAssertFalse(RichText.containsInlineMath("Primero $HOME\ny luego $PATH del sistema."))
    }
}

// MARK: - Generated registration (port from XCTest)
extension InlineMathDetectionTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "InlineMathDetectionTests",
        instance: { InlineMathDetectionTests() },
        checks: [
            .init(name: "testProseWithShellVariablesIsNotMath") { $0.testProseWithShellVariablesIsNotMath() },
            .init(name: "testPricesAreNotMath") { $0.testPricesAreNotMath() },
            .init(name: "testFormulasAreStillDetected") { $0.testFormulasAreStillDetected() },
            .init(name: "testUnpairedDelimiterIsNotMath") { $0.testUnpairedDelimiterIsNotMath() },
            .init(name: "testSpanDoesNotCrossLines") { $0.testSpanDoesNotCrossLines() },
        ])
}
