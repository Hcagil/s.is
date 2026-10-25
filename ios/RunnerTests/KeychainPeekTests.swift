import Foundation
import Security
import XCTest

@testable import Runner

// Runs ONLY on macOS (GitHub CI job `ios`, step "Native iOS tests (simulator)").
//
// KeychainMigration.migrate (Runner) and PeekCore.text / PeekPush (the
// notification extension's pure core; PushPeekCore.swift is also compiled into
// this test target, since an app extension cannot be imported) are driven
// through their injected seams: a stand-in keychain and a stand-in decryptor,
// both written from the contract, never from the implementation.

// MARK: - A keychain stand-in

/// Items per (access group, account), as the real keychain keeps them. Every
/// call is logged in order; failures can be injected per call kind.
final class FakeKeychain: KeychainItems {
  var items: [String: String] = [:]
  var log: [String] = []
  /// read(account, group) answers this error instead of the item.
  var readErrors: [String: OSStatus] = [:]
  /// add(account, group) fails with this status (nothing stored).
  var addErrors: [String: OSStatus] = [:]
  /// delete(account, group) fails with this status (nothing removed).
  var deleteErrors: [String: OSStatus] = [:]
  /// add(account, group) stores this value instead of the one given: the read-back differs.
  var corruptAdds: [String: String] = [:]

  static func k(_ account: String, _ group: String) -> String { "\(group)|\(account)" }

  func read(account: String, group: String) -> KeychainRead {
    let key = FakeKeychain.k(account, group)
    log.append("read \(key)")
    if let e = readErrors[key] { return .error(e) }
    if let v = items[key] { return .value(v) }
    return .missing
  }

  func add(account: String, value: String, group: String) -> OSStatus {
    let key = FakeKeychain.k(account, group)
    log.append("add \(key)")
    if let e = addErrors[key] { return e }
    if items[key] != nil { return errSecDuplicateItem }
    items[key] = corruptAdds[key] ?? value
    return errSecSuccess
  }

  func delete(account: String, group: String) -> OSStatus {
    let key = FakeKeychain.k(account, group)
    log.append("delete \(key)")
    if let e = deleteErrors[key] { return e }
    return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
  }
}

final class KeychainMigrationTests: XCTestCase {
  let legacy = "TEAM123.com.esd.sis"
  let group = "TEAM123.com.esd.sis.crypto"
  let store = "sis.store.key"
  let pickle = "sis.olm.pickle.key"
  let v1 = String(repeating: "a1", count: 32)
  let v2 = String(repeating: "0f", count: 32)

  func run(_ kc: FakeKeychain) -> [String: KeychainMigration.Outcome] {
    KeychainMigration.migrate(items: kc, legacyGroup: legacy, newGroup: group)
  }

  func testNothingInTheOldGroupMovesNothing() {
    let kc = FakeKeychain()
    XCTAssertEqual(run(kc), [store: .nothingToMove, pickle: .nothingToMove])
    XCTAssertFalse(kc.log.contains { $0.hasPrefix("add") || $0.hasPrefix("delete") }, "\(kc.log)")
  }

  func testBothKeysMoveAndTheOldCopyIsDeletedOnlyAfterTheReadBack() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.items[FakeKeychain.k(pickle, legacy)] = v2

    XCTAssertEqual(run(kc), [store: .moved, pickle: .moved])

