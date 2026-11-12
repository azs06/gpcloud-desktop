//! Upload math for GP Cloud's multipart protocol (see docs/API.md).
//!
//! Each slice sent to `create-file-meta` carries `hashCtx`: the eight SHA-256 chaining words
//! *before* that slice's bytes are hashed. Slice boundaries are multiples of 64 bytes, so the
//! midstate is exact. `sha2::compress256` gives direct access to the compression function.

use sha2::digest::generic_array::GenericArray;
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

pub const IV: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// Streaming SHA-256 with access to the internal state.
pub struct MidstateHasher {
    state: [u32; 8],
    buf: [u8; 64],
    buf_len: usize,
    total: u64,
}

impl Default for MidstateHasher {
    fn default() -> Self {
        Self { state: IV, buf: [0; 64], buf_len: 0, total: 0 }
    }
}

impl MidstateHasher {
    /// Chaining values after all complete 64-byte blocks fed so far.
    pub fn midstate(&self) -> [u32; 8] {
        self.state
    }

    pub fn update(&mut self, mut data: &[u8]) {
        self.total += data.len() as u64;
        if self.buf_len > 0 {
            let take = (64 - self.buf_len).min(data.len());
            self.buf[self.buf_len..self.buf_len + take].copy_from_slice(&data[..take]);
            self.buf_len += take;
            data = &data[take..];
            if self.buf_len == 64 {
                let block = self.buf;
                sha2::compress256(&mut self.state, &[GenericArray::clone_from_slice(&block)]);
                self.buf_len = 0;
            }
        }
        let whole = data.len() / 64 * 64;
        if whole > 0 {
            let blocks: Vec<GenericArray<u8, _>> =
                data[..whole].chunks_exact(64).map(GenericArray::clone_from_slice).collect();
            sha2::compress256(&mut self.state, &blocks);
        }
        let rest = &data[whole..];
        self.buf[..rest.len()].copy_from_slice(rest);
        self.buf_len = rest.len();
    }

    pub fn finalize(mut self) -> [u8; 32] {
        let bit_len = self.total.wrapping_mul(8);
        let mut pad = vec![0x80u8];
        let zeros = if self.buf_len < 56 { 55 - self.buf_len } else { 119 - self.buf_len };
        pad.extend(std::iter::repeat(0).take(zeros));
        pad.extend_from_slice(&bit_len.to_be_bytes());
        let total = self.total;
        self.update(&pad);
        self.total = total;
        debug_assert_eq!(self.buf_len, 0);
        let mut out = [0u8; 32];
        for (i, w) in self.state.iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&w.to_be_bytes());
        }
        out
    }
}

/// Slice size table from the Android app, rounded down to a multiple of 64 bytes.
pub fn slice_size(file_size: u64) -> u64 {
    const MB: u64 = 1_048_576;
    let chosen = match file_size {
        s if s <= 100 * MB => 5 * MB,
        s if s <= 500 * MB => 8 * MB,
        s if s <= 2048 * MB => 10 * MB,
        s if s <= 5120 * MB => 50 * MB,
        s if s <= 10240 * MB => 100 * MB,
        _ => 200 * MB,
    };
    file_size.min(chosen / 64 * 64)
}

/// proofCode = sha256(file[off .. off+8]) with off derived from sha256(hex(sha256(cloudUserId))).
pub fn proof_code(cloud_user_id: &str, file_size: u64, read_at: impl FnOnce(u64, usize) -> std::io::Result<Vec<u8>>) -> std::io::Result<String> {
    let seed = hex::encode(Sha256::digest(cloud_user_id.as_bytes()));
    let mut d: [u8; 32] = Sha256::digest(seed.as_bytes()).into();
    d[24] &= 0x7f;
    let mut off = i64::from_be_bytes(d[24..32].try_into().unwrap()) as u64;
    if off > file_size {
        off %= file_size;
    }
    let count = ((off + 8).min(file_size) - off) as usize;
    let sample = read_at(off, count)?;
    Ok(hex::encode(Sha256::digest(&sample)))
}

