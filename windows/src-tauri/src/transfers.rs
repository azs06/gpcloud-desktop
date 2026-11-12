//! Upload / download queue with progress events (`transfer`) for the UI.
//!
//! Upload protocol (docs/API.md): hash locally → POST create-file-meta → PUT each slice to its
//! presigned storage URL → GET complete-status.

use crate::api::{ApiError, Cloud, CloudFile};
use crate::hashing::{self, PlanError};
use futures_util::{stream, StreamExt, TryStreamExt};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tokio::io::AsyncWriteExt;
use tokio::sync::Semaphore;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferEvent {
    pub id: String,
    pub name: String,
    pub kind: &'static str, // "upload" | "download"
    pub size: u64,
    /// queued | hashing | transferring | finishing | done | failed | cancelled
    pub status: &'static str,
    pub fraction: f64,
    pub message: Option<String>,
    pub local_path: Option<String>,
}

pub struct Transfers {
    app: AppHandle,
    cloud: Arc<Cloud>,
    cancel: Mutex<HashMap<String, Arc<AtomicBool>>>,
    uploads: Arc<Semaphore>,
    downloads: Arc<Semaphore>,
    reserved: Mutex<HashSet<PathBuf>>,
    cloud_user_id: tokio::sync::Mutex<Option<String>>,
}

struct Reporter {
    app: AppHandle,
    ev: Mutex<TransferEvent>,
    last: Mutex<Instant>,
}

impl Reporter {
    fn new(app: &AppHandle, name: String, kind: &'static str, size: u64, local: Option<String>) -> Arc<Self> {
        let r = Arc::new(Reporter {
            app: app.clone(),
            ev: Mutex::new(TransferEvent {
                id: uuid::Uuid::new_v4().to_string(),
                name, kind, size, status: "queued", fraction: 0.0, message: None, local_path: local,
            }),
            last: Mutex::new(Instant::now() - Duration::from_secs(1)),
        });
        r.emit(true);
        r
    }
    fn id(&self) -> String { self.ev.lock().unwrap().id.clone() }
    fn set(&self, status: &'static str, fraction: f64, message: Option<String>) {
        {
            let mut e = self.ev.lock().unwrap();
            e.status = status;
            e.fraction = fraction.clamp(0.0, 1.0);
            e.message = message;
        }
        // Throttle progress-only updates to ~10/s; state changes always go out.
        self.emit(!matches!(status, "hashing" | "transferring"));
    }
    fn emit(&self, force: bool) {
        let mut last = self.last.lock().unwrap();
        if !force && last.elapsed() < Duration::from_millis(100) { return; }
        *last = Instant::now();
        let _ = self.app.emit("transfer", self.ev.lock().unwrap().clone());
    }
}

impl Transfers {
    pub fn new(app: AppHandle, cloud: Arc<Cloud>) -> Self {
        Transfers {
            app, cloud,
            cancel: Mutex::new(HashMap::new()),
            uploads: Arc::new(Semaphore::new(2)),
            downloads: Arc::new(Semaphore::new(3)),
            reserved: Mutex::new(HashSet::new()),
            cloud_user_id: tokio::sync::Mutex::new(None),
        }
    }

    pub fn cancel(&self, id: &str) {
        if let Some(flag) = self.cancel.lock().unwrap().get(id) {
            flag.store(true, Ordering::SeqCst);
        }
    }

    pub fn cancel_all(&self) {
        for f in self.cancel.lock().unwrap().values() { f.store(true, Ordering::SeqCst); }
    }

    pub async fn reset(&self) {
        self.cancel_all();
        *self.cloud_user_id.lock().await = None;
    }

    fn register(&self, id: &str) -> Arc<AtomicBool> {
        let flag = Arc::new(AtomicBool::new(false));
        self.cancel.lock().unwrap().insert(id.to_string(), flag.clone());
        flag
    }

    fn unregister(&self, id: &str) { self.cancel.lock().unwrap().remove(id); }