    XCTAssertEqual(kc.items, [FakeKeychain.k(store, group): v1, FakeKeychain.k(pickle, group): v2])
    for account in [store, pickle] {
      let add = kc.log.firstIndex(of: "add \(FakeKeychain.k(account, group))")
      let del = kc.log.firstIndex(of: "delete \(FakeKeychain.k(account, legacy))")
      XCTAssertNotNil(add, "\(account): \(kc.log)")
      XCTAssertNotNil(del, "\(account): \(kc.log)")
      guard let a = add, let d = del else { continue }
      guard a < d else {
        XCTFail("\(account): the old copy was deleted before the add: \(kc.log)")
        continue
      }
      let readBack = kc.log[(a + 1)..<d].contains("read \(FakeKeychain.k(account, group))")
      XCTAssertTrue(readBack, "\(account): no read-back between add and delete: \(kc.log)")
    }
  }

  func testEveryCallNamesItsGroupAndTheNewGroupIsNeverDeleted() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    _ = run(kc)
    for line in kc.log {
      XCTAssertTrue(line.contains("|"), line)
      if line.hasPrefix("add") { XCTAssertTrue(line.hasPrefix("add \(group)|"), line) }
      if line.hasPrefix("delete") { XCTAssertTrue(line.hasPrefix("delete \(legacy)|"), line) }
    }
  }

  func testInterruptedAfterTheAddFinishesOnTheNextStart() {
    // The app stopped after the add, before the delete: both groups hold the same value.
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.items[FakeKeychain.k(store, group)] = v1

    XCTAssertEqual(run(kc)[store], .alreadyThere)
    XCTAssertEqual(kc.items, [FakeKeychain.k(store, group): v1])
    XCTAssertFalse(kc.log.contains("add \(FakeKeychain.k(store, group))"), "\(kc.log)")
  }

  func testADifferentValueInTheNewGroupIsAConflictAndNothingIsDeleted() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.items[FakeKeychain.k(store, group)] = v2

    XCTAssertEqual(run(kc)[store], .conflict)
    XCTAssertEqual(kc.items[FakeKeychain.k(store, legacy)], v1)
    XCTAssertEqual(kc.items[FakeKeychain.k(store, group)], v2)
    XCTAssertFalse(kc.log.contains { $0.hasPrefix("delete") || $0.hasPrefix("add") }, "\(kc.log)")
  }

  func testAReadBackThatDiffersFailsAndKeepsTheOldCopy() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.corruptAdds[FakeKeychain.k(store, group)] = v2

    XCTAssertEqual(run(kc)[store], .failed)
    XCTAssertEqual(kc.items[FakeKeychain.k(store, legacy)], v1)
    XCTAssertFalse(kc.log.contains("delete \(FakeKeychain.k(store, legacy))"), "\(kc.log)")
  }

  func testAFailedAddFailsAndKeepsTheOldCopy() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.addErrors[FakeKeychain.k(store, group)] = errSecMissingEntitlement

    XCTAssertEqual(run(kc)[store], .failed)
    XCTAssertEqual(kc.items, [FakeKeychain.k(store, legacy): v1])
  }

  func testAFailedDeleteFailsAndTheNextStartFinishes() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.deleteErrors[FakeKeychain.k(store, legacy)] = errSecInteractionNotAllowed

    XCTAssertEqual(run(kc)[store], .failed)
    XCTAssertEqual(kc.items[FakeKeychain.k(store, group)], v1)
    XCTAssertEqual(kc.items[FakeKeychain.k(store, legacy)], v1)

    kc.deleteErrors = [:]
    XCTAssertEqual(run(kc)[store], .alreadyThere)
    XCTAssertEqual(kc.items, [FakeKeychain.k(store, group): v1])
  }

  func testAReadErrorFailsAndChangesNothing() {
    for errorGroup in [legacy, group] {
      let kc = FakeKeychain()
      kc.items[FakeKeychain.k(store, legacy)] = v1
      kc.readErrors[FakeKeychain.k(store, errorGroup)] = errSecInteractionNotAllowed

      XCTAssertEqual(run(kc)[store], .failed, errorGroup)
      XCTAssertEqual(kc.items, [FakeKeychain.k(store, legacy): v1], errorGroup)
    }
  }

  func testAFailedAccountDoesNotStopTheNextOne() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.items[FakeKeychain.k(pickle, legacy)] = v2
    kc.addErrors[FakeKeychain.k(store, group)] = errSecMissingEntitlement

    XCTAssertEqual(run(kc), [store: .failed, pickle: .moved])
    XCTAssertEqual(kc.items[FakeKeychain.k(pickle, group)], v2)
  }

  func testASecondRunAfterAMoveHasNothingToMove() {
    let kc = FakeKeychain()
    kc.items[FakeKeychain.k(store, legacy)] = v1
    kc.items[FakeKeychain.k(pickle, legacy)] = v2
    _ = run(kc)
    let after = kc.items
    XCTAssertEqual(run(kc), [store: .nothingToMove, pickle: .nothingToMove])
    XCTAssertEqual(kc.items, after)
  }
}

// MARK: - A decryptor stand-in

final class FakeDecryptor: PeekDecryptor {
  var log: [String] = []
  var prekeyIds: [String: String] = [:]
  /// session pickle -> text it decrypts to (others: nil)
  var sessionTexts: [String: String] = [:]
  /// account pickle + identity key -> text
  var inboundTexts: [String: String] = [:]
  var seenKeys: [[UInt8]] = []

  func prekeySessionId(ct: String) -> String? {
    log.append("prekey \(ct)")
    return prekeyIds[ct]
  }

  func decrypt(sessionPickle: String, pickleKey: [UInt8], messageId: String, ct: String, olmType: Int32) -> String? {
    log.append("decrypt \(sessionPickle) \(messageId) \(olmType)")
    seenKeys.append(pickleKey)
    return sessionTexts[sessionPickle]
  }

  func decryptInbound(accountPickle: String, pickleKey: [UInt8], identityKey: String, messageId: String, ct: String) -> String? {
    log.append("inbound \(accountPickle) \(identityKey) \(messageId)")
    seenKeys.append(pickleKey)
    return inboundTexts["\(accountPickle)+\(identityKey)"]
  }
}

final class PeekCoreTests: XCTestCase {
  let key: [UInt8] = Array(repeating: 7, count: 32)

  func push(ot: String = "1", ct: String = "CT") -> PeekPush {
    PeekPush(userInfo: [
      "encrypted": "true", "message_id": "m1", "conversation_id": "c1", "user_id": "me",
      "ct": ct, "ot": ot,
    ])!
  }

  func row(_ id: String, peer: String = "peer", ik: String? = nil) -> PeekSessionRow {
    PeekSessionRow(sessionId: id, peerUserId: peer, identityKey: ik ?? "IK-\(id)", pickle: "P-\(id)")
  }

  func data(
    owner: String? = "me", peer: String? = "peer", body: String? = PeekCore.lockedPlaceholder,
    account: String? = "ACC", sessions: [PeekSessionRow] = [], sender: String? = nil
  ) -> PeekData {
    PeekData(ownerId: owner, peerUserId: peer, storedBody: body, account: account, sessions: sessions, storedSenderId: sender)
  }

