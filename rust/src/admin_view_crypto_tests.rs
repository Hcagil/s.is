// rust/src/admin_view_crypto_tests.rs
use crate::api::admin_view_crypto::*;
use sha2::{Sha256, Digest};


fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

const PHONE_SECRET: [u8; 32] = [
    0xa8, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x41,
];
const COMPUTER_SECRET: [u8; 32] = [
    0xb0, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x42,
];
const EPH_SECRET: [u8; 32] = [
    0xc8, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x43,
];
const PHONE_PUBLIC: [u8; 32] = [
    0x57, 0x75, 0xdb, 0xf4, 0xab, 0x8e, 0x43, 0xab,
    0xc3, 0xee, 0x04, 0x82, 0xab, 0x49, 0x00, 0x37,
    0xf0, 0x41, 0x55, 0x0f, 0x16, 0x91, 0x17, 0xfc,
    0xad, 0xd0, 0x5f, 0xb8, 0x7a, 0xfc, 0x99, 0x3c,
];
const COMPUTER_PUBLIC: [u8; 32] = [
    0x67, 0x32, 0x75, 0x96, 0x46, 0xba, 0x9a, 0x0d,
    0x21, 0x62, 0xa0, 0xcc, 0xb7, 0x34, 0xdb, 0x91,
    0xff, 0x00, 0xb3, 0xcb, 0x35, 0x78, 0x14, 0x18,
    0x76, 0x5b, 0xdd, 0x13, 0xeb, 0x2d, 0xbb, 0x0b,
];
const E_PUB: [u8; 32] = [
    0x49, 0xa8, 0x4f, 0xd3, 0xd8, 0x09, 0x11, 0x6e,
    0xf4, 0x1c, 0x70, 0x11, 0xeb, 0xac, 0x15, 0xa4,
    0x9a, 0x1a, 0x40, 0x55, 0xaa, 0xe1, 0x37, 0xb0,
    0xe1, 0xb8, 0xd1, 0xae, 0x44, 0x26, 0x73, 0x05,
];
const PLAINTEXT: &[u8] = br#"{"t":"talk","text":"hello admin view"}"#;
const EXPECTED_SHA256: &str =
    "d4c47596cb85e1aa92024d31517eef7e5687b08b2febd3d8cb7c19b47587221f";
const EXPECTED_CODE: &str =
    "670024231898301849690996553600626420165697521047996232663810";

#[test]
fn vector_wire_matches() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    assert_eq!(wire.len(), 1073);
    assert_eq!(wire[0], 0x01);
    assert_eq!(&wire[1..33], &E_PUB);
    let hash = Sha256::digest(&wire);
    assert_eq!(hex(&hash), EXPECTED_SHA256);
}

#[test]
fn vector_opens_on_computer_side() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    let plain = admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        1,
        7,
        wire,
    )
    .expect("open failed");
    assert_eq!(plain, PLAINTEXT);
}

#[test]
fn vector_code() {
    let code = admin_view_code(
        PHONE_PUBLIC.to_vec(),
        COMPUTER_PUBLIC.to_vec(),
    )
    .expect("code failed");
    assert_eq!(code, EXPECTED_CODE);
    assert_eq!(code.len(), 60);
    assert!(code.chars().all(|c| c.is_ascii_digit()));
    let swapped = admin_view_code(
        COMPUTER_PUBLIC.to_vec(),
        PHONE_PUBLIC.to_vec(),
    )
    .expect("code failed");
    assert_ne!(code, swapped);
}

#[test]
fn refuse_flipped_bit() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    let indices = [0usize, 1, 40, 1072];
    for &idx in &indices {
        let mut bad = wire.clone();
        bad[idx] ^= 0x01;
        assert!(admin_view_open(
            COMPUTER_SECRET.to_vec(),
            PHONE_PUBLIC.to_vec(),
            1,
            1,
            7,
            bad
        )
        .is_err());
    }
}

#[test]
fn refuse_wrong_dir() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        0,
        1,
        7,
        wire.clone()
    )
    .is_err());
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        2,
        1,
        7,
        wire.clone()
    )
    .is_err());
    assert!(admin_view_seal(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        2,
        1,
        7,
        PLAINTEXT.to_vec()
    )
    .is_err());
}

