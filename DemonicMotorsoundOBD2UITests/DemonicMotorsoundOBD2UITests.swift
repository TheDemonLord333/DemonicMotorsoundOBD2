//
//  DemonicMotorsoundOBD2UITests.swift
//  DemonicMotorsoundOBD2UITests
//

import XCTest

final class DemonicMotorsoundOBD2UITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Startet die App, aktiviert den Demomodus und prüft die dauerhafte Kennzeichnung.
    @MainActor
    func testDemoModeIsClearlyLabelled() throws {
        let app = XCUIApplication()
        app.launch()

        let tryDemo = app.buttons["Demomodus ausprobieren"]
        if tryDemo.waitForExistence(timeout: 3) {
            tryDemo.tap()
        } else {
            app.tabBars.buttons["Verbindung"].tap()
            let toggle = app.switches["Demomodus (ohne Adapter)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            if (toggle.value as? String) != "1" { toggle.tap() }
            app.tabBars.buttons["Cockpit"].tap()
        }

        XCTAssertTrue(app.staticTexts["DEMOMODUS"].waitForExistence(timeout: 3) || app.otherElements["Demomodus aktiv, simulierte Daten"].exists)
        XCTAssertTrue(app.buttons["Motor starten"].waitForExistence(timeout: 3))
        app.buttons["Motor starten"].tap()
        XCTAssertTrue(app.buttons["Motor aus"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAllMainAreasReachable() throws {
        let app = XCUIApplication()
        app.launch()
        let later = app.buttons["Adapter verbinden"]
        if later.waitForExistence(timeout: 3) { later.tap() }
        for tab in ["Cockpit", "Sounds", "Verbindung", "Einstellungen"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 3), tab)
            button.tap()
        }
        app.buttons["Anleitung"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Anleitung"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
