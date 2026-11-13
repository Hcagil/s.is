// rust/src/admin_view_pad_tests.rs
#[cfg(test)]
mod admin_view_pad_tests {
    use crate::api::admin_view_crypto::admin_view_open;
    use chacha20poly1305::aead::{Aead, Payload};
    use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
    use hkdf::Hkdf;
    use sha2::Sha256;
    use x25519_dalek::{x25519, X25519_BASEPOINT_BYTES};

    const PHONE_SECRET: [u8; 32] = [0xa8, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 0x41];
    const COMPUTER_SECRET: [u8; 32] = [0xb0, 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, 0x42];
    const EPHEMERAL_SECRET: [u8; 32] = [0xc8, 3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3, 0x43];

    fn compute_pub(secret: &[u8; 32]) -> [u8; 32] {
        x25519(*secret, X25519_BASEPOINT_BYTES)
    }

    fn compute_ikm(eph: &[u8; 32], r_pub: &[u8; 32]) -> [u8; 64] {
        let mut ikm = [0u8; 64];
        let a = x25519(*eph, *r_pub);
        let b = x25519(PHONE_SECRET, *r_pub);
        ikm[..32].copy_from_slice(&a);
        ikm[32..].copy_from_slice(&b);
        ikm
    }

    fn derive_key_nonce(e_pub: &[u8; 32], ikm: &[u8; 64], s_pub: &[u8; 32], r_pub: &[u8; 32]) -> ([u8; 32], [u8; 12]) {
        let mut okm = [0u8; 44];
        let mut info: Vec<u8> = b"sis-admin-view-v1|up|".to_vec();
        info.extend_from_slice(s_pub);
        info.extend_from_slice(r_pub);
        Hkdf::<Sha256>::new(Some(e_pub), ikm)
            .expand(&info, &mut okm)
            .expect("HKDF expand should succeed");
        let mut key = [0u8; 32];
        key.copy_from_slice(&okm[..32]);
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&okm[32..44]);
        (key, nonce)
    }

    fn build_aad() -> [u8; 16] {
        let mut aad = [0u8; 16];
        aad[0] = 0x01;
        aad[1..4].copy_from_slice(b"up|");
        aad[4..8].copy_from_slice(&1u32.to_be_bytes());
        aad[8..16].copy_from_slice(&7u64.to_be_bytes());
        aad
    }

    fn good_padded() -> Vec<u8> {
        let p = br#"{"t":"talk","text":"x"}"#.to_vec();
        let mut padded = Vec::with_capacity(1024);
        padded.extend_from_slice(&(p.len() as u32).to_be_bytes());
        padded.extend_from_slice(&p);
        padded.resize(1024, 0);
        padded
    }

    fn wire_for(padded: &[u8]) -> Vec<u8> {
        let s_pub = compute_pub(&PHONE_SECRET);
        let r_pub = compute_pub(&COMPUTER_SECRET);
        let e_pub = compute_pub(&EPHEMERAL_SECRET);
        let ikm = compute_ikm(&EPHEMERAL_SECRET, &r_pub);
        let (key, nonce_arr) = derive_key_nonce(&e_pub, &ikm, &s_pub, &r_pub);
        let cipher = ChaCha20Poly1305::new_from_slice(&key).expect("key length ok");
        let nonce = Nonce::from(nonce_arr);
        let aad = build_aad();
        let ciphertext = cipher
            .encrypt(&nonce, Payload { msg: padded, aad: &aad })
            .expect("encryption should succeed");
        let mut wire = Vec::with_capacity(1 + 32 + ciphertext.len());
        wire.push(0x01);
        wire.extend_from_slice(&e_pub);
        wire.extend_from_slice(&ciphertext);
        wire
    }

    #[test]
    fn helper_good_padding_opens() {
        let wire = wire_for(&good_padded());
        let res = admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire,
        );
        assert!(res.is_ok());
        assert_eq!(res.unwrap(), br#"{"t":"talk","text":"x"}"#.to_vec());
    }

    #[test]
    fn refuse_nonzero_pad_byte() {
        let mut padded = good_padded();
        let last = padded.len() - 1;
        padded[last] = 1;
        let wire = wire_for(&padded);
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire,
        ).is_err());

        let mut padded2 = good_padded();
        let idx = 4 + br#"{"t":"talk","text":"x"}"#.len();
        padded2[idx] = 1;
        let wire2 = wire_for(&padded2);
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire2,
        ).is_err());
    }

    #[test]
    fn refuse_length_prefix_too_big() {
        let mut padded = good_padded();
        padded[0..4].copy_from_slice(&1021u32.to_be_bytes());
        let wire = wire_for(&padded);
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire,
        ).is_err());

        let mut padded2 = good_padded();
        padded2[0..4].copy_from_slice(&0xFFFFFFFFu32.to_be_bytes());
        let wire2 = wire_for(&padded2);
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire2,
        ).is_err());
    }

    #[test]
    fn refuse_not_multiple_of_1024() {
        let open = |padded: Vec<u8>| admin_view_open(COMPUTER_SECRET.to_vec(), compute_pub(&PHONE_SECRET).to_vec(), 1, 1, 7, wire_for(&padded));
        let mut short = good_padded();
        short.truncate(1000);
        assert!(open(short).is_err());
        let mut long = good_padded();
        long.push(0);
        assert!(open(long).is_err());
    }

    #[test]
    fn refuse_empty_padded() {
        let wire = wire_for(&[]);
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire,
        ).is_err());
    }

    #[test]
    fn refuse_wrong_version_byte() {
        let mut wire = wire_for(&good_padded());
        wire[0] = 2;
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire,
        ).is_err());
    }

    #[test]
    fn accept_prefix_exactly_full() {
        let p2 = vec![b'a'; 1020];
        let mut padded = Vec::with_capacity(1024);
        padded.extend_from_slice(&(1020u32).to_be_bytes());
        padded.extend_from_slice(&p2);
        let wire = wire_for(&padded);
        let res = admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire,
        );
        assert!(res.is_ok());
        assert_eq!(res.unwrap(), p2);
    }

    #[test]
    fn accept_shorter_prefix_with_zero_pad() {
        let p = br#"{"t":"talk","text":"x"}"#.to_vec();
        let mut padded = Vec::with_capacity(1024);
        padded.extend_from_slice(&(p.len() as u32 - 1).to_be_bytes());
        padded.extend_from_slice(&p);
        padded.resize(1024, 0);
        let wire = wire_for(&padded);
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            compute_pub(&PHONE_SECRET).to_vec(),
            1,
            1,
            7,
            wire,
        ).is_err());
    }
}