  func text(_ p: PeekPush, _ d: PeekData, _ dec: FakeDecryptor) -> String? {
    PeekCore.text(push: p, data: d, pickleKey: key, decryptor: dec)
  }

  // MARK: PeekPush(userInfo:)

  func testAPushWithAllKeysIsRead() {
    let p = push(ot: "0")
    XCTAssertEqual(p.messageId, "m1")
    XCTAssertEqual(p.conversationId, "c1")
    XCTAssertEqual(p.userId, "me")
    XCTAssertEqual(p.ct, "CT")
    XCTAssertEqual(p.olmType, 0)
    XCTAssertEqual(push(ot: "1").olmType, 1)
  }

  func testAPushThatIsNotEncryptedOrLacksAKeyIsNil() {
    let full: [AnyHashable: Any] = [
      "encrypted": "true", "message_id": "m1", "conversation_id": "c1", "user_id": "me",
      "ct": "CT", "ot": "1",
    ]
    XCTAssertNotNil(PeekPush(userInfo: full))
    for k in ["message_id", "conversation_id", "user_id", "ct", "ot", "encrypted"] {
      var missing = full
      missing.removeValue(forKey: k)
      XCTAssertNil(PeekPush(userInfo: missing), "without \(k)")
      if k != "encrypted" {
        var empty = full
        empty[k] = ""
        XCTAssertNil(PeekPush(userInfo: empty), "empty \(k)")
      }
    }
    for bad in ["false", "1", "TRUE"] {
      var p = full
      p["encrypted"] = bad
      XCTAssertNil(PeekPush(userInfo: p), "encrypted=\(bad)")
    }
    for ot in ["2", "-1", "01"] {
      var p = full
      p["ot"] = ot
      XCTAssertNil(PeekPush(userInfo: p), "ot=\(ot)")
    }
    var number = full
    number["ot"] = 1
    XCTAssertNil(PeekPush(userInfo: number), "ot as a number: FCM data values are strings")
  }

  // MARK: PeekCore.text rules

  func testAnotherOwnersStoreGivesNilWithoutOlm() {
    let dec = FakeDecryptor()
    dec.sessionTexts["P-s1"] = "hi"
    XCTAssertNil(text(push(), data(owner: "someone-else", sessions: [row("s1")]), dec))
    XCTAssertNil(text(push(), data(owner: nil, body: "stored", sessions: [row("s1")]), dec))
    XCTAssertTrue(dec.log.isEmpty, "\(dec.log)")
  }

  // t_5d6bdca09e: only a stored text the chat's known peer sent is shown as is.
  func testAStoredRealBodyIsShownWithoutOlm() {
    let dec = FakeDecryptor()
    XCTAssertEqual(text(push(), data(body: "already open", sender: "peer"), dec), "already open")
    XCTAssertTrue(dec.log.isEmpty, "\(dec.log)")
  }

  func testAStoredBodyNotSentByTheKnownPeerGoesToOlm() {
    let cases: [(String, String?, String?)] = [
      ("sent by me", "peer", "me"),
      ("sent by a third id", "peer", "intruder"),
      ("sender unknown", "peer", nil),
    ]
    for (desc, peer, sender) in cases {
      let dec = FakeDecryptor()
      dec.sessionTexts["P-s1"] = "real"
      XCTAssertEqual(text(push(), data(peer: peer, body: "forged", sessions: [row("s1")], sender: sender), dec), "real", desc)
      // Olm cannot open it: locked, never the stored text.
      let none = FakeDecryptor()
      XCTAssertNil(text(push(), data(peer: peer, body: "forged", sessions: [row("s1")], sender: sender), none), desc)
    }
  }

  func testAStoredBodyWithNoKnownPeerIsNotShown() {
    for sender in ["peer", nil] as [String?] {
      let dec = FakeDecryptor()
      XCTAssertNil(text(push(), data(peer: nil, body: "forged", sender: sender), dec), "sender \(sender ?? "nil")")
    }
  }

  func testThePlaceholderOrNoStoredRowGoesToOlm() {
    for body in [PeekCore.lockedPlaceholder, nil] as [String?] {
      let dec = FakeDecryptor()
      dec.sessionTexts["P-s1"] = "real"
      XCTAssertEqual(text(push(), data(body: body, sessions: [row("s1")]), dec), "real")
    }
  }

  func testNoPeerGivesNil() {
    let dec = FakeDecryptor()
    dec.sessionTexts["P-s1"] = "real"
    XCTAssertNil(text(push(), data(peer: nil, sessions: [row("s1")]), dec))
  }

  func testNormalMessageTriesThePeersSessionsInOrderAndTheFirstTextWins() {
    let dec = FakeDecryptor()
    dec.sessionTexts["P-s2"] = "second"
    dec.sessionTexts["P-s3"] = "third"
    dec.sessionTexts["P-x"] = "other peer"
    let sessions = [row("x", peer: "intruder"), row("s1"), row("s2"), row("s3")]

    XCTAssertEqual(text(push(ot: "1"), data(sessions: sessions), dec), "second")
    XCTAssertEqual(dec.log, ["decrypt P-s1 m1 1", "decrypt P-s2 m1 1"])
    XCTAssertEqual(dec.seenKeys, [key, key], "the pickle key is passed through")
  }

