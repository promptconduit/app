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

    func testSuppressAllDetectionBlocksAllStateChanges() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
        }

        // Activate ALL detection suppression (used after hook events)
        monitor.suppressAllDetection(for: 2.0)

        // Try to set waiting state - should be blocked
        monitor.setWaiting(true)

        // Also try to set not waiting - should also be blocked
        monitor.setWaiting(false)

        // No state changes should have occurred
        XCTAssertTrue(stateChanges.isEmpty, "All state changes should be suppressed")
        XCTAssertFalse(monitor.isWaiting, "isWaiting should remain false during suppression")
    }

    func testSuppressAllDetectionExpires() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let callbackExpectation = self.expectation(description: "Callback received")

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            callbackExpectation.fulfill()
        }

        // Activate very short ALL suppression window
        monitor.suppressAllDetection(for: 0.1)

        // Wait for suppression to expire, then set state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            monitor.setWaiting(true)
        }

        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(stateChanges, [true], "Should allow state changes after ALL suppression expires")
    }

    func testSuppressAllTakesPriorityOverWaitingSuppression() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
        }

        // Activate both suppression windows
        monitor.suppressWaitingDetection(for: 2.0)  // Only blocks waiting=true
        monitor.suppressAllDetection(for: 2.0)       // Blocks all changes

        // Try to set not waiting - normally allowed by waiting suppression, but blocked by all suppression
        monitor.setWaiting(false)

        XCTAssertTrue(stateChanges.isEmpty, "suppressAllDetection should block all changes including false")
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

    // MARK: - Hook-Managed Tests

    func testSetHookManagedMarksSessionAsHookManaged() {
        let monitor = TerminalOutputMonitor()

        XCTAssertFalse(monitor.isHookManaged, "Should not be hook-managed initially")

        monitor.setHookManaged()

        XCTAssertTrue(monitor.isHookManaged, "Should be hook-managed after setHookManaged()")
    }

    func testHookManagedSessionIgnoresOutputBasedStateChanges() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
        }

        // Mark as hook-managed
        monitor.setHookManaged()

        // Try to change state via setWaiting (output-based) - should be ignored
        monitor.setWaiting(true)
        monitor.setWaiting(false)
        monitor.setWaiting(true)

        XCTAssertTrue(stateChanges.isEmpty, "Hook-managed session should ignore output-based state changes")
        XCTAssertFalse(monitor.isWaiting, "isWaiting should remain unchanged")
    }

    func testForceSetWaitingWorksOnHookManagedSession() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let expectation = self.expectation(description: "Callback received")

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            expectation.fulfill()
        }

        // Mark as hook-managed
        monitor.setHookManaged()

        // Force set state (hook-based) - should work
        monitor.forceSetWaiting(true)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(stateChanges, [true], "forceSetWaiting should work on hook-managed session")
        XCTAssertTrue(monitor.isWaiting)
    }

    func testForceSetWaitingStateTransitions() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let expectation = self.expectation(description: "Callbacks received")
        expectation.expectedFulfillmentCount = 3

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            expectation.fulfill()
        }

        // Mark as hook-managed
        monitor.setHookManaged()

        // Simulate hook events: SessionStart -> UserPromptSubmit -> Stop
        monitor.forceSetWaiting(true)   // SessionStart: waiting
        monitor.forceSetWaiting(false)  // UserPromptSubmit: running
        monitor.forceSetWaiting(true)   // Stop: waiting again

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(stateChanges, [true, false, true], "Should track all hook-based state changes")
        XCTAssertTrue(monitor.isWaiting)
    }

    func testForceSetWaitingAlwaysUpdates() {
        let monitor = TerminalOutputMonitor()
        var notifyCount = 0
        let expectation = self.expectation(description: "Callbacks received")
        expectation.expectedFulfillmentCount = 3

        monitor.onWaitingStateChanged = { _ in
            notifyCount += 1
            expectation.fulfill()
        }

        monitor.setHookManaged()
        // forceSetWaiting should ALWAYS update since hooks are authoritative
        // This ensures state is properly synced even if lastNotifiedState is out of sync
        monitor.forceSetWaiting(true)
        monitor.forceSetWaiting(true)  // Still updates - hooks are authoritative
        monitor.forceSetWaiting(true)  // Still updates - hooks are authoritative

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(notifyCount, 3, "forceSetWaiting should always update since hooks are authoritative")
    }

    func testHookManagedSessionIgnoresProcessOutput() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
        }

        // Mark as hook-managed
        monitor.setHookManaged()

        // Process output with waiting pattern - should be ignored
        monitor.processOutput("Some output\n❯ ")

        // Wait for potential debounce
        let expectation = self.expectation(description: "Debounce completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(stateChanges.isEmpty, "Hook-managed session should ignore output-based detection")
        XCTAssertFalse(monitor.isWaiting)
    }

    func testMixedHookAndOutputBasedUpdates() {
        let monitor = TerminalOutputMonitor()
        var stateChanges: [Bool] = []
        let expectation = self.expectation(description: "Callbacks received")
        expectation.expectedFulfillmentCount = 2

        monitor.onWaitingStateChanged = { isWaiting in
            stateChanges.append(isWaiting)
            expectation.fulfill()
        }

        // Mark as hook-managed and set initial state
        monitor.setHookManaged()
        monitor.forceSetWaiting(true)  // Hook: waiting

        // Try output-based change - should be ignored
        monitor.setWaiting(false)

        // Hook-based change - should work
        monitor.forceSetWaiting(false)  // Hook: running

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(stateChanges, [true, false], "Only hook-based changes should be applied")
    }
}
