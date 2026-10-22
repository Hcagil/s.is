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
    account: String? = "ACC", sessions: [PeekSessionRow] = []
  ) -> PeekData {
    PeekData(ownerId: owner, peerUserId: peer, storedBody: body, account: account, sessions: sessions)
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

  func testAStoredRealBodyIsShownWithoutOlm() {
    let dec = FakeDecryptor()
    XCTAssertEqual(text(push(), data(peer: nil, body: "already open"), dec), "already open")
    XCTAssertTrue(dec.log.isEmpty, "\(dec.log)")
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

  func testPreKeyMessageForANewSessionNeedsSessionsAndAnAccount() {
    let dec = FakeDecryptor()
    dec.prekeyIds["CT"] = "new"
    dec.inboundTexts["ACC+IK-a"] = "fresh"
    XCTAssertNil(text(push(ot: "0"), data(sessions: []), dec))
    XCTAssertNil(text(push(ot: "0"), data(account: nil, sessions: [row("a")]), dec))
    XCTAssertFalse(dec.log.contains { $0.hasPrefix("inbound") }, "\(dec.log)")
  }
}