  func testNormalMessageWithNoSessionThatOpensItGivesNil() {
    let dec = FakeDecryptor()
    XCTAssertNil(text(push(ot: "1"), data(sessions: [row("s1"), row("s2")]), dec))
    XCTAssertNil(text(push(ot: "1"), data(sessions: []), dec))
    XCTAssertFalse(dec.log.contains { $0.hasPrefix("inbound") }, "\(dec.log)")
  }

  func testPreKeyMessageWithoutASessionIdGivesNil() {
    let dec = FakeDecryptor()
    dec.sessionTexts["P-s1"] = "x"
    XCTAssertNil(text(push(ot: "0"), data(sessions: [row("s1")]), dec))
    XCTAssertEqual(dec.log, ["prekey CT"])
  }

  func testPreKeyMessageForAStoredSessionUsesThatSession() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "s2"
    dec.sessionTexts["P-s2"] = "from s2"
    dec.inboundTexts["ACC+IK-s1"] = "inbound must not be used"

    XCTAssertEqual(text(push(ot: "0"), data(sessions: [row("s1"), row("s2")]), dec), "from s2")
    XCTAssertEqual(dec.log, ["prekey CT", "decrypt P-s2 m1 0"])
  }

  func testPreKeyMessageForAnotherPeersSessionGivesNil() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "s9"
    dec.sessionTexts["P-s9"] = "stolen"
    dec.inboundTexts["ACC+IK-s1"] = "inbound"

    XCTAssertNil(text(push(ot: "0"), data(sessions: [row("s1"), row("s9", peer: "intruder")]), dec))
    XCTAssertFalse(dec.log.contains { $0.hasPrefix("decrypt") || $0.hasPrefix("inbound") }, "\(dec.log)")
  }

  func testPreKeyMessageForANewSessionOpensInboundWithTheNewestIdentityKey() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+IK-newest"] = "fresh"
    let sessions = [row("a", ik: "IK-newest"), row("b", ik: "IK-older")]

    XCTAssertEqual(text(push(ot: "0"), data(sessions: sessions), dec), "fresh")
    XCTAssertEqual(dec.log, ["prekey CT", "inbound ACC IK-newest m1"])
    XCTAssertEqual(dec.seenKeys, [key])
  }

  // t_5d6bdca09e: the newest stored session lends its identity key only when it is the peer's.
  func testPreKeyMessageForANewSessionWhoseNewestSessionIsAnotherUsersGivesNil() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+IK-a"] = "opened with another user's key"
    let sessions = [row("a", peer: "intruder"), row("b")]
    XCTAssertNil(text(push(ot: "0"), data(sessions: sessions), dec))
    XCTAssertFalse(dec.log.contains { $0.hasPrefix("inbound") }, "\(dec.log)")
  }

  func testPreKeyMessageForANewSessionNeedsSessionsAndAnAccount() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+IK-a"] = "fresh"
    XCTAssertNil(text(push(ot: "0"), data(sessions: []), dec))
    XCTAssertNil(text(push(ot: "0"), data(account: nil, sessions: [row("a")]), dec))
    XCTAssertFalse(dec.log.contains { $0.hasPrefix("inbound") }, "\(dec.log)")
  }
}

// MARK: - The first-message unlock (push sk/si)

// The iPhone first-message unlock (push sk/si) in PeekCore.text and
// PeekPush(userInfo:), driven through FakeDecryptor (KeychainPeekTests.swift).
// Written from the contract (t_af9e46f598, security P1-P6), never from the code.

final class PeekSenderKeyTests: XCTestCase {
  // MARK: - Helpers
  let key: [UInt8] = Array(repeating: 7, count: 32)
  let peer = "6f1c2a4e-8b3d-4c5e-9f70-1a2b3c4d5e6f"
  let other = "0a9b8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d"
  let validSk = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE"
  let otherSk = "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210/+ZyXwV"

  func push(ot: String = "0", sk: String? = nil, si: String? = nil) -> PeekPush {
    var userInfo: [AnyHashable: Any] = [
      "encrypted": "true",
      "message_id": "m1",
      "conversation_id": "c1",
      "user_id": "me",
      "ct": "CT",
      "ot": ot
    ]
    if let sk = sk { userInfo["sk"] = sk }
    if let si = si { userInfo["si"] = si }
    return PeekPush(userInfo: userInfo)!
  }

  func data(peer: String? = nil, account: String? = "ACC", sessions: [PeekSessionRow] = [], keyElsewhere: Bool = false) -> PeekData {
    PeekData(ownerId: "me", peerUserId: peer, storedBody: PeekCore.lockedPlaceholder, account: account, sessions: sessions, keyElsewhere: keyElsewhere)
  }

  func text(_ p: PeekPush, _ d: PeekData, _ dec: FakeDecryptor) -> String? {
    PeekCore.text(push: p, data: d, pickleKey: key, decryptor: dec)
  }

  // MARK: - Tests