#[test]
fn refuse_wrong_seq() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        1,
        6,
        wire.clone()
    )
    .is_err());
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        1,
        8,
        wire.clone()
    )
    .is_err());
}

#[test]
fn refuse_wrong_epoch() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        0,
        7,
        wire.clone()
    )
    .is_err());
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        2,
        7,
        wire.clone()
    )
    .is_err());
}

#[test]
fn refuse_wrong_keys() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    // swapped roles
    assert!(admin_view_open(
        PHONE_SECRET.to_vec(),
        COMPUTER_PUBLIC.to_vec(),
        1,
        1,
        7,
        wire.clone()
    )
    .is_err());
    // third key pair
    let third = admin_view_generate_keypair().expect("gen");
    assert!(admin_view_open(
        third.secret.clone(),
        third.public.clone(),
        1,
        1,
        7,
        wire.clone()
    )
    .is_err());
}

#[test]
fn refuse_low_order_point() {
    let bad_peer = [0u8; 32];
    assert!(admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        bad_peer,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT
    )
    .is_err());
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        bad_peer.to_vec(),
        1,
        1,
        7,
        wire.clone()
    )
    .is_err());
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        vec![0u8; 31],
        1,
        1,
        7,
        wire.clone()
    )
    .is_err());
}

#[test]
fn refuse_truncated_and_empty() {
    let wire = admin_view_seal_with_ephemeral(
        PHONE_SECRET,
        COMPUTER_PUBLIC,
        EPH_SECRET,
        1,
        1,
        7,
        PLAINTEXT,
    )
    .expect("seal failed");
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        1,
        7,
        wire[..1072].to_vec()
    )
    .is_err());
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        1,
        7,
        wire[..1].to_vec()
    )
    .is_err());
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        1,
        7,
        Vec::new()
    )
    .is_err());
    assert!(admin_view_open(
        COMPUTER_SECRET.to_vec(),
        PHONE_PUBLIC.to_vec(),
        1,
        1,
        7,
        [wire.clone(), vec![0u8]].concat()
    )
    .is_err());
}

#[test]
fn random_roundtrip() {
    let a = admin_view_generate_keypair().expect("gen a");
    let b = admin_view_generate_keypair().expect("gen b");
    let wire = admin_view_seal(
        a.secret.clone(),
        b.public.clone(),
        0,
        3,
        1,
        b"hi".to_vec(),
    )
    .expect("seal");
    assert_eq!(wire.len(), 1073);
    let plain = admin_view_open(
        b.secret.clone(),
        a.public.clone(),
        0,
        3,
        1,
        wire.clone(),
    )
    .expect("open");
    assert_eq!(plain, b"hi".to_vec());
    let wire2 = admin_view_seal(
        a.secret.clone(),
        b.public.clone(),
        0,
        3,
        1,
        b"hi".to_vec(),
    )
    .expect("seal2");
    assert_ne!(wire, wire2);
    assert_eq!(
        admin_view_public_key(a.secret.clone()).expect("pub"),
        a.public.clone()
    );
}

#[test]
fn padding_sizes() {
    let a = admin_view_generate_keypair().expect("gen");
    let b = admin_view_generate_keypair().expect("gen");
    let plain1020 = vec![0u8; 1020];
    let wire1020 = admin_view_seal(
        a.secret.clone(),
        b.public.clone(),
        0,
        1,
        1,
        plain1020.clone(),
    )
    .expect("seal1020");
    assert_eq!(wire1020.len(), 49 + 1024);
    let plain1021 = vec![0u8; 1021];
    let wire1021 = admin_view_seal(
        a.secret.clone(),
        b.public.clone(),
        0,
        1,
        1,
        plain1021.clone(),
    )
    .expect("seal1021");
    assert_eq!(wire1021.len(), 49 + 2048);
    let empty = Vec::<u8>::new();
    let wire_empty = admin_view_seal(
        a.secret.clone(),
        b.public.clone(),
        0,
        1,
        1,
        empty.clone(),
    )
    .expect("seal empty");
    assert_eq!(wire_empty.len(), 1073);
    let opened = admin_view_open(
        b.secret.clone(),
        a.public.clone(),
        0,
        1,
        1,
        wire_empty,
    )
    .expect("open empty");
    assert!(opened.is_empty());
}
