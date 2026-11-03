// sis_peek_reaction_session against real Olm sessions (vodozemac through the app's own wrapper).
use crate::c_api::sis_peek_reaction_session;
use crate::api::olm::{OlmAccount, OlmCiphertext, OlmSession};
use std::ffi::CString;

const KEY: [u8; 32] = [7; 32];
const MSG: &str = "11111111-1111-4111-8111-111111111111";
const REACTOR: &str = "22222222-2222-4222-8222-222222222222";

/// Alice (the reactor) and Bob (the phone that peeks), with an Olm session each.
struct Pair {
    alice: OlmSession,
    bob: OlmSession,
}

fn pair() -> Pair {
    let alice_acc = OlmAccount::new();
    let mut bob_acc = OlmAccount::new();
    let otk = bob_acc.generate_one_time_keys(1).remove(0);
    bob_acc.mark_keys_as_published();
    let mut alice = alice_acc.create_outbound_session(bob_acc.identity_key(), otk).unwrap();
    let first = alice.encrypt(b"hello".to_vec()).unwrap();
    let bob = bob_acc.create_inbound_session(alice_acc.identity_key(), first).unwrap().session;
    Pair { alice, bob }
}

fn reaction(i: &str, u: &str, emoji: &str) -> Vec<u8> {
    serde_json::json!({"v": 1, "k": "r", "i": i, "u": u, "e": emoji, "p": "    "}).to_string().into_bytes()
}

struct Out {
    code: i32,
    text: Vec<u8>,
    buf: Vec<u8>,
    len: usize,
}

fn peek_raw(key: &[u8], pickle: &CString, mid: &CString, rid: &CString, ct: &CString, olm_type: i32, cap: usize) -> Out {
    let mut buf = vec![0u8; cap.max(1)];
    let mut len = 0usize;
    let code = unsafe {
        sis_peek_reaction_session(key.as_ptr(), key.len(), pickle.as_ptr(), mid.as_ptr(), rid.as_ptr(), ct.as_ptr(), olm_type, buf.as_mut_ptr(), cap, &mut len)
    };
    let text = if code == 0 { buf[..len].to_vec() } else { Vec::new() };
    Out { code, text, buf, len }
}

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn b64(m: &OlmCiphertext) -> CString {
    c(&vodozemac::base64_encode(&m.body))
}

/// Peek `plain` sent Alice -> Bob as a pre-key message (olm_type 0), with message_id MSG and reactor REACTOR.
fn peek_plain(plain: Vec<u8>) -> Out {
    let mut p = pair();
    let m = p.alice.encrypt(plain).unwrap();
    assert_eq!(m.message_type, 0);
    let pickle = c(&p.bob.pickle(KEY.to_vec()).unwrap());
    peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &b64(&m), 0, 64)
}

fn assert_refused(o: Out, want: i32) {
    assert_eq!(o.code, want);
    assert_eq!(o.len, 0, "out_len must stay empty on a refusal");
    assert!(o.buf.iter().all(|&b| b == 0), "out must stay empty on a refusal");
}

#[test]
fn a_reaction_envelope_in_a_pre_key_message_gives_the_emoji() {
    let o = peek_plain(reaction(MSG, REACTOR, "👍"));
    assert_eq!(o.code, 0);
    assert_eq!(String::from_utf8(o.text).unwrap(), "👍");
}

#[test]
fn a_reaction_envelope_in_a_normal_message_gives_the_emoji() {
    let mut p = pair();
    // Bob answers once, so Alice's next message is a normal (type 1) message.
    let reply = p.bob.encrypt(b"hi back".to_vec()).unwrap();
    p.alice.decrypt(reply).unwrap();
    let m = p.alice.encrypt(reaction(MSG, REACTOR, "❤️")).unwrap();
    assert_eq!(m.message_type, 1);
    let pickle = c(&p.bob.pickle(KEY.to_vec()).unwrap());
    let o = peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &b64(&m), 1, 64);
    assert_eq!(o.code, 0);
    assert_eq!(String::from_utf8(o.text).unwrap(), "❤️");
}

#[test]
fn the_pickle_is_not_changed_and_nothing_is_saved() {
    let mut p = pair();
    let m = p.alice.encrypt(reaction(MSG, REACTOR, "😂")).unwrap();
    let pickle = c(&p.bob.pickle(KEY.to_vec()).unwrap());
    let before = pickle.as_bytes().to_vec();
    let ct = b64(&m);
    let first = peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &ct, 0, 64);
    assert_eq!(pickle.as_bytes(), &before[..]);
    // Same pickle, same message again: still decrypts, so no ratchet state was kept.
    let second = peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &ct, 0, 64);
    assert_eq!((first.code, second.code), (0, 0));
    assert_eq!(first.text, second.text);
    // And the real session still decrypts it afterwards.
    assert_eq!(p.bob.decrypt(m).unwrap(), reaction(MSG, REACTOR, "😂"));
}

#[test]
fn a_reaction_for_another_message_is_refused() {
    assert_refused(peek_plain(reaction("33333333-3333-4333-8333-333333333333", REACTOR, "👍")), 4);
}

#[test]
fn a_reaction_from_another_reactor_is_refused() {
    assert_refused(peek_plain(reaction(MSG, "44444444-4444-4444-8444-444444444444", "👍")), 4);
}

#[test]
fn an_envelope_that_is_not_a_reaction_is_refused() {
    let plain = serde_json::json!({"v": 1, "k": "t", "i": MSG, "u": REACTOR, "e": "👍"}).to_string().into_bytes();
    assert_refused(peek_plain(plain), 4);
    let no_k = serde_json::json!({"v": 1, "i": MSG, "u": REACTOR, "e": "👍"}).to_string().into_bytes();
    assert_refused(peek_plain(no_k), 4);
}