  func testPeekPushKeepsSkAndSi() {
    // Valid sk and si
    let pushValid = push(sk: validSk, si: peer)
    XCTAssertEqual(pushValid.senderKey, validSk)
    XCTAssertEqual(pushValid.senderId, peer)

    // Malformed sk and si
    let pushMalformed = push(sk: "short", si: "bob")
    XCTAssertEqual(pushMalformed.senderKey, "short")
    XCTAssertEqual(pushMalformed.senderId, "bob")

    // Empty strings
    let pushEmpty = push(sk: "", si: "")
    XCTAssertNil(pushEmpty.senderKey)
    XCTAssertNil(pushEmpty.senderId)

    // Nil values
    let pushNil = push(sk: nil, si: nil)
    XCTAssertNil(pushNil.senderKey)
    XCTAssertNil(pushNil.senderId)

    // Sk present, si nil
    let pushSkOnly = push(sk: "short", si: nil)
    XCTAssertEqual(pushSkOnly.senderKey, "short")
    XCTAssertNil(pushSkOnly.senderId)

    // Sk nil, si present
    let pushSiOnly = push(sk: nil, si: "bob")
    XCTAssertNil(pushSiOnly.senderKey)
    XCTAssertEqual(pushSiOnly.senderId, "bob")
  }

  func testOt0NoSessionsValidSk() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "inbound text"

    let p = push(ot: "0", sk: validSk, si: peer)
    let d = data(peer: peer)
    let result = text(p, d, dec)

