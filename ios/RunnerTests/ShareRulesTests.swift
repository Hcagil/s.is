import XCTest

@testable import Runner

// Runs ONLY on macOS (GitHub CI job `ios`, step "Native iOS tests (simulator)").
//
// ShareRules (the share extension's pure size and text rules; ShareRules.swift
// is also compiled into this test target, since an app extension cannot be
// imported). Written from the contract, never from the implementation.

final class ShareRulesTests: XCTestCase {
  private func a(_ n: Int) -> String { String(repeating: "a", count: n) }
  private func b(_ n: Int) -> String { String(repeating: "b", count: n) }

  // MARK: - Limits

  func testLimitsMatchTheContract() {
    XCTAssertEqual(ShareRules.maxVideoBytes, 1_073_741_824)
    XCTAssertEqual(ShareRules.maxPhotoBytes, 52_428_800)
    XCTAssertEqual(ShareRules.maxTextChars, 4000)
  }

  // MARK: - allowsFile

  func testUnknownSizeIsRefusedForPhotoAndVideo() {
    XCTAssertFalse(ShareRules.allowsFile(size: nil, isVideo: false))
    XCTAssertFalse(ShareRules.allowsFile(size: nil, isVideo: true))
  }

  func testPhotoAtCapIsAllowedAndOneByteOverIsRefused() {
    XCTAssertTrue(ShareRules.allowsFile(size: 52_428_800, isVideo: false))
    XCTAssertFalse(ShareRules.allowsFile(size: 52_428_801, isVideo: false))
  }

  func testEmptyPhotoIsAllowed() {
    XCTAssertTrue(ShareRules.allowsFile(size: 0, isVideo: false))
  }

  func testVideoAtCapIsAllowedAndOneByteOverIsRefused() {
    XCTAssertTrue(ShareRules.allowsFile(size: 1_073_741_824, isVideo: true))
    XCTAssertFalse(ShareRules.allowsFile(size: 1_073_741_825, isVideo: true))
  }

  func testPhotoCapIsNotAppliedToVideo() {
    XCTAssertTrue(ShareRules.allowsFile(size: 52_428_801, isVideo: true))
  }

  func testVideoCapIsNotAppliedToPhoto() {
    XCTAssertFalse(ShareRules.allowsFile(size: 1_073_741_824, isVideo: false))
  }

  // MARK: - clippedText

  func testNoPartsGiveEmptyText() {
    XCTAssertEqual(ShareRules.clippedText([]), "")
  }

  func testPartsAreJoinedWithNewline() {
    XCTAssertEqual(ShareRules.clippedText(["hello", "world"]), "hello\nworld")
  }

  func testTextAtLimitIsKeptWhole() {
    let result = ShareRules.clippedText([a(4000)])
    XCTAssertEqual(result, a(4000))
    XCTAssertEqual(result.utf16.count, 4000)
  }

  func testTextOverLimitIsCutTo4000Units() {
    let result = ShareRules.clippedText([a(4001)])
    XCTAssertEqual(result, a(4000))
    XCTAssertEqual(result.utf16.count, 4000)
  }

  func testCutInsideEmojiDropsTheLeadSurrogate() {
    let result = ShareRules.clippedText([a(3999) + "\u{1F600}"])
    XCTAssertEqual(result.utf16.count, 3999)
    XCTAssertEqual(result, a(3999))
    if let last = result.utf16.last {
      XCTAssertFalse((0xD800...0xDBFF).contains(last), "trailing lead surrogate kept")
    }
  }

  func testEmojiEndingExactlyAtLimitIsKept() {
    let text = a(3998) + "\u{1F600}"
    let result = ShareRules.clippedText([text])
    XCTAssertEqual(result, text)
    XCTAssertEqual(result.utf16.count, 4000)
  }

  func testJoinedPartsOfExactly4000UnitsAreKeptWhole() {
    let result = ShareRules.clippedText([a(1999), b(2000)])
    XCTAssertEqual(result, a(1999) + "\n" + b(2000))
    XCTAssertEqual(result.utf16.count, 4000)
  }

  func testJoinedPartsOverLimitAreCutAfterJoining() {
    let result = ShareRules.clippedText([a(2000), b(2000)])
    XCTAssertEqual(result, a(2000) + "\n" + b(1999))
    XCTAssertEqual(result.utf16.count, 4000)
  }
}
