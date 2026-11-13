use sha2::Digest;
use chacha20poly1305::aead::Aead;
use chacha20poly1305::KeyInit;
use flutter_rust_bridge::frb;

#[allow(dead_code)]
fn dir_name(dir: u8) -> Result<&'static [u8], String> {
    match dir {
        0 => Ok(b"down"),
        1 => Ok(b"up"),
        _ => Err("invalid request".to_string()),
    }
}

#[allow(dead_code)]
fn to32(v: &[u8]) -> Result<[u8; 32], String> {
    if v.len() == 32 {
        let mut arr = [0u8; 32];
        arr.copy_from_slice(v);
        Ok(arr)
    } else {
        Err("invalid key length".to_string())
    }
}

#[allow(dead_code)]
fn build_aad(dirname: &[u8], epoch: u32, seq: u64) -> Vec<u8> {
    let mut aad = Vec::with_capacity(1 + dirname.len() + 1 + 4 + 8);
    aad.push(0x01);
    aad.extend_from_slice(dirname);
    aad.push(0x7C);
    aad.extend_from_slice(&epoch.to_be_bytes());
    aad.extend_from_slice(&seq.to_be_bytes());
    aad
}

#[allow(dead_code)]
fn pad(plaintext: &[u8], dirname: &[u8]) -> Result<Vec<u8>, String> {
    let max_len = if dirname == b"down" { 65536 } else { 8192 };
    let data_len = 4 + plaintext.len();
    let block_size = 1024;
    let total_len = if data_len % block_size == 0 {
        data_len
    } else {
        (data_len / block_size + 1) * block_size
    };

    if total_len > max_len {
        return Err("invalid request".to_string());
    }

    let mut padded = Vec::with_capacity(total_len);
    padded.extend_from_slice(&(plaintext.len() as u32).to_be_bytes());
    padded.extend_from_slice(plaintext);
    let zeros = total_len - padded.len();
    padded.extend(vec![0u8; zeros]);
    Ok(padded)
}

#[allow(dead_code)]
fn unpad(padded: &[u8]) -> Option<Vec<u8>> {
    if padded.len() < 4 {
        return None;
    }
    let l = u32::from_be_bytes([padded[0], padded[1], padded[2], padded[3]]) as usize;
    if l > padded.len() - 4 {
        return None;
    }
    let end = 4 + l;
    if padded[end..].iter().any(|&b| b != 0) {
        return None;
    }
    Some(padded[4..end].to_vec())
}

#[allow(dead_code)]
fn dh_ikm(a: [u8; 32], b: [u8; 32], c: [u8; 32], d: [u8; 32]) -> Option<[u8; 64]> {
    let ab = x25519_dalek::x25519(a, b);
    let cd = x25519_dalek::x25519(c, d);
    if ab == [0u8; 32] || cd == [0u8; 32] {
        return None;
    }
    let mut ikm = [0u8; 64];
    ikm[..32].copy_from_slice(&ab);
    ikm[32..].copy_from_slice(&cd);
    Some(ikm)
}

#[allow(dead_code)]
fn derive(
    ikm: &[u8; 64],
    e_pub: &[u8; 32],
    dirname: &[u8],
    s_pub: &[u8; 32],
    r_pub: &[u8; 32],
) -> Option<([u8; 32], [u8; 12])> {
    let salt = e_pub;
    let mut info = Vec::with_capacity(16 + dirname.len() + 1 + 32 + 32);
    info.extend_from_slice(b"sis-admin-view-v1|");
    info.extend_from_slice(dirname);
    info.push(b'|');
    info.extend_from_slice(s_pub);
    info.extend_from_slice(r_pub);

    let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(Some(salt), ikm);
    let mut okm = [0u8; 44];
    hkdf.expand(&info, &mut okm).ok()?;

    let mut key = [0u8; 32];
    let mut nonce = [0u8; 12];
    key.copy_from_slice(&okm[..32]);
    nonce.copy_from_slice(&okm[32..]);
    Some((key, nonce))
}

#[frb(non_opaque)]
pub struct AdminViewKeyPair {
    pub secret: Vec<u8>,
    pub public: Vec<u8>,
}

#[frb(sync)]
pub fn admin_view_generate_keypair() -> Result<AdminViewKeyPair, String> {
    let mut secret = [0u8; 32];
    getrandom::fill(&mut secret).map_err(|_| "random failed".to_string())?;
    let public = x25519_dalek::x25519(secret, x25519_dalek::X25519_BASEPOINT_BYTES);
    Ok(AdminViewKeyPair {
        secret: secret.to_vec(),
        public: public.to_vec(),
    })
}

#[frb(sync)]
pub fn admin_view_public_key(secret: Vec<u8>) -> Result<Vec<u8>, String> {
    let secret_arr = to32(&secret)?;
    let public = x25519_dalek::x25519(secret_arr, x25519_dalek::X25519_BASEPOINT_BYTES);
    Ok(public.to_vec())
}

