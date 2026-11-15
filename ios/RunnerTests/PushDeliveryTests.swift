import XCTest
@testable import Runner
import Foundation

// Runs ONLY on macOS (GitHub CI job `ios`, step "Native iOS tests (simulator)").
//
// PushDelivery (the push delivery logic; PushDelivery.swift is also compiled into this test target, since an app extension cannot be imported). Written from the contract, never from the implementation.

final class PushDeliveryTests: XCTestCase {
  // MARK: - Fixtures

  let now = Date(timeIntervalSince1970: 1_767_225_600)
  var nowS: Int { Int(now.timeIntervalSince1970) }

  func item(token: String = "tok-1",
            expiresAt: Int? = nil,
            userId: String = "u-1",
            url: String = "https://ref.sis.test",
            key: String = "pk-1") -> DeliveryItem {
    DeliveryItem(accessToken: token,
                 expiresAt: expiresAt ?? nowS + 3600,
                 userId: userId,
                 url: url,
                 key: key)
  }

  let push: [AnyHashable: Any] = ["conversation_id": "c-1",
                                  "user_id": "u-1",
                                  "message_id": "m-1"]

  func with(_ k: String, _ v: Any?) -> [AnyHashable: Any] {
    var p = push
    if let v = v { p[k] = v } else { p.removeValue(forKey: k) }
    return p
  }

  // MARK: - Fakes

  final class FakeReader: DeliveryReading {
    var item: DeliveryItem?
    var reads = 0
    init(_ item: DeliveryItem?) { self.item = item }
    func read() -> DeliveryItem? { reads += 1; return item }
  }

  final class FakeCaller: DeliveryCalling {
    var sent: [URLRequest] = []
    var pending: [() -> Void] = []
    var cancels = 0
    func send(_ request: URLRequest, completion: @escaping () -> Void) {
      sent.append(request)
      pending.append(completion)
    }
    func cancel() { cancels += 1 }
    func finishAll() {
      let p = pending
      pending = []
      p.forEach { $0() }
    }
  }

  // MARK: - Tests

  func testConstants() {
    XCTAssertEqual(PushDelivery.timeout, 5)
    XCTAssertEqual(PushDelivery.expirySlack, 30)
  }

