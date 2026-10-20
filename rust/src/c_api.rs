// Plain C entry that the iPhone notification extension (Swift) will call later.
use crate::api::olm::{olm_pre_key_session_id, OlmAccount, OlmCiphertext, OlmSession};

/// Olm round trip through the same wrapper Dart uses: returns 0 when "hi" encrypted by one account decrypts on another, else the number of the failing step (1..5).
#[no_mangle]
pub extern "C" fn sis_olm_selftest() -> i32 {
    let alice = OlmAccount::new();
    let mut bob = OlmAccount::new();

    let otk = match bob.generate_one_time_key() {
        Ok(key) => key,
        Err(_) => return 1,
    };
    let mut session = match alice.create_outbound_session(bob.identity_key(), otk) {
        Ok(s) => s,
        Err(_) => return 2,
    };
    let ciphertext: OlmCiphertext = match session.encrypt(b"hi".to_vec()) {
        Ok(c) => c,
        Err(_) => return 3,
    };
    let inbound = match bob.create_inbound_session(alice.identity_key(), ciphertext) {
        Ok(i) => i,
        Err(_) => return 4,
    };
    if inbound.plaintext != b"hi" {
        return 5;
    }
    0
}

/// Wipe the buffer by overwriting it with zeros.
fn wipe(buf: &mut [u8]) {
    for i in buf.iter_mut() {
        unsafe { std::ptr::write_volatile(i, 0); }
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// Convert a C string to an Option<&str>.
unsafe fn cstr<'a>(p: *const std::os::raw::c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        std::ffi::CStr::from_ptr(p).to_str().ok()
    }
}

/// Extract the "t" field from a JSON envelope.
fn envelope_text(plaintext: &[u8], message_id: &str) -> Option<String> {
    let json: serde_json::Value = serde_json::from_slice(plaintext).ok()?;
    if let (Some(v), Some(i), Some(t)) = (
        json.get("v")?.as_i64(),
        json.get("i")?.as_str(),
        json.get("t")?.as_str()
    ) {
        if v == 1 && i == message_id {
            return Some(t.to_string());
        }
    }
    None
}

/// Finish processing a decrypted message.
fn finish(mut plain: Vec<u8>, message_id: &str, out: *mut u8, out_cap: usize, out_len: *mut usize) -> i32 {
    let text = envelope_text(&plain, message_id);
    wipe(&mut plain);
    let Some(text) = text else { return 4 };
    let mut bytes = text.into_bytes();
    if bytes.len() > out_cap {
        wipe(&mut bytes);
        return 5;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
        *out_len = bytes.len();
    }
    wipe(&mut bytes);
    0
}

/// Guard a function call to catch panics.
fn guarded(f: impl FnOnce() -> i32) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(6)
}

/// Session id inside a pre-key message (olm_type 0), written to out as UTF-8 (not NUL terminated). Codes above.
#[no_mangle]
pub unsafe extern "C" fn sis_peek_prekey_session_id(ct_b64: *const std::os::raw::c_char, olm_type: i32, out: *mut u8, out_cap: usize, out_len: *mut usize) -> i32 {
    guarded(|| {
        if olm_type != 0 {
            return 1;
        }
        if out.is_null() || out_len.is_null() {
            return 1;
        }
        let Some(ct_b64) = cstr(ct_b64) else { return 1 };
        let Ok(body) = vodozemac::base64_decode(ct_b64) else { return 1 };
        let result = olm_pre_key_session_id(OlmCiphertext { message_type: 0, body });
        let Ok(session_id) = result else { return 3 };
        let session_id_bytes = session_id.as_bytes();
        if session_id_bytes.len() > out_cap {
            return 5;
        }
        std::ptr::copy_nonoverlapping(session_id_bytes.as_ptr(), out, session_id_bytes.len());
        *out_len = session_id_bytes.len();
        0
    })
}

/// Decrypts an Olm message with a COPY of a stored session (the pickle) and returns the text of the envelope; nothing is saved anywhere.
#[no_mangle]
pub unsafe extern "C" fn sis_peek_session(key: *const u8, key_len: usize, pickle: *const std::os::raw::c_char, message_id: *const std::os::raw::c_char, ct_b64: *const std::os::raw::c_char, olm_type: i32, out: *mut u8, out_cap: usize, out_len: *mut usize) -> i32 {
    guarded(|| {
        if olm_type != 0 && olm_type != 1 {
            return 1;
        }
        if out.is_null() || out_len.is_null() || key.is_null() {
            return 1;
        }
        let Some(pickle) = cstr(pickle) else { return 1 };
        let Some(message_id) = cstr(message_id) else { return 1 };
        let Some(ct_b64) = cstr(ct_b64) else { return 1 };
        if key_len != 32 {
            return 1;
        }
        let mut key_vec = std::slice::from_raw_parts(key, key_len).to_vec();
        let mut body = match vodozemac::base64_decode(ct_b64) {
            Ok(b) => b,
            Err(_) => {
                wipe(&mut key_vec);
                return 1;
            }
        };
        let mut session = match OlmSession::from_pickle(pickle.to_string(), key_vec.clone()) {
            Ok(s) => s,
            Err(_) => {
                wipe(&mut key_vec);
                wipe(&mut body);
                return 2;
            }
        };
        wipe(&mut key_vec);
        let plain = match session.decrypt(OlmCiphertext { message_type: olm_type as u32, body }) {
            Ok(p) => p,
            Err(_) => return 3
        };
        finish(plain, message_id, out, out_cap, out_len)
    })
}

/// Pre-key message from a peer with no stored session: makes the inbound session on a COPY of the account (the pickle); nothing is saved anywhere.
#[no_mangle]
pub unsafe extern "C" fn sis_peek_inbound(key: *const u8, key_len: usize, account_pickle: *const std::os::raw::c_char, identity_key: *const std::os::raw::c_char, message_id: *const std::os::raw::c_char, ct_b64: *const std::os::raw::c_char, olm_type: i32, out: *mut u8, out_cap: usize, out_len: *mut usize) -> i32 {
    guarded(|| {
        if olm_type != 0 {
            return 1;
        }
        if out.is_null() || out_len.is_null() || key.is_null() {
            return 1;
        }
        let Some(account_pickle) = cstr(account_pickle) else { return 1 };
        let Some(identity_key) = cstr(identity_key) else { return 1 };
        let Some(message_id) = cstr(message_id) else { return 1 };
        let Some(ct_b64) = cstr(ct_b64) else { return 1 };
        if key_len != 32 {
            return 1;
        }
        let mut key_vec = std::slice::from_raw_parts(key, key_len).to_vec();
        let mut body = match vodozemac::base64_decode(ct_b64) {
            Ok(b) => b,
            Err(_) => {
                wipe(&mut key_vec);
                return 1;
            }
        };
        let mut account = match OlmAccount::from_pickle(account_pickle.to_string(), key_vec.clone()) {
            Ok(a) => a,
            Err(_) => {
                wipe(&mut key_vec);
                wipe(&mut body);
                return 2;
            }
        };
        wipe(&mut key_vec);
        let inbound = match account.create_inbound_session(identity_key.to_string(), OlmCiphertext { message_type: 0, body }) {
            Ok(i) => i,
            Err(_) => return 3
        };
        finish(inbound.plaintext, message_id, out, out_cap, out_len)
    })
}