    async fn user_id(&self) -> Result<String, ApiError> {
        let mut c = self.cloud_user_id.lock().await;
        if let Some(id) = c.clone() { return Ok(id); }
        let id = self.cloud.space().await?.cloud_user_id.ok_or_else(|| ApiError::Api("Couldn't read your cloud user id".into()))?;
        *c = Some(id.clone());
        Ok(id)
    }

    fn files_changed(&self, folder_id: &str) {
        let _ = self.app.emit("files-changed", folder_id.to_string());
    }

    // MARK: - Uploads

    /// Files and folders. Folders are recreated remotely (symlinks are skipped), then their files queued.
    pub fn upload(self: &Arc<Self>, paths: Vec<PathBuf>, folder_id: String) {
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            for p in paths { me.enqueue(p, folder_id.clone()).await; }
        });
    }

    fn enqueue(self: &Arc<Self>, path: PathBuf, folder_id: String) -> futures_util::future::BoxFuture<'static, ()> {
        let me = self.clone();
        Box::pin(async move {
            let Ok(meta) = std::fs::symlink_metadata(&path) else { return };
            if meta.file_type().is_symlink() { return; }
            let display = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if meta.is_dir() {
                match me.cloud.create_folder(&hashing::sanitize_name(&display), &folder_id).await {
                    Ok(Some(new_id)) => {
                        me.files_changed(&folder_id);
                        let mut children: Vec<PathBuf> = std::fs::read_dir(&path).map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).collect()).unwrap_or_default();
                        children.retain(|c| !c.file_name().map(|n| n.to_string_lossy().starts_with('.')).unwrap_or(true));
                        for c in children { me.enqueue(c, new_id.clone()).await; }
                    }
                    Ok(None) => {}
                    Err(e) => { Reporter::new(&me.app, display, "upload", 0, None).set("failed", 0.0, Some(e.to_string())); }
                }
                return;
            }
            let rep = Reporter::new(&me.app, display, "upload", meta.len(), Some(path.to_string_lossy().to_string()));
            let flag = me.register(&rep.id());
            let me2 = me.clone();
            tauri::async_runtime::spawn(async move {
                let _permit = me2.uploads.clone().acquire_owned().await;
                if flag.load(Ordering::SeqCst) {
                    rep.set("cancelled", 0.0, None);
                } else {
                    match me2.run_upload(&path, &folder_id, &rep, flag.clone()).await {
                        Ok(rapid) => { rep.set("done", 1.0, rapid.then(|| "Uploaded (instant)".to_string())); me2.files_changed(&folder_id); }
                        Err(_) if flag.load(Ordering::SeqCst) => rep.set("cancelled", 0.0, None),
                        Err(e) => rep.set("failed", 0.0, Some(e)),
                    }
                }
                me2.unregister(&rep.id());
            });
        })
    }

    async fn run_upload(&self, path: &Path, folder_id: &str, rep: &Arc<Reporter>, cancel: Arc<AtomicBool>) -> Result<bool, String> {
        let uid = self.user_id().await.map_err(|e| e.to_string())?;
        rep.set("hashing", 0.0, None);
        let (p, c, r) = (path.to_path_buf(), cancel.clone(), rep.clone());
        let plan = tauri::async_runtime::spawn_blocking(move || {
            hashing::make_plan(&p, &uid, &|| c.load(Ordering::SeqCst), &|f| r.set("hashing", f * 0.1, None))
        })
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| match e { PlanError::Cancelled => "Cancelled".to_string(), other => other.to_string() })?;

        let meta = self.cloud.create_file_meta(&plan, folder_id).await.map_err(|e| e.to_string())?;
        let file_id = meta.file_id.clone().ok_or("Server didn't return a file id")?;
        if meta.rapid_upload == Some(true) {
            rep.set("finishing", 0.99, None);
            let _ = self.cloud.complete_upload(&file_id).await;
            return Ok(true);
        }
        let mut parts = meta.multi_parts.unwrap_or_default();
        if parts.is_empty() { return Err(format!("Server didn't return upload slots for {}", plan.file_name)); }
        parts.sort_by_key(|p| p.part_number.unwrap_or(0));

        let total = plan.total_size.max(1);
        let sent = Arc::new(AtomicU64::new(0));
        let concurrency = if plan.slices.first().map(|s| s.size >= 50 * 1_048_576).unwrap_or(false) { 1 } else { 3 };
        let storage = self.cloud.storage_client();
        stream::iter(parts.into_iter().map(|part| {
            let (storage, sent, rep, cancel, path) = (storage.clone(), sent.clone(), rep.clone(), cancel.clone(), path.to_path_buf());
            async move { put_part(&storage, &path, part, sent, total, &rep, &cancel).await }
        }))
        .buffer_unordered(concurrency)
        .try_collect::<Vec<()>>()
        .await?;

        rep.set("finishing", 0.99, None);
        self.cloud.complete_upload(&file_id).await.map_err(|e| e.to_string())?;
        Ok(false)
    }

    // MARK: - Downloads

    pub fn download(self: &Arc<Self>, files: Vec<CloudFile>, dir: PathBuf) {
        for f in files.into_iter().filter(|f| !f.is_folder()) {
            let dest = self.unique_path(dir.join(&f.file_name));
            let rep = Reporter::new(&self.app, dest.file_name().unwrap().to_string_lossy().to_string(), "download", f.file_size.unwrap_or(0), Some(dest.to_string_lossy().to_string()));
            let flag = self.register(&rep.id());
            let me = self.clone();
            tauri::async_runtime::spawn(async move {
                let _permit = me.downloads.clone().acquire_owned().await;
                let result = if flag.load(Ordering::SeqCst) { Err("Cancelled".into()) } else { me.fetch_to(&f, &dest, Some(&rep), &flag).await };
                match result {
                    Ok(()) => rep.set("done", 1.0, None),
                    Err(_) if flag.load(Ordering::SeqCst) => rep.set("cancelled", 0.0, None),
                    Err(e) => rep.set("failed", 0.0, Some(e)),
                }
                me.reserved.lock().unwrap().remove(&dest);
                me.unregister(&rep.id());
            });
        }
    }

    /// Download into a cache folder (reused if present) and return the path, for "Open".
    pub async fn fetch_for_open(&self, file: &CloudFile, cache_root: &Path) -> Result<PathBuf, String> {
        let dir = cache_root.join(&file.id);
        let dest = dir.join(&file.file_name);
        if dest.exists() { return Ok(dest); }
        tokio::fs::create_dir_all(&dir).await.map_err(|e| e.to_string())?;
        self.fetch_to(file, &dest, None, &AtomicBool::new(false)).await?;
        Ok(dest)
    }

    async fn fetch_to(&self, file: &CloudFile, dest: &Path, rep: Option<&Arc<Reporter>>, cancel: &AtomicBool) -> Result<(), String> {
        // Presigned links expire, so get fresh ones right before downloading.
        let fresh = self.cloud.file(&file.id).await.map_err(|e| e.to_string())?;
        let url = fresh.content_url().or_else(|| file.content_url()).ok_or("No download link for this file")?;
        let res = self.cloud.storage_client().get(url).send().await.map_err(|e| e.to_string())?;
        if !res.status().is_success() { return Err(format!("Download failed (HTTP {})", res.status())); }
        let total = res.content_length().or(file.file_size).unwrap_or(0);
        let tmp = dest.with_extension(format!("{}gpcloud-part", dest.extension().map(|e| format!("{}.", e.to_string_lossy())).unwrap_or_default()));
        let mut out = tokio::fs::File::create(&tmp).await.map_err(|e| e.to_string())?;
        let mut got = 0u64;
        let mut body = res.bytes_stream();
        if let Some(r) = rep { r.set("transferring", 0.0, None); }
        while let Some(chunk) = body.next().await {
            if cancel.load(Ordering::SeqCst) {
                drop(out);
                let _ = tokio::fs::remove_file(&tmp).await;
                return Err("Cancelled".into());
            }
            let chunk = chunk.map_err(|e| e.to_string())?;
            out.write_all(&chunk).await.map_err(|e| e.to_string())?;
            got += chunk.len() as u64;
            if let (Some(r), true) = (rep, total > 0) { r.set("transferring", got as f64 / total as f64, None); }
        }
        out.flush().await.map_err(|e| e.to_string())?;
        drop(out);
        tokio::fs::rename(&tmp, dest).await.map_err(|e| e.to_string())
    }

    fn unique_path(&self, path: PathBuf) -> PathBuf {
        let mut reserved = self.reserved.lock().unwrap();
        let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let ext = path.extension().map(|e| e.to_string_lossy().to_string());
        let mut candidate = path.clone();
        let mut n = 2;
        while candidate.exists() || reserved.contains(&candidate) {
            let name = match &ext { Some(e) => format!("{stem} ({n}).{e}"), None => format!("{stem} ({n})") };
            candidate = path.with_file_name(name);
            n += 1;
        }
        reserved.insert(candidate.clone());
        candidate
    }
}

