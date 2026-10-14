use flutter_rust_bridge::frb;

use vodozemac::olm::{Account, OlmMessage, Session, SessionConfig};
use vodozemac::Curve25519PublicKey;

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
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