  func testGoodPushAndItem() throws {
    let req = try XCTUnwrap(PushDelivery.request(userInfo: push, now: now, item: item()))
    XCTAssertEqual(req.url?.absoluteString, "https://ref.sis.test/rest/v1/rpc/mark_delivered")
    XCTAssertEqual(req.httpMethod, "POST")
    XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"), "pk-1")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
    XCTAssertEqual(req.timeoutInterval, 5)

    let bodyData = try XCTUnwrap(req.httpBody)
    let json = try JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any]
    XCTAssertEqual(json?.count, 2)
    XCTAssertEqual(json?["conversation"] as? String, "c-1")
    XCTAssertTrue(json?["up_to"] is NSNull)
  }

  func testNoItem() {
    XCTAssertNil(PushDelivery.request(userInfo: push, now: now, item: nil))
  }

  func testKindReaction() {
    let p = with("kind", "reaction")
    XCTAssertNil(PushDelivery.request(userInfo: p, now: now, item: item()))
  }

  func testConversationIdMissing() {
    let p = with("conversation_id", nil)
    XCTAssertNil(PushDelivery.request(userInfo: p, now: now, item: item()))
  }

  func testConversationIdEmpty() {
    let p = with("conversation_id", "")
    XCTAssertNil(PushDelivery.request(userInfo: p, now: now, item: item()))
  }

  func testUserIdMissing() {
    let p = with("user_id", nil)
    XCTAssertNil(PushDelivery.request(userInfo: p, now: now, item: item()))
  }

  func testUserIdDifferent() {
    let p = with("user_id", "u-2")
    XCTAssertNil(PushDelivery.request(userInfo: p, now: now, item: item()))
  }

  func testExpiryWithin30SecondsIsSkippedAndJustAfterIsSent() {
    let p = item(expiresAt: nowS + 30)
    XCTAssertNil(PushDelivery.request(userInfo: push, now: now, item: p))
    let p2 = item(expiresAt: nowS + 31)
    XCTAssertNotNil(PushDelivery.request(userInfo: push, now: now, item: p2))
  }

  func testExpired() {
    let p = item(expiresAt: nowS - 1)
    XCTAssertNil(PushDelivery.request(userInfo: push, now: now, item: p))
  }

  func testHttpUrlIsSkipped() {
    let p = item(url: "http://ref.sis.test")
    XCTAssertNil(PushDelivery.request(userInfo: push, now: now, item: p))
  }

  func testEmptyKeyIsSkipped() {
    let p = item(key: "")
    XCTAssertNil(PushDelivery.request(userInfo: push, now: now, item: p))
  }

  func testNonReactionKindIsNotSkipped() {
    let p = with("kind", "message")
    XCTAssertNotNil(PushDelivery.request(userInfo: p, now: now, item: item()))
  }

  func testForeignActionUrlIgnored() {
    let p = with("action_url", "https://evil.mail.test/functions/v1/notification-action")
    let req = try! XCTUnwrap(PushDelivery.request(userInfo: p, now: now, item: item()))
    XCTAssertEqual(req.url?.host, "ref.sis.test")
  }

  func testRunSendsOnceAndCompletesOnce() {
    let reader = FakeReader(item())
    let caller = FakeCaller()
    var done = 0
    PushDelivery.run(userInfo: push, now: now, reader: reader, caller: caller) { done += 1 }
    XCTAssertEqual(caller.sent.count, 1)
    XCTAssertEqual(caller.sent.first?.url?.absoluteString,
                   "https://ref.sis.test/rest/v1/rpc/mark_delivered")
    XCTAssertEqual(done, 0)
    caller.finishAll()
    XCTAssertEqual(done, 1)
  }

  func testRunWithSkipCallsCompletionOnce() {
    let reader = FakeReader(nil)
    let caller = FakeCaller()
    let e = expectation(description: "completion")
    e.expectedFulfillmentCount = 1
    e.assertForOverFulfill = true
    PushDelivery.run(userInfo: push, now: now, reader: reader, caller: caller) { e.fulfill() }
    wait(for: [e], timeout: 1)
    XCTAssertTrue(caller.sent.isEmpty)
  }

  func testURLSessionDeliveryCallerErrorSwallowed() {
    let caller = URLSessionDeliveryCaller()
    let req = URLRequest(url: URL(string: "https://127.0.0.1:9/rest/v1/rpc/mark_delivered")!)
    let e = expectation(description: "completion")
    e.assertForOverFulfill = true
    caller.send(req) { e.fulfill() }
    wait(for: [e], timeout: 10)
  }

  func testURLSessionDeliveryCallerCancelCompletesOnce() {
    let caller = URLSessionDeliveryCaller()
    let req = URLRequest(url: URL(string: "https://10.255.255.1/rest/v1/rpc/mark_delivered")!)
    let e = expectation(description: "completion")
    e.assertForOverFulfill = true
    caller.send(req) { e.fulfill() }
    caller.cancel()
    caller.cancel()
    wait(for: [e], timeout: 5)
  }

  func testRedirectRefused() {
    let c = URLSessionDeliveryCaller()
    let s = URLSession(configuration: .ephemeral)
    let task = s.dataTask(with: URL(string: "https://ref.sis.test/a")!)
    let resp = HTTPURLResponse(url: URL(string: "https://ref.sis.test/a")!,
                               statusCode: 302,
                               httpVersion: "HTTP/1.1",
                               headerFields: ["Location": "https://evil.mail.test/b"])!
    var got: URLRequest? = URLRequest(url: URL(string: "https://x.test")!)
    var called = false
    c.urlSession(s, task: task, willPerformHTTPRedirection: resp, newRequest: URLRequest(url: URL(string: "https://evil.mail.test/b")!)) { r in
      called = true
      got = r
    }
    XCTAssertTrue(called)
    XCTAssertNil(got)
    s.invalidateAndCancel()
  }

  func testEmptyTokenIsSkipped() {
    let p = item(token: "")
    XCTAssertNil(PushDelivery.request(userInfo: push, now: now, item: p))
  }

}