    XCTAssertEqual(result, "inbound text")
    XCTAssertEqual(dec.log, ["prekey CT", "inbound ACC \(validSk) m1"])
  }

  func testOt0PeerUserIdNil() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "inbound text"

    let p = push(ot: "0", sk: validSk, si: peer)
    let d = data(peer: nil)
    let result = text(p, d, dec)

    XCTAssertEqual(result, "inbound text")
    XCTAssertEqual(dec.log, ["prekey CT", "inbound ACC \(validSk) m1"])
  }

  func testOt0StoredSessionOverridesSk() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+IK-stored"] = "stored inbound"

    let session = PeekSessionRow(sessionId: "a", peerUserId: peer, identityKey: "IK-stored", pickle: "P-a")
    let p = push(ot: "0", sk: otherSk, si: peer)
    let d = data(peer: peer, sessions: [session])
    let result = text(p, d, dec)

    XCTAssertEqual(result, "stored inbound")
    XCTAssertTrue(dec.log.contains("prekey CT"))
    XCTAssertTrue(dec.log.contains("inbound ACC IK-stored m1"))
    XCTAssertFalse(dec.log.contains(where: { $0.contains(otherSk) }), "\(dec.log)")
  }

  func testOt0SiNotPeerNilInbound() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "inbound text"

    let p = push(ot: "0", sk: validSk, si: other)
    let d = data(peer: peer)
    let result = text(p, d, dec)

    XCTAssertNil(result)
    XCTAssertFalse(dec.log.contains(where: { $0.contains("inbound") || $0.contains("decrypt") }))

    // ot 1 with session decrypt
    let session = PeekSessionRow(sessionId: "s1", peerUserId: peer, identityKey: "IK-s1", pickle: "P-s1")
    dec.sessionTexts["P-s1"] = "hi"
    let p1 = push(ot: "1", sk: validSk, si: other)
    let d1 = data(peer: peer, sessions: [session])
    let result1 = text(p1, d1, dec)

    XCTAssertNil(result1)
    XCTAssertFalse(dec.log.contains(where: { $0.contains("inbound") || $0.contains("decrypt") }))
  }

  func testBadShape() {
    let sk42 = String(repeating: "a", count: 42)
    let sk44 = String(repeating: "a", count: 44)
    let sk43Dash = String(repeating: "a", count: 42) + "-"
    let sk43Equals = String(repeating: "a", count: 42) + "="
    let sk43Space = String(repeating: "a", count: 42) + " "
    let badSkCases = [
      ("42 chars", sk42),
      ("44 chars", sk44),
      ("43 chars with dash", sk43Dash),
      ("43 chars with equals", sk43Equals),
      ("43 chars with space", sk43Space),
      ("43 chars with a non-ASCII letter", String(repeating: "a", count: 42) + "é")
    ]

    let badSiCases = [
      ("not-a-uuid", "not-a-uuid"),
      ("missing one char", String(peer.dropLast())),
      ("one hex digit too many at the end", peer + "0"),
      ("one hex digit too many at the start", "0" + peer),
      ("hex digit replaced with g", peer.replacingOccurrences(of: "a", with: "g")),
      // t_5d6bdca09e: only the lowercase form a uuid column prints.
      ("uppercase", peer.uppercased())
    ]

    // Each bad value is the ONLY thing wrong: si equals the peer (or the
    // chat has none) and the fake would decrypt with whatever key it gets.
    for (desc, badSk) in badSkCases {
      let dec = FakeDecryptor()
      dec.prekeyIds["CT"] = "new"
      dec.inboundTexts["ACC+\(badSk)"] = "opened with a bad key"
      XCTAssertNil(text(push(ot: "0", sk: badSk, si: peer), data(peer: peer), dec), "Bad sk case: \(desc)")
      XCTAssertFalse(dec.log.contains(where: { $0.hasPrefix("inbound") }), "Bad sk case: \(desc): \(dec.log)")
    }

    for (desc, badSi) in badSiCases {
      for known in [nil, badSi] as [String?] {
        let dec = FakeDecryptor()
        dec.prekeyIds["CT"] = "new"
        dec.inboundTexts["ACC+\(validSk)"] = "opened for a bad sender id"
        XCTAssertNil(text(push(ot: "0", sk: validSk, si: badSi), data(peer: known), dec), "Bad si case: \(desc), known peer \(known ?? "none")")
        XCTAssertFalse(dec.log.contains(where: { $0.hasPrefix("inbound") }), "Bad si case: \(desc): \(dec.log)")
      }
    }
  }

  func testKeyElsewhereTrue() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "inbound text"

    let p = push(ot: "0", sk: validSk, si: peer)
    let d = data(peer: peer, keyElsewhere: true)
    let result = text(p, d, dec)

    XCTAssertNil(result)
    XCTAssertFalse(dec.log.contains(where: { $0.contains("inbound") }))
  }

  func testAccountNil() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "inbound text"

    let p = push(ot: "0", sk: validSk, si: peer)
    let d = data(peer: peer, account: nil)
    let result = text(p, d, dec)

    XCTAssertNil(result)
    XCTAssertFalse(dec.log.contains(where: { $0.contains("inbound") }))
  }

  func testMissingSkOrSi() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "inbound text"

    // Missing sk
    let p1 = push(ot: "0", sk: nil, si: peer)
    let d1 = data(peer: peer)
    let result1 = text(p1, d1, dec)
    XCTAssertNil(result1)
    XCTAssertFalse(dec.log.contains(where: { $0.contains("inbound") }))

    // Missing si
    let p2 = push(ot: "0", sk: validSk, si: nil)
    let d2 = data(peer: peer)
    let result2 = text(p2, d2, dec)
    XCTAssertNil(result2)
    XCTAssertFalse(dec.log.contains(where: { $0.contains("inbound") }))
  }

  func testOt1IgnoresSkSi() {
    let session = PeekSessionRow(sessionId: "s1", peerUserId: peer, identityKey: "IK-s1", pickle: "P-s1")
    func fresh() -> FakeDecryptor {
      let dec = FakeDecryptor()
      dec.prekeyIds["CT"] = "new"
      dec.sessionTexts["P-s1"] = "hi"
      dec.inboundTexts["ACC+\(validSk)"] = "sk must not be used"
      return dec
    }

    // A stored session opens it; sk plays no part.
    let d1 = fresh()
    XCTAssertEqual(text(push(ot: "1", sk: validSk, si: peer), data(peer: peer, sessions: [session]), d1), "hi")
    XCTAssertEqual(d1.log, ["decrypt P-s1 m1 1"])

    // No session: nothing opens it, sk is not used for an inbound session.
    let d2 = fresh()
    XCTAssertNil(text(push(ot: "1", sk: validSk, si: peer), data(peer: peer, sessions: []), d2))
    XCTAssertFalse(d2.log.contains(where: { $0.hasPrefix("inbound") || $0.hasPrefix("prekey") }), "\(d2.log)")

    // No known chat peer: si does not become the peer for a normal message.
    let d3 = fresh()
    XCTAssertNil(text(push(ot: "1", sk: validSk, si: peer), data(peer: nil, sessions: [session]), d3))
    XCTAssertTrue(d3.log.isEmpty, "\(d3.log)")
  }

  func testDecryptFailure() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    // inboundTexts empty

    let p = push(ot: "0", sk: validSk, si: peer)
    let d = data(peer: peer)
    let result = text(p, d, dec)

    XCTAssertNil(result)
    XCTAssertEqual(dec.log, ["prekey CT", "inbound ACC \(validSk) m1"], "the decrypt was tried and failed")
  }

  func testOt0NoKnownPeerUsesTheSendersStoredSessionNotSk() {
    // The store reader returns the sender id's sessions when the chat has no known peer.
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+IK-stored"] = "stored inbound"
    dec.inboundTexts["ACC+\(validSk)"] = "sk must not be used"
    let session = PeekSessionRow(sessionId: "a", peerUserId: peer, identityKey: "IK-stored", pickle: "P-a")

    XCTAssertEqual(text(push(ot: "0", sk: validSk, si: peer), data(peer: nil, sessions: [session]), dec), "stored inbound")
    XCTAssertEqual(dec.log, ["prekey CT", "inbound ACC IK-stored m1"])
  }

  func testOt0StoredSessionIdOfTheSenderDecryptsThatSession() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "a"
    dec.sessionTexts["P-a"] = "from a"
    dec.inboundTexts["ACC+\(validSk)"] = "sk must not be used"
    let session = PeekSessionRow(sessionId: "a", peerUserId: peer, identityKey: "IK-a", pickle: "P-a")

    XCTAssertEqual(text(push(ot: "0", sk: validSk, si: peer), data(peer: peer, sessions: [session]), dec), "from a")
    XCTAssertEqual(dec.log, ["prekey CT", "decrypt P-a m1 0"])
  }

  func testTheValidCaseAlsoPassesThePickleKey() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "x"
    _ = text(push(ot: "0", sk: validSk, si: peer), data(peer: peer), dec)
    XCTAssertEqual(dec.seenKeys, [key])
  }

  func testValidSkLength() {
    XCTAssertEqual(validSk.count, 43, "validSk should be 43 characters")
    XCTAssertEqual(otherSk.count, 43)
    XCTAssertNotEqual(otherSk, validSk)
  }
}