#[derive(Debug, Clone, PartialEq)]
pub struct Slice {
    pub part_number: u32,
    pub offset: u64,
    pub size: u64,
    pub hash_ctx: [u32; 8],
}

#[derive(Debug, Clone)]
pub struct UploadPlan {
    pub file_name: String,
    pub mime_type: String,
    pub file_type: String,
    pub total_size: u64,
    pub sha256: String,
    pub proof_code: String,
    pub slices: Vec<Slice>,
}

#[derive(Debug, thiserror::Error)]
pub enum PlanError {
    #[error("GP Cloud doesn't accept empty (0-byte) files.")]
    Empty,
    #[error("Cancelled")]
    Cancelled,
    #[error("Couldn't read the file: {0}")]
    Io(#[from] std::io::Error),
}

/// One pass over the file: whole-file SHA-256, per-slice midstates, and the proofCode.
pub fn make_plan(
    path: &Path,
    cloud_user_id: &str,
    is_cancelled: &dyn Fn() -> bool,
    progress: &dyn Fn(f64),
) -> Result<UploadPlan, PlanError> {
    let mut file = File::open(path)?;
    let size = file.metadata()?.len();
    if size == 0 {
        return Err(PlanError::Empty);
    }
    let slice = slice_size(size);
    let mut hasher = MidstateHasher::default();
    let mut slices = Vec::new();
    let mut buf = vec![0u8; 4 * 1_048_576]; // multiple of 64: slice edges always land on block edges
    let mut offset = 0u64;
    let mut part = 1u32;
    while offset < size {
        let this = slice.min(size - offset);
        slices.push(Slice { part_number: part, offset, size: this, hash_ctx: hasher.midstate() });
        let mut remaining = this;
        while remaining > 0 {
            if is_cancelled() {
                return Err(PlanError::Cancelled);
            }
            let want = remaining.min(buf.len() as u64) as usize;
            file.read_exact(&mut buf[..want])?;
            hasher.update(&buf[..want]);
            remaining -= want as u64;
            offset += want as u64;
            progress(offset as f64 / size as f64);
        }
        part += 1;
    }
    let sha = hex::encode(hasher.finalize());
    let proof = proof_code(cloud_user_id, size, |off, count| {
        file.seek(SeekFrom::Start(off))?;
        let mut v = vec![0u8; count];
        file.read_exact(&mut v)?;
        Ok(v)
    })?;

    let original = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    let mime = mime_guess::from_path(path).first_or_octet_stream().essence_str().to_string();
    Ok(UploadPlan {
        file_name: sanitize_name(&original),
        file_type: file_type(&mime, &ext).to_string(),
        mime_type: mime,
        total_size: size,
        sha256: sha,
        proof_code: proof,
        slices,
    })
}

pub fn file_type(mime: &str, ext: &str) -> &'static str {
    if mime.starts_with("image/") { return "PICTURE" }
    if mime.starts_with("video/") { return "VIDEO" }
    if mime.starts_with("audio/") { return "AUDIO" }
    match ext {
        "doc" | "docx" | "odt" | "rtf" => "WORD",
        "xls" | "xlsx" | "ods" | "csv" => "EXCEL",
        "ppt" | "pptx" | "odp" => "PPT",
        "zip" | "rar" | "7z" | "tar" | "gz" | "bz2" | "xz" => "ARCHIVE",
        "apk" | "exe" | "msi" | "dmg" | "pkg" => "APPLICATION",
        _ => "OTHER",
    }
}

const FORBIDDEN: &[char] = &['<', '>', '|', ':', '"', '*', '?', '/', '\\'];

/// Server rule: ^(?!\.{1,2}$)(?!.*[<>|:"*?\/\s]).{1,250}$
pub fn name_error(name: &str) -> Option<&'static str> {
    if name.is_empty() { return Some("Name can't be empty.") }
    if name == "." || name == ".." { return Some("Name can't be \".\" or \"..\".") }
    if name.chars().count() > 250 { return Some("Name must be 250 characters or fewer.") }
    if name.chars().any(char::is_whitespace) { return Some("GP Cloud doesn't allow spaces in names.") }
    if name.chars().any(|c| FORBIDDEN.contains(&c)) { return Some("Name can't contain < > | : \" * ? / \\") }
    None
}

