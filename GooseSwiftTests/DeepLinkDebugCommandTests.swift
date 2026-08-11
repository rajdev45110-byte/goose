import Foundation
import XCTest

@testable import GooseSwift

/// F8: a `gooseswift://debug-command` link must never reach the strap without
/// explicit user approval.
///
/// "Zero writes" is asserted through `ble.debugCommandStatus`. Every early-exit
/// path inside `sendDebugResearchCommand` mutates that string before returning,
/// so an unchanged value proves the send was never attempted — as opposed to
/// attempted-and-blocked, which would leave a "blocked"/"needs" message.
@MainActor
final class DeepLinkDebugCommandTests: XCTestCase {
  private var model: GooseAppModel!
  private var initialStatus: String!

  override func setUp() {
    super.setUp()
    model = GooseAppModel(startBLE: false)
    initialStatus = model.ble.debugCommandStatus
  }

  override func tearDown() {
    model = nil
    initialStatus = nil
    super.tearDown()
  }

  private func url(_ string: String) -> URL {
    URL(string: string)!
  }

  private func assertNoWriteAttempted(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(
      model.ble.debugCommandStatus,
      initialStatus,
      message,
      file: file,
      line: line
    )
  }

  /// A known command stages a confirmation and writes nothing.
  func testValidDeepLinkStagesConfirmationAndSendsNothing() {
    let known = model.ble.debugResearchCommands.first!
    let handled = model.handleDebugCommandDeepLink(url("gooseswift://debug-command/\(known.id)"))

    XCTAssertTrue(handled, "the deep link must be consumed by Goose")
    XCTAssertNotNil(model.pendingDeepLinkDebugCommand, "a confirmation must be staged")
    XCTAssertEqual(model.pendingDeepLinkDebugCommand?.commandID, known.id)
    XCTAssertEqual(model.pendingDeepLinkDebugCommand?.risk, known.risk, "risk must be surfaced to the user")
    assertNoWriteAttempted("no BLE write may be attempted before confirmation")
  }

  /// Payload from the link is carried into the confirmation, still unsent.
  func testDeepLinkPayloadIsStagedNotSent() {
    let known = model.ble.debugResearchCommands.first!
    _ = model.handleDebugCommandDeepLink(url("gooseswift://debug-command/\(known.id)?payload=00ff"))

    XCTAssertEqual(model.pendingDeepLinkDebugCommand?.payloadHex, "00ff")
    XCTAssertEqual(model.pendingDeepLinkDebugCommand?.payloadSummary, "00ff")
    assertNoWriteAttempted("payload links must not send either")
  }

  /// Cancelling clears the staged command and writes nothing.
  func testCancelSendsNothing() {
    let known = model.ble.debugResearchCommands.first!
    _ = model.handleDebugCommandDeepLink(url("gooseswift://debug-command/\(known.id)"))
    XCTAssertNotNil(model.pendingDeepLinkDebugCommand)

    model.cancelPendingDeepLinkDebugCommand()

    XCTAssertNil(model.pendingDeepLinkDebugCommand, "cancel must clear the staged command")
    assertNoWriteAttempted("cancel must not send")
  }

  /// Dismissing (equivalent to cancel via the alert binding) writes nothing.
  func testDismissWithoutConfirmingSendsNothing() {
    let known = model.ble.debugResearchCommands.first!
    _ = model.handleDebugCommandDeepLink(url("gooseswift://debug-command/\(known.id)"))

    // The alert's `isPresented` setter routes dismissal to cancel.
    model.cancelPendingDeepLinkDebugCommand()
    model.cancelPendingDeepLinkDebugCommand()  // idempotent

    XCTAssertNil(model.pendingDeepLinkDebugCommand)
    assertNoWriteAttempted("dismissal must not send")
  }

  /// An unknown command id stages nothing and writes nothing.
  func testUnknownCommandStagesNothing() {
    let handled = model.handleDebugCommandDeepLink(url("gooseswift://debug-command/not_a_real_command"))

    XCTAssertTrue(handled, "the link is still consumed so it cannot fall through elsewhere")
    XCTAssertNil(model.pendingDeepLinkDebugCommand, "unknown commands must not stage a confirmation")
    assertNoWriteAttempted("unknown commands must not send")
  }

  /// A link with no command id stages nothing and writes nothing.
  func testMalformedDeepLinkStagesNothing() {
    let handled = model.handleDebugCommandDeepLink(url("gooseswift://debug-command"))

    XCTAssertTrue(handled)
    XCTAssertNil(model.pendingDeepLinkDebugCommand)
    assertNoWriteAttempted("malformed links must not send")
  }

  /// Non-debug-command URLs are not handled here at all.
  func testUnrelatedURLIsNotHandled() {
    XCTAssertFalse(model.handleDebugCommandDeepLink(url("gooseswift://health")))
    XCTAssertFalse(model.handleDebugCommandDeepLink(url("https://example.com/debug-command/x")))
    XCTAssertNil(model.pendingDeepLinkDebugCommand)
    assertNoWriteAttempted("unrelated URLs must not send")
  }

  /// Confirming clears the staged command and takes the send path exactly once.
  /// With no connected strap the send is refused downstream, which is observable
  /// as a changed status — proving confirmation is the only route to a write.
  func testConfirmTakesSendPathExactlyOnce() {
    let known = model.ble.debugResearchCommands.first!
    _ = model.handleDebugCommandDeepLink(url("gooseswift://debug-command/\(known.id)"))
    assertNoWriteAttempted("precondition: nothing attempted while staged")

    model.confirmPendingDeepLinkDebugCommand()

    XCTAssertNil(model.pendingDeepLinkDebugCommand, "confirm must clear the staged command")
    XCTAssertNotEqual(
      model.ble.debugCommandStatus,
      initialStatus,
      "confirm must reach sendDebugResearchCommand"
    )

    // A second confirm is a no-op: there is nothing staged.
    let afterFirst = model.ble.debugCommandStatus
    model.confirmPendingDeepLinkDebugCommand()
    XCTAssertEqual(model.ble.debugCommandStatus, afterFirst, "confirm must not replay")
  }
}