// MARK: - What may be saved (PeekCore.opened, slice 3)

// PeekCore.opened storedKey: only a key already on the phone (stored session,
// stored session id, inbound with the stored peer key) may lead to a save; the
// push sk (first contact) and a stored body never do. text() == opened()?.text.
// Written from the contract (t_176cbd956f), never from the code. Draft: test_writer.

final class PeekOpenedTests: XCTestCase {
  // MARK: - Helpers

  let key: [UInt8] = Array(repeating: 7, count: 32)
  let peer = "6f1c2a4e-8b3d-4c5e-9f70-1a2b3c4d5e6f"
  let validSk = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE"

  func push(ot: String, sk: String? = nil, si: String? = nil) -> PeekPush {
    var u: [AnyHashable: Any] = ["encrypted": "true",
                                 "message_id": "m1",
                                 "conversation_id": "c1",
                                 "user_id": "me",
                                 "ct": "CT",
                                 "ot": ot]
    if let sk = sk { u["sk"] = sk }
    if let si = si { u["si"] = si }
    return PeekPush(userInfo: u)!
  }

  func row(_ id: String, peer p: String? = nil, ik: String? = nil) -> PeekSessionRow {
    PeekSessionRow(sessionId: id,
                   peerUserId: p ?? peer,
                   identityKey: ik ?? "IK-\(id)",
                   pickle: "P-\(id)")
  }

  func data(noPeer: Bool = false,
            body: String? = PeekCore.lockedPlaceholder,
            sender: String? = nil,
            sessions: [PeekSessionRow] = []) -> PeekData {
    let peerUserId: String? = noPeer ? nil : peer
    return PeekData(ownerId: "me",
                    peerUserId: peerUserId,
                    storedBody: body,
                    account: "ACC",
                    sessions: sessions,
                    storedSenderId: sender)
  }

  func opened(_ p: PeekPush, _ d: PeekData, _ dec: FakeDecryptor) -> PeekOpened? {
    PeekCore.opened(push: p, data: d, pickleKey: key, decryptor: dec)
  }

  // MARK: - Tests

  func testOt1StoredSessionIsStoredKey() {
    let dec = FakeDecryptor()
    dec.sessionTexts["P-s1"] = "hi"
    let p = push(ot: "1")
    let d = data(sessions: [row("s1")])
    let result = opened(p, d, dec)
    XCTAssertEqual(result, PeekOpened(text: "hi", storedKey: true))
  }

  func testOt0StoredSessionIdIsStoredKey() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "s1"
    dec.sessionTexts["P-s1"] = "pre"
    let p = push(ot: "0")
    let d = data(sessions: [row("s1")])
    let result = opened(p, d, dec)
    XCTAssertEqual(result, PeekOpened(text: "pre", storedKey: true))
  }

  func testOt0InboundWithStoredPeerSessionIsStoredKey() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+IK-a"] = "fresh"
    let p = push(ot: "0")
    let d = data(sessions: [row("a")])
    let result = opened(p, d, dec)
    XCTAssertEqual(result, PeekOpened(text: "fresh", storedKey: true))
  }

  func testOt0InboundWithPushSenderKeyIsNotStoredKey() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+\(validSk)"] = "first"
    let p = push(ot: "0", sk: validSk, si: peer)

    // Peer known
    let d1 = data(sessions: [])
    let result1 = opened(p, d1, dec)
    XCTAssertEqual(result1, PeekOpened(text: "first", storedKey: false))

    // No peer
    let d2 = data(noPeer: true, sessions: [])
    let result2 = opened(p, d2, dec)
    XCTAssertEqual(result2, PeekOpened(text: "first", storedKey: false))
  }

  func testAStoredBodyIsNotStoredKey() {
    let dec = FakeDecryptor()
    dec.sessionTexts["P-s1"] = "olm"
    let p = push(ot: "1")
    let d = data(body: "stored text", sender: peer, sessions: [row("s1")])
    let result = opened(p, d, dec)
    XCTAssertEqual(result, PeekOpened(text: "stored text", storedKey: false))
  }

  func testNothingOpensGivesNil() {
    // ot1 with no sessionTexts
    let dec1 = FakeDecryptor()
    let p1 = push(ot: "1")
    let d1 = data(sessions: [row("s1")])
    let result1 = opened(p1, d1, dec1)
    XCTAssertNil(result1)

    // ot0 with no prekeyIds
    let dec2 = FakeDecryptor()
    let p2 = push(ot: "0")
    let d2 = data(sessions: [])
    let result2 = opened(p2, d2, dec2)
    XCTAssertNil(result2)
  }

  func testTextEqualsOpenedText() {
    let cases: [(PeekPush, PeekData, (FakeDecryptor) -> Void)] = [
      // 1
      (push(ot: "1"),
       data(sessions: [row("s1")]),
       { dec in dec.sessionTexts["P-s1"] = "hi" }),

      // 2
      (push(ot: "0"),
       data(sessions: [row("s1")]),
       { dec in
          dec.prekeyIds["CT"] = "s1"
          dec.sessionTexts["P-s1"] = "pre"
       }),

      // 3
      (push(ot: "0"),
       data(sessions: [row("a")]),
       { dec in
          dec.prekeyIds["CT"] = "new"
          dec.inboundTexts["ACC+IK-a"] = "fresh"
       }),

      // 4a
      (push(ot: "0", sk: validSk, si: peer),
       data(sessions: []),
       { dec in
          dec.prekeyIds["CT"] = "new"
          dec.inboundTexts["ACC+\(validSk)"] = "first"
       }),

      // 4b
      (push(ot: "0", sk: validSk, si: peer),
       data(noPeer: true, sessions: []),
       { dec in
          dec.prekeyIds["CT"] = "new"
          dec.inboundTexts["ACC+\(validSk)"] = "first"
       }),

      // 5
      (push(ot: "1"),
       data(body: "stored text", sender: peer, sessions: [row("s1")]),
       { dec in dec.sessionTexts["P-s1"] = "olm" }),

      // 6a nil
      (push(ot: "1"),
       data(sessions: [row("s1")]),
       { _ in }),

      // 6b nil
      (push(ot: "0"),
       data(sessions: []),
       { _ in })
    ]

    for (p, d, setup) in cases {
      let decText = FakeDecryptor()
      setup(decText)
      let decOpened = FakeDecryptor()
      setup(decOpened)

      let text = PeekCore.text(push: p, data: d, pickleKey: key, decryptor: decText)
      let opened = PeekCore.opened(push: p, data: d, pickleKey: key, decryptor: decOpened)

      if let opened = opened {
        XCTAssertEqual(text, opened.text)
      } else {
        XCTAssertNil(text)
      }
    }
  }
}