/// Whitespace becomes "_", other forbidden characters are dropped.
pub fn sanitize_name(name: &str) -> String {
    let mut out: String = name
        .chars()
        .filter_map(|c| if c.is_whitespace() { Some('_') } else if FORBIDDEN.contains(&c) { None } else { Some(c) })
        .collect();
    if out.is_empty() || out == "." || out == ".." {
        out = "untitled".into();
    }
    if out.chars().count() > 250 {
        let p = Path::new(&out);
        let ext = p.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
        let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let keep = 250 - if ext.is_empty() { 0 } else { ext.chars().count() + 1 };
        out = stem.chars().take(keep.max(1)).collect::<String>() + &if ext.is_empty() { String::new() } else { format!(".{ext}") };
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digest_matches_sha2() {
        for size in [0usize, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 1000, 1_048_577] {
            let data: Vec<u8> = (0..size).map(|i| (i * 31 + 7) as u8).collect();
            let mut h = MidstateHasher::default();
            for chunk in data.chunks(777) { h.update(chunk); }
            assert_eq!(hex::encode(h.finalize()), hex::encode(Sha256::digest(&data)), "size {size}");
        }
    }

    #[test]
    fn known_midstate() {
        let mut h = MidstateHasher::default();
        assert_eq!(h.midstate(), IV);
        h.update(&[0u8; 64]);
        assert_eq!(h.midstate()[0], 0xda5698be);
    }

    #[test]
    fn slice_table() {
        const MB: u64 = 1_048_576;
        assert_eq!(slice_size(38), 38);
        assert_eq!(slice_size(6 * MB), 5 * MB);
        assert_eq!(slice_size(400 * MB), 8 * MB);
        assert_eq!(slice_size(3000 * MB), 50 * MB);
        assert_eq!(slice_size(20000 * MB), 200 * MB);
    }

    /// Same fixture as the macOS self-test, so both clients are checked against each other.
    #[test]
    fn plan_two_slices() {
        let size = 6 * 1_048_576 + 123;
        let data: Vec<u8> = (0..size).map(|i: usize| (i.wrapping_mul(31).wrapping_add(7)) as u8).collect();
        let dir = std::env::temp_dir().join(format!("gpcloud-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("gpcloud selftest.bin");
        std::fs::write(&path, &data).unwrap();
        let plan = make_plan(&path, "1234567890", &|| false, &|_| {}).unwrap();
        assert_eq!(plan.slices.len(), 2);
        assert_eq!(plan.slices[0].hash_ctx, IV);
        let mut r = MidstateHasher::default();
        r.update(&data[..5 * 1_048_576]);
        assert_eq!(plan.slices[1].hash_ctx, r.midstate());
        assert_eq!(plan.slices[1].offset, 5 * 1_048_576);
        assert_eq!(plan.slices[1].size, 1_048_576 + 123);
        assert_eq!(plan.sha256, hex::encode(Sha256::digest(&data)));
        assert_eq!(plan.file_name, "gpcloud_selftest.bin");
        // Golden values, identical to the macOS client's planner for this fixture
        // (the macOS upload path was verified against the live service).
        assert_eq!(plan.sha256, "5e180957ceb3deff212a1b78882555fd111f39c12a49fa82215c2bb5eacd0123");
        assert_eq!(plan.proof_code, "5c9dfbf8cb0cb800932c9aa2c4729c4f55ffa8768ef82ddcdc8cf60be3340f96");
        assert_eq!(plan.slices[1].hash_ctx, [3486211182, 1877963227, 3385071343, 140397954, 2202282557, 1027318033, 2944245752, 204843458]);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn names() {
        assert!(name_error("My Folder").is_some());
        assert!(name_error("My-Folder").is_none());
        assert_eq!(sanitize_name("a<b>c d?.txt"), "abc_d.txt");
    }
}
