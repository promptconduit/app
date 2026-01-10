import XCTest
@testable import PromptConduit

final class TerminalOutputMonitorTests: XCTestCase {

    // MARK: - Suppression Window Tests

    func testSuppressionWindowBlocksWaitingState() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
        }

        // Activate suppression window
        monitor.suppressWaitingDetection(for: 2.0)

        // Try to set waiting state - should be blocked
        monitor.setWaiting(true)

        // No state change should have occurred
        XCTAssertTrue(stateChanges.isEmpty, "Waiting state should be suppressed")
        XCTAssertFalse(monitor.isWaiting, "isWaiting should remain false during suppression")
    }

    func testSuppressionWindowAllowsFalseState() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let setupExpectation = self.expectation(description: "Setup complete")
        let changeExpectation = self.expectation(description: "State changed")

        // First set to waiting
        monitor.onWaitingStateChanged = { _ in
            setupExpectation.fulfill()
        }
        monitor.setWaiting(true)
        wait(for: [setupExpectation], timeout: 1.0)

        // Now set up for the actual test
        stateChanges = []
        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            changeExpectation.fulfill()
        }

        // Activate suppression window
        monitor.suppressWaitingDetection(for: 2.0)

        // Setting to false should still work
        monitor.setWaiting(false)

        wait(for: [changeExpectation], timeout: 1.0)
        XCTAssertEqual(stateChanges, [false], "Should allow transition to false even during suppression")
    }

    func testSuppressionWindowExpires() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let callbackExpectation = self.expectation(description: "Callback received")

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            callbackExpectation.fulfill()
        }

        // Activate very short suppression window
        monitor.suppressWaitingDetection(for: 0.1)

        // Wait for suppression to expire, then set state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            monitor.setWaiting(true)
        }

        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(stateChanges, [true], "Should allow waiting state after suppression expires")
    }

    // MARK: - State Change Tests

    func testStateChangeNotifiesCallback() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let expectation = self.expectation(description: "Callbacks received")
        expectation.expectedFulfillmentCount = 3

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            expectation.fulfill()
        }

        monitor.setWaiting(true)
        monitor.setWaiting(false)
        monitor.setWaiting(true)

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(stateChanges, [true, false, true], "Should notify on each state change")
    }

    func testDuplicateStateDoesNotNotify() {
        let monitor = TerminalOutputMonitor()
        var notifyCount = 0
        let expectation = self.expectation(description: "First callback")

        monitor.onWaitingStateChanged = { _ in
            notifyCount += 1
            expectation.fulfill()
        }

        monitor.setWaiting(true)
        monitor.setWaiting(true)  // Duplicate - should be ignored
        monitor.setWaiting(true)  // Duplicate - should be ignored

        wait(for: [expectation], timeout: 1.0)

        // Give time for any potential extra callbacks (which shouldn't happen)
        let delayExpectation = self.expectation(description: "Delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            delayExpectation.fulfill()
        }
        wait(for: [delayExpectation], timeout: 1.0)

        XCTAssertEqual(notifyCount, 1, "Should only notify once for repeated same state")
    }

    // MARK: - Output Processing Tests

    func testProcessOutputTriggersDebounce() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
        }

        // Process output with waiting pattern
        monitor.processOutput("Some output\n❯ ")

        // Should not immediately trigger (debounced)
        XCTAssertTrue(stateChanges.isEmpty, "Should debounce state check")

        // Wait for debounce
        let expectation = self.expectation(description: "Debounce completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0)

        // Now should have detected waiting state
        XCTAssertEqual(stateChanges, [true], "Should detect waiting state after debounce")
    }

    func testResetClearsState() {
        let monitor = TerminalOutputMonitor()

        // Set some state
        monitor.setWaiting(true)
        monitor.processOutput("Some buffered content")

        // Reset
        monitor.reset()

        XCTAssertFalse(monitor.isWaiting, "isWaiting should be false after reset")
    }

    // MARK: - User Input Tests

    func testUserProvidedInputClearsWaiting() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let setupExpectation = self.expectation(description: "Setup complete")
        let changeExpectation = self.expectation(description: "State changed")

        // First set to waiting
        monitor.onWaitingStateChanged = { _ in
            setupExpectation.fulfill()
        }
        monitor.setWaiting(true)
        wait(for: [setupExpectation], timeout: 1.0)

        // Now set up for the actual test
        stateChanges = []
        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            changeExpectation.fulfill()
        }

        monitor.userProvidedInput()

        wait(for: [changeExpectation], timeout: 1.0)
        XCTAssertEqual(stateChanges, [false], "userProvidedInput should set waiting to false")
        XCTAssertFalse(monitor.isWaiting)
    }
}