#[frb(sync)]
pub fn admin_view_seal(
    my_secret: Vec<u8>,
    peer_public: Vec<u8>,
    dir: u8,
    epoch: u32,
    seq: u64,
    plaintext: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let my_secret_arr = to32(&my_secret)?;
    let peer_public_arr = to32(&peer_public)?;
    let mut eph_secret = [0u8; 32];
    getrandom::fill(&mut eph_secret).map_err(|_| "random failed".to_string())?;
    admin_view_seal_with_ephemeral(
        my_secret_arr,
        peer_public_arr,
        eph_secret,
        dir,
        epoch,
        seq,
        &plaintext,
    )
}

#[frb(ignore)]
pub fn admin_view_seal_with_ephemeral(
    my_secret: [u8; 32],
    peer_public: [u8; 32],
    eph_secret: [u8; 32],
    dir: u8,
    epoch: u32,
    seq: u64,
    plaintext: &[u8],
) -> Result<Vec<u8>, String> {
    let dirname = dir_name(dir)?;
    let s_pub = x25519_dalek::x25519(my_secret, x25519_dalek::X25519_BASEPOINT_BYTES);
    let e_pub = x25519_dalek::x25519(eph_secret, x25519_dalek::X25519_BASEPOINT_BYTES);
    let ikm = dh_ikm(eph_secret, peer_public, my_secret, peer_public).ok_or("invalid request".to_string())?;
    let (key, nonce) = derive(&ikm, &e_pub, dirname, &s_pub, &peer_public).ok_or("invalid request".to_string())?;
    let padded = pad(plaintext, dirname)?;
    let aad = build_aad(dirname, epoch, seq);
    let cipher = chacha20poly1305::ChaCha20Poly1305::new_from_slice(&key).map_err(|_| "invalid request".to_string())?;
    let nonce_obj = chacha20poly1305::Nonce::from(nonce);
    let ciphertext = cipher
        .encrypt(&nonce_obj, chacha20poly1305::aead::Payload { msg: &padded, aad: &aad })
        .map_err(|_| "invalid request".to_string())?;
    let mut wire = Vec::with_capacity(1 + 32 + ciphertext.len());
    wire.push(0x01);
    wire.extend_from_slice(&e_pub);
    wire.extend_from_slice(&ciphertext);
    Ok(wire)
}

#[frb(sync)]
pub fn admin_view_open(
    my_secret: Vec<u8>,
    peer_public: Vec<u8>,
    dir: u8,
    epoch: u32,
    seq: u64,
    wire: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let result = admin_view_open_inner(my_secret, peer_public, dir, epoch, seq, &wire);
    result.ok_or("invalid message".to_string())
}

fn admin_view_open_inner(
    my_secret: Vec<u8>,
    peer_public: Vec<u8>,
    dir: u8,
    epoch: u32,
    seq: u64,
    wire: &[u8],
) -> Option<Vec<u8>> {
    let my_secret_arr = to32(&my_secret).ok()?;
    let peer_public_arr = to32(&peer_public).ok()?;
    let dirname = dir_name(dir).ok()?;
    if wire.is_empty() || wire[0] != 0x01 {
        return None;
    }
    if wire.len() < 1073 {
        return None;
    }
    if (wire.len() - 49) % 1024 != 0 {
        return None;
    }
    let e_pub: [u8; 32] = wire[1..33].try_into().ok()?;
    let r_pub = x25519_dalek::x25519(my_secret_arr, x25519_dalek::X25519_BASEPOINT_BYTES);
    let ikm = dh_ikm(my_secret_arr, e_pub, my_secret_arr, peer_public_arr)?;
    let (key, nonce) = derive(&ikm, &e_pub, dirname, &peer_public_arr, &r_pub)?;
    let cipher = chacha20poly1305::ChaCha20Poly1305::new_from_slice(&key).ok()?;
    let nonce_obj = chacha20poly1305::Nonce::from(nonce);
    let aad = build_aad(dirname, epoch, seq);
    let padded = cipher
        .decrypt(&nonce_obj, chacha20poly1305::aead::Payload { msg: &wire[33..], aad: &aad })
        .ok()?;
    unpad(&padded)
}

#[frb(sync)]
pub fn admin_view_code(phone_public: Vec<u8>, computer_public: Vec<u8>) -> Result<String, String> {
    let phone_arr = to32(&phone_public)?;
    let computer_arr = to32(&computer_public)?;
    let phone_digits = digits30(&phone_arr, b"phone");
    let computer_digits = digits30(&computer_arr, b"computer");
    Ok(format!("{}{}", phone_digits, computer_digits))
}

fn digits30(public: &[u8; 32], role: &[u8]) -> String {
    let mut h = Vec::with_capacity(34);
    h.push(0x00);
    h.push(0x01);
    h.extend_from_slice(public);
    h.extend_from_slice(role);

    let mut hasher = sha2::Sha512::new();
    for _ in 0..5200 {
        hasher.update(&h);
        hasher.update(public);
        h = hasher.finalize_reset().to_vec();
        hasher = sha2::Sha512::new();
    }

    let mut result = String::with_capacity(30);
    for c in (0..30).step_by(5) {
        let mut v: u64 = 0;
        for j in 0..5 {
            v = v * 256 + h[c + j] as u64;
        }
        result.push_str(&format!("{:05}", v % 100000));
    }
    result
}
