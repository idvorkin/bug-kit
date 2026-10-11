import XCTest

@MainActor
final class WhatsNewUITests: XCTestCase {
  func testDismissButtonIsReachableAtItsEdgeInLightAndDarkRows() {
    let app = XCUIApplication()
    for dark in [false, true] {
      app.launchArguments = ["--whats-new-test"] + (dark ? ["--dark"] : [])
      app.launch()
      let row = app.buttons["whats-new-row"]
      let dismiss = app.buttons["whats-new-dismiss"]
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      XCTAssertTrue(dismiss.isHittable)
      XCTAssertEqual(dismiss.label, "Hide What's new until the next change")
      XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
      XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
      let picture = XCTAttachment(screenshot: app.screenshot())
      picture.name = dark ? "What's new on black" : "What's new on white"
      picture.lifetime = .keepAlways
      add(picture)
      dismiss.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: 2)).tap()
      let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
      XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
      XCTAssertFalse(dismiss.exists)
      app.terminate()
    }
  }
}
