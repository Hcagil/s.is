use flutter_rust_bridge::frb;

use vodozemac::olm::{Account, OlmMessage, Session, SessionConfig};
use vodozemac::{
    olm::{AccountPickle, SessionPickle},
    Curve25519PublicKey, Ed25519PublicKey, Ed25519Signature,
};

pub struct OlmAccount {
    inner: Account,
}

pub struct OlmSession {
    inner: Session,
}

pub struct OlmCiphertext {
    pub message_type: u32,
    pub body: Vec<u8>,
}

#[frb(non_opaque)]
pub struct OlmInbound {
    pub session: OlmSession,
    pub plaintext: Vec<u8>,
}

impl OlmAccount {
    #[frb(sync)]
    pub fn new() -> OlmAccount {
        OlmAccount {
            inner: Account::new(),
        }
    }

    #[frb(sync)]
    pub fn identity_key(&self) -> String {
        self.inner.curve25519_key().to_base64()
    }

    #[frb(sync)]
    pub fn ed25519_key(&self) -> String {
        self.inner.ed25519_key().to_base64()
    }

    #[frb(sync)]
    pub fn max_one_time_keys(&self) -> u32 {
        self.inner.max_number_of_one_time_keys() as u32
    }

    #[frb(sync)]
    pub fn stored_one_time_key_count(&self) -> u32 {
        self.inner.stored_one_time_key_count() as u32
    }

    #[frb(sync)]
    pub fn generate_one_time_keys(&mut self, count: u32) -> Vec<String> {
        self.inner
            .generate_one_time_keys(count as usize)
            .created
            .into_iter()
            .map(|k| k.to_base64())
            .collect()
    }

    #[frb(sync)]
    pub fn unpublished_one_time_keys(&self) -> Vec<String> {
        self.inner
            .one_time_keys()
            .values()
            .map(|k| k.to_base64())
            .collect()
    }

    #[frb(sync)]
    pub fn generate_fallback_key(&mut self) {
        self.inner.generate_fallback_key();
    }

    #[frb(sync)]
    pub fn unpublished_fallback_key(&self) -> Option<String> {
        self.inner
            .fallback_key()
            .values()
            .next()
            .map(|k| k.to_base64())
    }

    #[frb(sync)]
    pub fn forget_fallback_key(&mut self) -> bool {
        self.inner.forget_fallback_key()
    }

    #[frb(sync)]
    pub fn mark_keys_as_published(&mut self) {
        self.inner.mark_keys_as_published();
    }

    #[frb(sync)]
    pub fn sign(&self, message: String) -> String {
        self.inner.sign(message.as_bytes()).to_base64()
    }

    #[frb(sync)]
    pub fn pickle(&self, key: Vec<u8>) -> Result<String, String> {
        if key.len() != 32 {
            return Err("invalid key length".to_string());
        }
        let k = <[u8; 32]>::try_from(key.as_slice()).unwrap();
        Ok(self.inner.pickle().encrypt(&k))
    }

    #[frb(sync)]
    pub fn from_pickle(pickle: String, mut key: Vec<u8>) -> Result<OlmAccount, String> {
        if key.len() != 32 {
            crate::c_api::wipe(&mut key);
            return Err("invalid key length".to_string());
        }
        let mut k = <[u8; 32]>::try_from(key.as_slice()).unwrap();
        let decoded = AccountPickle::from_encrypted(&pickle, &k);
        crate::c_api::wipe(&mut k);
        crate::c_api::wipe(&mut key);
        let p = decoded.map_err(|_| "invalid pickle")?;
        Ok(OlmAccount {
            inner: Account::from_pickle(p),
        })
    }

    #[frb(sync)]
    pub fn generate_one_time_key(&mut self) -> Result<String, String> {
        let result = self.inner.generate_one_time_keys(1);
        match result.created.first() {
            Some(key) => Ok(key.to_base64()),
            None => Err("No key generated".to_string()),
        }
    }

    #[frb(sync)]
    pub fn create_outbound_session(
        &self,
        their_identity_key: String,
        their_one_time_key: String,
    ) -> Result<OlmSession, String> {
        let identity_key =
            Curve25519PublicKey::from_base64(&their_identity_key).map_err(|e| e.to_string())?;
        let one_time_key =
            Curve25519PublicKey::from_base64(&their_one_time_key).map_err(|e| e.to_string())?;
        let session = self
            .inner
            .create_outbound_session(SessionConfig::version_1(), identity_key, one_time_key)
            .map_err(|e| e.to_string())?;
        Ok(OlmSession { inner: session })
    }

