// Plain C entry that the iPhone notification extension (Swift) will call later.
use crate::api::olm::{OlmAccount, OlmCiphertext};

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