/// PUT one slice to its presigned URL with progress and retries.
async fn put_part(
    storage: &reqwest::Client,
    path: &Path,
    part: crate::api::MetaPart,
    sent: Arc<AtomicU64>,
    total: u64,
    rep: &Arc<Reporter>,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let (Some(url), Some(offset), Some(size)) = (part.upload_url, part.part_offset, part.part_size) else {
        return Err("Malformed upload slice from server".into());
    };
    let data = {
        use std::io::{Read, Seek, SeekFrom};
        let mut f = std::fs::File::open(path).map_err(|e| e.to_string())?;
        f.seek(SeekFrom::Start(offset)).map_err(|e| e.to_string())?;
        let mut v = vec![0u8; size as usize];
        f.read_exact(&mut v).map_err(|_| "File changed while uploading".to_string())?;
        bytes_from(v)
    };
    let mut last_err = String::from("Upload failed");
    for attempt in 0..4u64 {
        if cancel.load(Ordering::SeqCst) { return Err("Cancelled".into()); }
        if attempt > 0 { tokio::time::sleep(Duration::from_secs(attempt * attempt)).await; }
        let mine = Arc::new(AtomicU64::new(0));
        let chunks: Vec<Result<bytes::Bytes, std::io::Error>> =
            (0..data.len()).step_by(256 * 1024).map(|i| Ok(data.slice(i..(i + 256 * 1024).min(data.len())))).collect();
        let (sent2, mine2, rep2) = (sent.clone(), mine.clone(), rep.clone());
        let body = stream::iter(chunks).inspect(move |c| {
            if let Ok(c) = c {
                mine2.fetch_add(c.len() as u64, Ordering::Relaxed);
                let now = sent2.fetch_add(c.len() as u64, Ordering::Relaxed) + c.len() as u64;
                rep2.set("transferring", 0.1 + 0.88 * (now as f64 / total as f64), None);
            }
        });
        let res = storage
            .put(&url)
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", size)
            .body(reqwest::Body::wrap_stream(body))
            .send()
            .await;
        match res {
            Ok(r) if r.status().is_success() => return Ok(()),
            Ok(r) => {
                let code = r.status().as_u16();
                last_err = format!("Storage rejected slice (HTTP {code})");
                sent.fetch_sub(mine.load(Ordering::Relaxed), Ordering::Relaxed);
                if (400..500).contains(&code) && code != 408 && code != 429 { break; }
            }
            Err(e) => {
                last_err = e.to_string();
                sent.fetch_sub(mine.load(Ordering::Relaxed), Ordering::Relaxed);
            }
        }
    }
    Err(last_err)
}

fn bytes_from(v: Vec<u8>) -> bytes::Bytes {
    bytes::Bytes::from(v)
}
