//
//  TubCompanionUITests.swift
//  TubCompanionUITests
//
//  Created by Sebastian Suarez-Solis on 3/31/26.
//

import XCTest

final class TubCompanionUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testCableDisconnectedShowsBlockingOverlay() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["Play into the tub"].waitForExistence(timeout: 8))
        app.buttons["Play into the tub"].tap()

        XCTAssertTrue(app.buttons["Enter live mode"].waitForExistence(timeout: 8))
        app.buttons["Enter live mode"].tap()

        XCTAssertTrue(app.staticTexts["CONNECT USB-C CABLE"].waitForExistence(timeout: 8))
        XCTAssertFalse(deckElement(in: app, id: "play.capture.holdButton").exists)
    }

    @MainActor
    func testArmedPadHoldRecordPathInPortrait() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES", "-DEBUG_FAKE_CABLE", "YES"]
        app.launch()

        XCUIDevice.shared.orientation = .portrait

        let playTab = shellTabButton(in: app, tab: "play")
        XCTAssertTrue(playTab.waitForExistence(timeout: 8))
        playTab.tap()

        let holdButton = firstHittableElement(
            in: app.buttons.matching(identifier: "play.capture.holdButton"),
            timeout: 8
        )
        XCTAssertTrue(holdButton.exists)
        holdButton.press(forDuration: 0.7)

        XCTAssertTrue(waitForAnyLabelContaining(["Committing", "Playing", "COMMITTING", "PLAYING"], in: app, timeout: 8))
    }

    @MainActor
    func testSynthTapAndTransportRemainAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES", "-DEBUG_FAKE_CABLE", "YES"]
        app.launch()

        let playTab = shellTabButton(in: app, tab: "play")
        XCTAssertTrue(playTab.waitForExistence(timeout: 8))
        playTab.tap()

        let firstSynthPad = deckElement(in: app, id: "play.synth.note.48")
        scrollUntilVisible(firstSynthPad, in: app)
        XCTAssertTrue(firstSynthPad.waitForExistence(timeout: 8))
        firstSynthPad.tap()

        let quantizeControl = deckElement(in: app, id: "play.transport.quantize")
        scrollUntilVisible(quantizeControl, in: app)
        if quantizeControl.exists {
            XCTAssertTrue(quantizeControl.waitForExistence(timeout: 8))
            return
        }

        let stopButton = deckElement(in: app, id: "play.transport.stop")
        scrollUntilVisible(stopButton, in: app)
        XCTAssertTrue(stopButton.waitForExistence(timeout: 8))
        XCTAssertTrue(stopButton.isHittable)
    }

    @MainActor
    func testSynthPressDoesNotBlockVerticalScroll() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES", "-DEBUG_FAKE_CABLE", "YES"]
        app.launch()

        let playTab = shellTabButton(in: app, tab: "play")
        XCTAssertTrue(playTab.waitForExistence(timeout: 8))
        playTab.tap()

        let synthPad = deckElement(in: app, id: "play.synth.note.48")
        scrollUntilVisible(synthPad, in: app)
        XCTAssertTrue(synthPad.waitForExistence(timeout: 8))
        synthPad.press(forDuration: 0.35)

        app.swipeUp()
        let stopButton = deckElement(in: app, id: "play.transport.stop")
        XCTAssertTrue(stopButton.waitForExistence(timeout: 8))
    }

    @MainActor
    func testAccessibilityHooksExistForCoreControls() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES", "-DEBUG_FAKE_CABLE", "YES"]
        app.launch()

        let playTab = shellTabButton(in: app, tab: "play")
        XCTAssertTrue(playTab.waitForExistence(timeout: 8))
        playTab.tap()

        XCTAssertTrue(deckElement(in: app, id: "play.capture.holdButton").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "play.capture.state").waitForExistence(timeout: 8))

        let synthPad = deckElement(in: app, id: "play.synth.note.48")
        scrollUntilVisible(synthPad, in: app)
        XCTAssertTrue(synthPad.exists)

        let stopButton = deckElement(in: app, id: "play.transport.stop")
        scrollUntilVisible(stopButton, in: app)
        XCTAssertTrue(stopButton.exists)
    }

    @MainActor
    func testLearnOpensInRitualChapterOne() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES"]
        app.launch()

        let learnTab = shellTabButton(in: app, tab: "learn")
        XCTAssertTrue(learnTab.waitForExistence(timeout: 8))
        learnTab.tap()

        XCTAssertTrue(deckElement(in: app, id: "learn.mode.ritual").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "learn.ritual.chapter.title").waitForExistence(timeout: 8))
        XCTAssertEqual(deckElement(in: app, id: "learn.ritual.chapter.title").label, "ENTER")
    }

    @MainActor
    func testLearnJumpPlaySwitchesTabAndRestoresChapter() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES", "-DEBUG_FAKE_CABLE", "YES"]
        app.launch()

        let learnTab = shellTabButton(in: app, tab: "learn")
        XCTAssertTrue(learnTab.waitForExistence(timeout: 8))
        learnTab.tap()

        let nextButton = deckElement(in: app, id: "learn.command.next")
        XCTAssertTrue(nextButton.waitForExistence(timeout: 8))
        nextButton.tap()

        let chapterTitle = deckElement(in: app, id: "learn.ritual.chapter.title")
        XCTAssertTrue(chapterTitle.waitForExistence(timeout: 8))
        XCTAssertEqual(chapterTitle.label, "TOUCH")

        let jumpPlay = deckElement(in: app, id: "learn.command.jumpPlay")
        XCTAssertTrue(jumpPlay.waitForExistence(timeout: 8))
        jumpPlay.tap()

        let playTab = shellTabButton(in: app, tab: "play")
        XCTAssertTrue(playTab.waitForExistence(timeout: 8))
        XCTAssertTrue(playTab.isSelected)

        learnTab.tap()
        let restoredTitle = deckElement(in: app, id: "learn.ritual.chapter.title")
        XCTAssertTrue(restoredTitle.waitForExistence(timeout: 8))
        XCTAssertEqual(restoredTitle.label, "TOUCH")
    }

    @MainActor
    func testLearnSkipToAtlasAndAnchorNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES"]
        app.launch()

        let learnTab = shellTabButton(in: app, tab: "learn")
        XCTAssertTrue(learnTab.waitForExistence(timeout: 8))
        learnTab.tap()

        let skipToAtlas = deckElement(in: app, id: "learn.command.skipAtlas")
        XCTAssertTrue(skipToAtlas.waitForExistence(timeout: 8))
        skipToAtlas.tap()

        XCTAssertTrue(deckElement(in: app, id: "learn.atlas.deck").waitForExistence(timeout: 8))

        let queueAnchor = deckElement(in: app, id: "learn.atlas.anchor.queue-claims")
        XCTAssertTrue(queueAnchor.waitForExistence(timeout: 8))
        queueAnchor.tap()

        let queueSection = deckElement(in: app, id: "learn.atlas.section.queue-claims")
        XCTAssertTrue(queueSection.waitForExistence(timeout: 8))
    }

    @MainActor
    func testLearnTapTargetsRemainHittableWithLargeType() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-DEBUG_RESET_APP_STATE",
            "YES",
            "-DEBUG_SKIP_ENTRY_GATE",
            "YES",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryXXXL"
        ]
        app.launch()

        let learnTab = shellTabButton(in: app, tab: "learn")
        XCTAssertTrue(learnTab.waitForExistence(timeout: 8))
        learnTab.tap()

        let nextButton = deckElement(in: app, id: "learn.command.next")
        XCTAssertTrue(nextButton.waitForExistence(timeout: 8))
        XCTAssertTrue(nextButton.isHittable)

        let jumpSteer = deckElement(in: app, id: "learn.command.jumpSteer")
        XCTAssertTrue(jumpSteer.waitForExistence(timeout: 8))
        XCTAssertTrue(jumpSteer.isHittable)
    }

    @MainActor
    func testSteerTabShowsCoreControls() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-DEBUG_RESET_APP_STATE",
            "YES",
            "-DEBUG_SKIP_ENTRY_GATE",
            "YES",
            "-DEBUG_ALLOW_STEER_WITHOUT_LINK",
            "YES",
            "-DEBUG_BYPASS_STEER_LOCK",
            "YES"
        ]
        app.launch()

        let steerTab = shellTabButton(in: app, tab: "steer")
        XCTAssertTrue(steerTab.waitForExistence(timeout: 8))
        steerTab.tap()

        XCTAssertTrue(deckElement(in: app, id: "steer.root").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "steer.pad").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "steer.button.more").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "steer.button.less").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "steer.button.compare").waitForExistence(timeout: 8))
    }

    @MainActor
    func testSteerCompareModeEntryAndExit() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-DEBUG_RESET_APP_STATE",
            "YES",
            "-DEBUG_SKIP_ENTRY_GATE",
            "YES",
            "-DEBUG_ALLOW_STEER_WITHOUT_LINK",
            "YES",
            "-DEBUG_BYPASS_STEER_LOCK",
            "YES"
        ]
        app.launch()

        let steerTab = shellTabButton(in: app, tab: "steer")
        XCTAssertTrue(steerTab.waitForExistence(timeout: 8))
        steerTab.tap()

        let enterCompare = deckElement(in: app, id: "steer.button.compare")
        XCTAssertTrue(enterCompare.waitForExistence(timeout: 8))
        enterCompare.tap()

        let leftChoice = deckElement(in: app, id: "steer.compare.left")
        XCTAssertTrue(leftChoice.waitForExistence(timeout: 8))
        leftChoice.tap()

        let exitCompare = deckElement(in: app, id: "steer.compare.exit")
        XCTAssertTrue(exitCompare.waitForExistence(timeout: 8))
        exitCompare.tap()

        XCTAssertTrue(deckElement(in: app, id: "steer.button.compare").waitForExistence(timeout: 8))
    }

    @MainActor
    func testSteerDisconnectedShowsHardGate() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "NO"]
        app.launch()

        XCTAssertTrue(app.buttons["Steer the ML"].waitForExistence(timeout: 8))
        app.buttons["Steer the ML"].tap()

        XCTAssertTrue(app.staticTexts["CONNECT LOCALLY"].waitForExistence(timeout: 8))
        XCTAssertFalse(deckElement(in: app, id: "steer.pad").exists)
    }

    @MainActor
    func testSteerConnectedShowsAccessRequiredOverlay() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-DEBUG_RESET_APP_STATE",
            "YES",
            "-DEBUG_SKIP_ENTRY_GATE",
            "YES",
            "-DEBUG_ALLOW_STEER_WITHOUT_LINK",
            "YES"
        ]
        app.launch()

        let steerTab = shellTabButton(in: app, tab: "steer")
        XCTAssertTrue(steerTab.waitForExistence(timeout: 8))
        steerTab.tap()

        XCTAssertTrue(deckElement(in: app, id: "steer.access.overlay").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "steer.access.required.title").waitForExistence(timeout: 8))
        XCTAssertTrue(deckElement(in: app, id: "steer.access.unlock").waitForExistence(timeout: 8))
        XCTAssertFalse(deckElement(in: app, id: "steer.access.match").exists)
    }

    @MainActor
    func testSteerCodeMatchUnlockFlowShowsGrantedAndRevealsPad() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-DEBUG_RESET_APP_STATE",
            "YES",
            "-DEBUG_SKIP_ENTRY_GATE",
            "YES",
            "-DEBUG_ALLOW_STEER_WITHOUT_LINK",
            "YES"
        ]
        app.launch()

        let steerTab = shellTabButton(in: app, tab: "steer")
        XCTAssertTrue(steerTab.waitForExistence(timeout: 8))
        steerTab.tap()

        let unlockButton = deckElement(in: app, id: "steer.access.unlock")
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 8))
        unlockButton.tap()

        let passwordEntry = deckElement(in: app, id: "steer.access.password.entry")
        XCTAssertTrue(passwordEntry.waitForExistence(timeout: 8))
        passwordEntry.tap()
        app.typeText("THETUB")
        deckElement(in: app, id: "steer.access.password.hack").tap()

        let matchButton = deckElement(in: app, id: "steer.access.match")
        XCTAssertTrue(matchButton.waitForExistence(timeout: 8))

        for _ in 0..<3 {
            matchButton.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }

        XCTAssertTrue(deckElement(in: app, id: "steer.access.granted").waitForExistence(timeout: 4))
        XCTAssertTrue(deckElement(in: app, id: "steer.pad").waitForExistence(timeout: 8))
    }

    @MainActor
    func testSteerCodeMatchFailureShowsCooldownThenRetry() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-DEBUG_RESET_APP_STATE",
            "YES",
            "-DEBUG_SKIP_ENTRY_GATE",
            "YES",
            "-DEBUG_ALLOW_STEER_WITHOUT_LINK",
            "YES",
            "-DEBUG_STEER_HACK_FORCE_MISS",
            "YES"
        ]
        app.launch()

        let steerTab = shellTabButton(in: app, tab: "steer")
        XCTAssertTrue(steerTab.waitForExistence(timeout: 8))
        steerTab.tap()

        let unlockButton = deckElement(in: app, id: "steer.access.unlock")
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 8))
        unlockButton.tap()
        let passwordEntry = deckElement(in: app, id: "steer.access.password.entry")
        XCTAssertTrue(passwordEntry.waitForExistence(timeout: 8))
        passwordEntry.tap()
        app.typeText("THETUB")
        deckElement(in: app, id: "steer.access.password.hack").tap()

        let matchButton = deckElement(in: app, id: "steer.access.match")
        XCTAssertTrue(matchButton.waitForExistence(timeout: 8))

        for _ in 0..<3 {
            matchButton.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let retryButton = deckElement(in: app, id: "steer.access.retry")
        XCTAssertTrue(retryButton.waitForExistence(timeout: 6))
        XCTAssertTrue(retryButton.label.contains("LOCKED"))

        let deadline = Date().addingTimeInterval(7.0)
        var becameRetry = false
        while Date() < deadline {
            if retryButton.label == "RETRY" {
                becameRetry = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(becameRetry)
    }

    @MainActor
    func testLearnAccessibilityLabelsExistForCoreActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DEBUG_RESET_APP_STATE", "YES", "-DEBUG_SKIP_ENTRY_GATE", "YES"]
        app.launch()

        let learnTab = shellTabButton(in: app, tab: "learn")
        XCTAssertTrue(learnTab.waitForExistence(timeout: 8))
        learnTab.tap()

        let nextButton = deckElement(in: app, id: "learn.command.next")
        let jumpPlay = deckElement(in: app, id: "learn.command.jumpPlay")
        let skipButton = deckElement(in: app, id: "learn.command.skipAtlas")

        XCTAssertTrue(nextButton.waitForExistence(timeout: 8))
        XCTAssertTrue(jumpPlay.waitForExistence(timeout: 8))
        XCTAssertTrue(skipButton.waitForExistence(timeout: 8))

        XCTAssertFalse(nextButton.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(jumpPlay.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(skipButton.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    private func deckElement(in app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func shellTabButton(in app: XCUIApplication, tab: String) -> XCUIElement {
        deckElement(in: app, id: "shell.nav.button.\(tab)")
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) {
        guard !element.exists else { return }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.exists {
                return
            }
        }
    }

    private func waitForAnyLabelContaining(_ snippets: [String], in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
            if labels.contains(where: { label in snippets.contains(where: { label.contains($0) }) }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func firstHittableElement(in query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement {
        let first = query.firstMatch
        _ = first.waitForExistence(timeout: timeout)

        let count = min(query.count, 8)
        if count > 0 {
            for index in 0..<count {
                let candidate = query.element(boundBy: index)
                if candidate.exists && candidate.isHittable {
                    return candidate
                }
            }
        }
        return first
    }
}