// MARK: - The save decision (PeekCore.saveRow / sealedHash, slice 3 fix round 1)

// Save only a text opened with a stored key, only for a known store peer (never
// the push si); sealed = Dart sha256 hex of the UTF-8 ciphertext (vectors from
// hashlib, the standard SHA-256 Dart package:crypto implements).
// Written from the contract (t_176cbd956f), never from the code. Draft: test_writer.
final class PeekSaveRowTests: XCTestCase {
  let peer = "6f1c2a4e-8b3d-4c5e-9f70-1a2b3c4d5e6f"
  let other = "0a9b8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d"
  func push(ct: String = "AwogQ+/xyz==", si: String? = nil) -> PeekPush {
    var u: [AnyHashable: Any] = ["encrypted": "true", "message_id": "m1", "conversation_id": "c1", "user_id": "me", "ct": ct, "ot": "0"]
    if let si = si { u["si"] = si }
    return PeekPush(userInfo: u)!
  }
  func data(peer p: String?) -> PeekData {
    PeekData(ownerId: "me", peerUserId: p, storedBody: nil, account: "ACC", sessions: [])
  }

  func testAStoredKeyTextIsSavedWithTheStorePeerAndTheCiphertextHash() {
    let r = PeekCore.saveRow(push: push(), data: data(peer: peer), opened: PeekOpened(text: "merhaba", storedKey: true))
    XCTAssertEqual(r?.peerUserId, peer)
    XCTAssertEqual(r?.body, "merhaba")
    XCTAssertEqual(r?.sealed, "71722cc5f9acf0dbcd5a3dafeee05b7a4b508564b39edc2914fdf91b8d7a55f7")
  }

  func testATextNotOpenedWithAStoredKeyIsNeverSaved() {
    let r1 = PeekCore.saveRow(push: push(si: peer), data: data(peer: peer), opened: PeekOpened(text: "first", storedKey: false))
    XCTAssertNil(r1)
    let r2 = PeekCore.saveRow(push: push(si: peer), data: data(peer: peer), opened: nil)
    XCTAssertNil(r2)
  }

  func testTheSenderIsTheStorePeerEvenWhenThePushSenderIdDiffers() {
    let r = PeekCore.saveRow(push: push(si: other), data: data(peer: peer), opened: PeekOpened(text: "test", storedKey: true))
    XCTAssertEqual(r?.peerUserId, peer)
    XCTAssertNotEqual(r?.peerUserId, other)
  }

  func testNoKnownPeerIsNeverSavedEvenWithAStoredKey() {
    let r1 = PeekCore.saveRow(push: push(si: peer), data: data(peer: nil), opened: PeekOpened(text: "x", storedKey: true))
    XCTAssertNil(r1)
    let r2 = PeekCore.saveRow(push: push(si: nil), data: data(peer: nil), opened: PeekOpened(text: "x", storedKey: true))
    XCTAssertNil(r2)
  }

  func testSealedHashIsTheDartSha256HexOfTheUtf8Ciphertext() {
    XCTAssertEqual(PeekCore.sealedHash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(PeekCore.sealedHash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    XCTAssertEqual(PeekCore.sealedHash("Günaydın 🔒"), "3b874d5e72d79187fa863a851df66557e16116892f21f00d5f13ed76bc173c4a")
    XCTAssertEqual(PeekCore.sealedHash("AwogQ+/xyz=="), "71722cc5f9acf0dbcd5a3dafeee05b7a4b508564b39edc2914fdf91b8d7a55f7")
  }
}