#[test]
fn a_reaction_envelope_of_another_version_is_refused() {
    for v in [serde_json::json!(2), serde_json::json!(0), serde_json::json!("1")] {
        let plain = serde_json::json!({"v": v, "k": "r", "i": MSG, "u": REACTOR, "e": "👍"}).to_string().into_bytes();
        assert_refused(peek_plain(plain), 4);
    }
}

#[test]
fn a_text_envelope_is_refused() {
    let plain = serde_json::json!({"v": 1, "i": MSG, "t": "hello there"}).to_string().into_bytes();
    assert_refused(peek_plain(plain), 4);
}

/// A good pre-key reaction message and Bob's pickle, for the argument checks.
fn good() -> (CString, CString) {
    let mut p = pair();
    let m = p.alice.encrypt(reaction(MSG, REACTOR, "👍")).unwrap();
    (c(&p.bob.pickle(KEY.to_vec()).unwrap()), b64(&m))
}

#[test]
fn a_bad_olm_type_is_a_bad_argument() {
    let (pickle, ct) = good();
    for t in [2, -1, 5] {
        assert_refused(peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &ct, t, 64), 1);
    }
}

#[test]
fn a_key_that_is_not_32_bytes_is_a_bad_argument() {
    let (pickle, ct) = good();
    assert_refused(peek_raw(&[7; 31], &pickle, &c(MSG), &c(REACTOR), &ct, 0, 64), 1);
    assert_refused(peek_raw(&[7; 33], &pickle, &c(MSG), &c(REACTOR), &ct, 0, 64), 1);
}

#[test]
fn non_utf8_ids_are_a_bad_argument() {
    let (pickle, ct) = good();
    let bad = CString::new(vec![0xff, 0xfe, b'a']).unwrap();
    assert_refused(peek_raw(&KEY, &pickle, &bad, &c(REACTOR), &ct, 0, 64), 1);
    assert_refused(peek_raw(&KEY, &pickle, &c(MSG), &bad, &ct, 0, 64), 1);
}

#[test]
fn null_pointers_are_a_bad_argument() {
    let (pickle, ct) = good();
    let (mid, rid) = (c(MSG), c(REACTOR));
    let mut buf = [0u8; 64];
    let mut len = 0usize;
    let n = std::ptr::null();
    let call = |k: *const u8, p, m, r, ct_p, out: *mut u8, out_len: *mut usize| unsafe {
        sis_peek_reaction_session(k, 32, p, m, r, ct_p, 0, out, 64, out_len)
    };
    let (k, p, m, r, t) = (KEY.as_ptr(), pickle.as_ptr(), mid.as_ptr(), rid.as_ptr(), ct.as_ptr());
    assert_eq!(call(std::ptr::null(), p, m, r, t, buf.as_mut_ptr(), &mut len), 1, "null key");
    assert_eq!(call(k, n, m, r, t, buf.as_mut_ptr(), &mut len), 1, "null pickle");
    assert_eq!(call(k, p, n, r, t, buf.as_mut_ptr(), &mut len), 1, "null message_id");
    assert_eq!(call(k, p, m, n, t, buf.as_mut_ptr(), &mut len), 1, "null reactor_id");
    assert_eq!(call(k, p, m, r, n, buf.as_mut_ptr(), &mut len), 1, "null ct");
    assert_eq!(call(k, p, m, r, t, std::ptr::null_mut(), &mut len), 1, "null out");
    assert_eq!(call(k, p, m, r, t, buf.as_mut_ptr(), std::ptr::null_mut()), 1, "null out_len");
    assert!(buf.iter().all(|&b| b == 0));
}

#[test]
fn a_wrong_key_or_pickle_is_rejected() {
    let (pickle, ct) = good();
    assert_refused(peek_raw(&[8; 32], &pickle, &c(MSG), &c(REACTOR), &ct, 0, 64), 2);
    assert_refused(peek_raw(&KEY, &c("not a pickle"), &c(MSG), &c(REACTOR), &ct, 0, 64), 2);
}

#[test]
fn a_message_from_another_session_cannot_be_decrypted() {
    let (pickle, _) = good();
    let mut other = pair();
    let m = other.alice.encrypt(reaction(MSG, REACTOR, "👍")).unwrap();
    assert_refused(peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &b64(&m), 0, 64), 3);
}

#[test]
fn an_out_buffer_too_small_for_the_emoji_is_code_5() {
    let (pickle, ct) = good();
    // "👍" is 4 UTF-8 bytes.
    assert_refused(peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &ct, 0, 3), 5);
    let fits = peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &ct, 0, 4);
    assert_eq!(fits.code, 0);
    assert_eq!(fits.text, "👍".as_bytes());
}

/// Peek a reaction with emoji `e` into a 128-byte buffer.
fn peek_emoji(e: &str) -> Out {
    let mut p = pair();
    let m = p.alice.encrypt(reaction(MSG, REACTOR, e)).unwrap();
    let pickle = c(&p.bob.pickle(KEY.to_vec()).unwrap());
    peek_raw(&KEY, &pickle, &c(MSG), &c(REACTOR), &b64(&m), 0, 128)
}

#[test]
fn an_empty_emoji_is_refused() {
    assert_refused(peek_emoji(""), 4);
}

#[test]
fn an_emoji_of_exactly_64_bytes_is_accepted() {
    let e = "👍".repeat(16);
    assert_eq!(e.len(), 64);
    let o = peek_emoji(&e);
    assert_eq!(o.code, 0);
    assert_eq!(o.text, e.as_bytes());
}

#[test]
fn an_emoji_of_65_bytes_is_refused() {
    let e = format!("{}a", "👍".repeat(16));
    assert_eq!(e.len(), 65);
    assert_refused(peek_emoji(&e), 4);
}