    #[frb(sync)]
    pub fn create_inbound_session(
        &mut self,
        their_identity_key: String,
        message: OlmCiphertext,
    ) -> Result<OlmInbound, String> {
        let identity_key =
            Curve25519PublicKey::from_base64(&their_identity_key).map_err(|e| e.to_string())?;
        let olm_message = OlmMessage::from_parts(message.message_type as usize, &message.body)
            .map_err(|e| e.to_string())?;
        match olm_message {
            OlmMessage::PreKey(pre_key_message) => {
                let result = self
                    .inner
                    .create_inbound_session(
                        SessionConfig::version_1(),
                        identity_key,
                        &pre_key_message,
                    )
                    .map_err(|e| e.to_string())?;
                Ok(OlmInbound {
                    session: OlmSession {
                        inner: result.session,
                    },
                    plaintext: result.plaintext,
                })
            }
            _ => Err("not a pre-key message".to_string()),
        }
    }
}

impl OlmSession {
    #[frb(sync)]
    pub fn session_id(&self) -> String {
        self.inner.session_id()
    }

    #[frb(sync)]
    pub fn encrypt(&mut self, plaintext: Vec<u8>) -> Result<OlmCiphertext, String> {
        let olm_message = self.inner.encrypt(&plaintext).map_err(|e| e.to_string())?;
        let (message_type, body) = olm_message.to_parts();
        Ok(OlmCiphertext {
            message_type: message_type as u32,
            body,
        })
    }

    #[frb(sync)]
    pub fn decrypt(&mut self, message: OlmCiphertext) -> Result<Vec<u8>, String> {
        let olm_message = OlmMessage::from_parts(message.message_type as usize, &message.body)
            .map_err(|e| e.to_string())?;
        self.inner.decrypt(&olm_message).map_err(|e| e.to_string())
    }

    #[frb(sync)]
    pub fn pickle(&self, key: Vec<u8>) -> Result<String, String> {
        if key.len() != 32 {
            return Err("invalid key length".to_string());
        }
        let k = <[u8; 32]>::try_from(key.as_slice()).unwrap();
        Ok(self.inner.pickle().encrypt(&k))
    }

    #[frb(sync)]
    pub fn from_pickle(pickle: String, mut key: Vec<u8>) -> Result<OlmSession, String> {
        if key.len() != 32 {
            crate::c_api::wipe(&mut key);
            return Err("invalid key length".to_string());
        }
        let mut k = <[u8; 32]>::try_from(key.as_slice()).unwrap();
        let decoded = SessionPickle::from_encrypted(&pickle, &k);
        crate::c_api::wipe(&mut k);
        crate::c_api::wipe(&mut key);
        let p = decoded.map_err(|_| "invalid pickle")?;
        Ok(OlmSession {
            inner: Session::from_pickle(p),
        })
    }
}

#[frb(sync)]
pub fn olm_verify(signing_key: String, message: String, signature: String) -> Result<(), String> {
    let key = Ed25519PublicKey::from_base64(&signing_key).map_err(|_| "invalid signature")?;
    let sig = Ed25519Signature::from_base64(&signature).map_err(|_| "invalid signature")?;
    key.verify(message.as_bytes(), &sig)
        .map_err(|_| "invalid signature".to_string())
}

#[frb(sync)]
pub fn olm_pre_key_session_id(message: OlmCiphertext) -> Result<String, String> {
    match OlmMessage::from_parts(message.message_type as usize, &message.body)
        .map_err(|e| e.to_string())?
    {
        OlmMessage::PreKey(m) => Ok(m.session_id()),
        _ => Err("not a pre-key message".to_string()),
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Trace logs only in debug builds; release keeps Warn so nothing sensitive reaches logcat/oslog.
    flutter_rust_bridge::setup_log_to_console(if cfg!(debug_assertions) {
        log::LevelFilter::Trace
    } else {
        log::LevelFilter::Warn
    });
    flutter_rust_bridge::setup_backtrace();
}
