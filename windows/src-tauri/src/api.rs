//! GP Cloud API client + session handling. Protocol notes: docs/API.md.
//!
//! Auth: the user signs in on gpcloud.grameenphone.com inside an embedded (private) webview.
//! We copy that site's NextAuth session cookie into our own cookie jar, then get bearer tokens
//! from `GET /api/auth/session`; NextAuth refreshes them server-side. The password never reaches
//! this code. The cookie is kept in the app's data folder so you stay signed in.

use crate::hashing::UploadPlan;
use reqwest::cookie::{CookieStore, Jar};
use reqwest::{Client, Method, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

pub const ORIGIN: &str = "https://gpcloud.grameenphone.com";
const GATEWAY: &str = "https://gpcloud.grameenphone.com/api/gateway";
const V1: &str = "/gpcloud/edge/api/v1";

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("You're signed out of GP Cloud.")]
    SignedOut,
    #[error("Couldn't reach GP Cloud. Check your connection. ({0})")]
    Network(String),
    #[error("{0}")]
    Api(String),
}

impl Serialize for ApiError {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

impl From<reqwest::Error> for ApiError {
    fn from(e: reqwest::Error) -> Self {
        ApiError::Network(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, ApiError>;

// MARK: - Models (camelCase both from the API and to the UI)

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadLink {
    pub usage: Option<String>,
    pub download_link: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudFile {
    pub id: String,
    pub file_name: String,
    pub file_type: Option<String>,
    pub file_suffix: Option<String>,
    pub mime_type: Option<String>,
    pub parent_folder: Option<Vec<String>>,
    pub file_size: Option<u64>,
    pub recycled: Option<bool>,
    pub favorite: Option<bool>,
    pub created_time: Option<String>,
    pub edited_time: Option<String>,
    pub download_links: Option<Vec<DownloadLink>>,
}

pub const FOLDER_MIME: &str = "application/vnd.huawei-apps.folder";

impl CloudFile {
    pub fn is_folder(&self) -> bool {
        self.mime_type.as_deref() == Some(FOLDER_MIME) || self.file_type.as_deref() == Some("FOLDER")
    }
    pub fn parent_id(&self) -> String {
        self.parent_folder.as_ref().and_then(|p| p.first().cloned()).unwrap_or_else(|| "root".into())
    }
    pub fn content_url(&self) -> Option<String> {
        self.download_links.as_ref()?.iter().find(|l| l.usage.as_deref() == Some("content"))?.download_link.clone()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SpaceInfo {
    pub cloud_user_id: Option<String>,
    pub capacity: Option<u64>,
    pub space_used: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub name: Option<String>,
    pub first_name: Option<String>,
    pub last_name: Option<String>,
    pub email: Option<String>,
    pub mobile_number: Option<String>,
    pub user_name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileList {
    files: Option<Vec<CloudFile>>,
    next_page_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaPart {
    pub part_number: Option<u32>,
    pub part_offset: Option<u64>,
    pub part_size: Option<u64>,
    pub upload_url: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileMeta {
    pub rapid_upload: Option<bool>,
    pub file_id: Option<String>,
    pub multi_parts: Option<Vec<MetaPart>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecentList {
    files: Option<Vec<RecentEntry>>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecentEntry {
    file_id: Option<String>,
    metadata: Option<RecentMeta>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecentMeta {
    file_id: Option<String>,
}

// MARK: - Client

struct TokenCache {
    token: Option<String>,
    expires: u64,
}

pub struct Cloud {
    http: RwLock<(Client, Arc<Jar>)>,
    session_file: PathBuf,
    token: Mutex<TokenCache>,
    device_id: String,
    root_id: Mutex<Option<String>>,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn origin_url() -> url::Url {
    url::Url::parse(ORIGIN).unwrap()
}

fn new_client(jar: Arc<Jar>) -> Client {
    Client::builder()
        .cookie_provider(jar)
        .timeout(Duration::from_secs(60))
        .user_agent(concat!("GPCloudDesktop/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("http client")
}

impl Cloud {
    pub fn new(data_dir: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&data_dir);
        let device_file = data_dir.join("device-id");
        let device_id = std::fs::read_to_string(&device_file).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                let id = uuid::Uuid::new_v4().to_string();
                let _ = std::fs::write(&device_file, &id);
                id
            });
        let jar = Arc::new(Jar::default());
        let session_file = data_dir.join("session");
        if let Ok(saved) = std::fs::read_to_string(&session_file) {
            add_cookie_header(&jar, saved.trim());
        }
        Cloud {
            http: RwLock::new((new_client(jar.clone()), jar)),
            session_file,
            token: Mutex::new(TokenCache { token: None, expires: 0 }),
            device_id,
            root_id: Mutex::new(None),
        }
    }

    fn client(&self) -> Client {
        self.http.read().unwrap().0.clone()
    }

    /// Cookies copied from the login webview (name, value).
    pub fn import_cookies(&self, cookies: &[(String, String)]) {
        let jar = self.http.read().unwrap().1.clone();
        let url = origin_url();
        for (name, value) in cookies {
            jar.add_cookie_str(&format!("{name}={value}; Domain=gpcloud.grameenphone.com; Path=/; Secure; HttpOnly"), &url);
        }
    }

    fn persist_session(&self) {
        let jar = self.http.read().unwrap().1.clone();
        if let Some(header) = jar.cookies(&origin_url()) {
            if let Ok(s) = header.to_str() {
                let _ = std::fs::write(&self.session_file, s);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(&self.session_file, std::fs::Permissions::from_mode(0o600));
                }
            }
        }
    }

    pub async fn sign_out(&self) {
        let jar = Arc::new(Jar::default());
        *self.http.write().unwrap() = (new_client(jar.clone()), jar);
        *self.token.lock().await = TokenCache { token: None, expires: 0 };
        *self.root_id.lock().await = None;
        let _ = std::fs::remove_file(&self.session_file);
    }

    /// Asks NextAuth for the current access token. SignedOut only when the session has none.
    pub async fn fetch_token(&self) -> Result<String> {
        let res = self.client().get(format!("{ORIGIN}/api/auth/session")).header("Cache-Control", "no-store").send().await?;
        if !res.status().is_success() {
            return Err(ApiError::Network(format!("HTTP {}", res.status())));
        }
        let v: Value = res.json().await.map_err(|e| ApiError::Network(e.to_string()))?;
        let token = match (v.get("error"), v.get("accessToken").and_then(Value::as_str)) {
            (None, Some(t)) if !t.is_empty() => t.to_string(),
            _ => return Err(ApiError::SignedOut),
        };
        let expires = jwt_exp(&token).unwrap_or(now() + 300);
        *self.token.lock().await = TokenCache { token: Some(token.clone()), expires };
        self.persist_session(); // NextAuth may have rotated the cookie
        Ok(token)
    }

    async fn access_token(&self, force: bool) -> Result<String> {
        {
            let c = self.token.lock().await;
            if !force {
                if let Some(t) = &c.token {
                    if c.expires > now() + 60 {
                        return Ok(t.clone());
                    }
                }
            }
        }
        self.fetch_token().await
    }

    // MARK: core request

    async fn send(&self, method: Method, path: &str, body: Option<Value>) -> Result<Value> {
        let url = format!("{GATEWAY}{path}");
        for attempt in 0..2 {
            let token = self.access_token(attempt > 0).await?;
            let mut req = self
                .client()
                .request(method.clone(), &url)
                .bearer_auth(&token)
                .header("Accept", "application/json")
                .header("X-APP-NAME", "GP Cloud")
                .header("X-APP-VERSION", "0.1.0")
                .header("X-APP-PACKAGE-NAME", "gpcloud.grameenphone.com")
                .header("X-DEVICE-ID", &self.device_id)
                .header("X-DEVICE-VENDOR", "Desktop")
                .header("X-DEVICE-MODEL", "GPCloud Desktop")
                .header("X-DEVICE-OS-VERSION", std::env::consts::OS);
            if let Some(b) = &body {
                req = req.json(b);
            }
            let res = req.send().await?;
            let status = res.status();
            if status == StatusCode::UNAUTHORIZED {
                if attempt == 0 {
                    continue;
                }
                // Still rejected after a fresh token: either the session is gone or the route isn't allowed.
                return match self.fetch_token().await {
                    Err(ApiError::SignedOut) => Err(ApiError::SignedOut),
                    _ => Err(ApiError::Api("GP Cloud rejected this request.".into())),
                };
            }
            let text = res.text().await?;
            let v: Value = serde_json::from_str(&text).map_err(|_| {
                ApiError::Api(format!("Unexpected response ({status}): {}", text.chars().take(200).collect::<String>()))
            })?;
            if v.get("success") == Some(&Value::Bool(false)) || !status.is_success() {
                let msg = v["errorMessages"][0]["message"].as_str().or(v["message"].as_str()).unwrap_or("Request failed");
                return Err(ApiError::Api(msg.to_string()));
            }
            return Ok(v);
        }
        Err(ApiError::SignedOut)
    }

    async fn data<T: serde::de::DeserializeOwned>(&self, method: Method, path: &str, body: Option<Value>) -> Result<T> {
        let v = self.send(method, path, body).await?;
        serde_json::from_value(v.get("data").cloned().unwrap_or(Value::Null)).map_err(|e| ApiError::Api(format!("Unexpected response: {e}")))
    }

    // MARK: account

    pub async fn space(&self) -> Result<SpaceInfo> {
        self.data(Method::GET, &format!("{V1}/profile/user-space-info/1"), None).await
    }
    pub async fn profile(&self) -> Result<Profile> {
        self.data(Method::GET, "/iam/edge/api/v1/users/profile", None).await
    }

    // MARK: browsing

    pub async fn file(&self, id: &str) -> Result<CloudFile> {
        self.data(Method::GET, &format!("{V1}/files/{id}"), None).await
    }

    async fn paged(&self, path: &str, mut make_body: impl FnMut(Option<&str>) -> Value) -> Result<Vec<CloudFile>> {
        let mut all = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let res: FileList = self.data(Method::POST, path, Some(make_body(cursor.as_deref()))).await?;
            all.extend(res.files.unwrap_or_default());
            match res.next_page_cursor.filter(|c| !c.is_empty()) {
                Some(c) => cursor = Some(c),
                None => break,
            }
            if all.len() > 50_000 { break; }
        }
        Ok(all)
    }

    pub async fn list(&self, folder_id: &str) -> Result<Vec<CloudFile>> {
        self.paged(&format!("{V1}/files"), |c| {
            let mut page = json!({"pageSize": 100});
            if let Some(c) = c { page["pageCursor"] = json!(c); }
            json!({"parentFolderId": folder_id, "recycled": false, "pageInfo": page})
        }).await
    }

    pub async fn trash(&self) -> Result<Vec<CloudFile>> {
        self.paged(&format!("{V1}/files"), |c| {
            let mut page = json!({"pageSize": 100});
            if let Some(c) = c { page["pageCursor"] = json!(c); }
            json!({"recycled": true, "pageInfo": page})
        }).await
    }

    pub async fn favorites(&self) -> Result<Vec<CloudFile>> {
        self.paged(&format!("{V1}/files/favorite"), |c| {
            let mut b = json!({"pageSize": 100});
            if let Some(c) = c { b["pageCursor"] = json!(c); }
            b
        }).await
    }

    pub async fn search(&self, keyword: &str, in_trash: bool) -> Result<Vec<CloudFile>> {
        let res: FileList = self
            .data(Method::POST, &format!("{V1}/files/search"), Some(json!({"keyWord": keyword, "recycled": in_trash, "pageInfo": {"pageSize": 100}})))
            .await?;
        Ok(res.files.unwrap_or_default())
    }

    pub async fn recent(&self, limit: usize) -> Result<Vec<CloudFile>> {
        let res: RecentList = self.data(Method::GET, &format!("{V1}/files/recent"), None).await?;
        let mut seen = std::collections::HashSet::new();
        let ids: Vec<String> = res.files.unwrap_or_default().into_iter()
            .filter_map(|e| e.metadata.and_then(|m| m.file_id).or(e.file_id))
            .filter(|id| seen.insert(id.clone()))
            .take(limit)
            .collect();
        let root = self.root_id().await;
        let fetched = futures_util::future::join_all(ids.iter().map(|id| self.file(id))).await;
        Ok(fetched.into_iter().filter_map(|r| r.ok())
            .filter(|f| Some(&f.id) != root.as_ref() && f.recycled != Some(true))
            .collect())
    }

    async fn root_id(&self) -> Option<String> {
        let mut r = self.root_id.lock().await;
        if r.is_none() {
            *r = self.file("root").await.ok().map(|f| f.id);
        }
        r.clone()
    }

    // MARK: mutations

    pub async fn create_folder(&self, name: &str, parent: &str) -> Result<Option<String>> {
        let v: Value = self.data(Method::POST, &format!("{V1}/files/create/folder"), Some(json!({"name": name, "parentFolder": parent}))).await?;
        Ok(v.get("id").and_then(Value::as_str).map(String::from))
    }
    /// `new_name` excludes the extension; the server keeps the original suffix.
    pub async fn rename(&self, id: &str, new_name: &str) -> Result<()> {
        self.send(Method::PUT, &format!("{V1}/files/rename/{id}"), Some(json!({"newName": new_name, "duplicateFilePolicy": "FORCE_RENAME"}))).await.map(|_| ())
    }
    pub async fn move_files(&self, ids: &[String], dest: &str) -> Result<()> {
        let items: Vec<Value> = ids.iter().map(|i| json!({"fileId": i})).collect();
        self.send(Method::PUT, &format!("{V1}/files/move"), Some(json!({"items": items, "newFilePath": dest}))).await.map(|_| ())
    }
    pub async fn copy_files(&self, ids: &[String], dest: &str) -> Result<()> {
        let items: Vec<Value> = ids.iter().map(|i| json!({"fileId": i})).collect();
        self.send(Method::POST, &format!("{V1}/files/copy"), Some(json!({"items": items, "newFilePath": dest}))).await.map(|_| ())
    }
    pub async fn delete(&self, files: &[CloudFile], permanent: bool) -> Result<()> {
        let items: Vec<Value> = files.iter().map(|f| json!({"fileId": f.id, "filePath": format!("{}/{}", f.parent_id(), f.id)})).collect();
        self.send(Method::DELETE, &format!("{V1}/files/delete"), Some(json!({"items": items, "policy": if permanent { "PERMANENT" } else { "LOGICAL" }}))).await.map(|_| ())
    }
    pub async fn restore(&self, ids: &[String]) -> Result<()> {
        self.send(Method::POST, &format!("{V1}/files/restore"), Some(json!({"items": ids}))).await.map(|_| ())
    }
    pub async fn empty_trash(&self) -> Result<()> {
        self.send(Method::DELETE, &format!("{V1}/files/trash-empty"), None).await.map(|_| ())
    }
    pub async fn set_favorite(&self, ids: &[String], on: bool) -> Result<()> {
        self.send(Method::PUT, &format!("{V1}/files/favorite/mark-favorite"), Some(json!({"items": ids, "favorite": on}))).await.map(|_| ())
    }
    /// Validity unit is a best guess (days); untested against the live API.
    pub async fn public_link(&self, id: &str) -> Result<String> {
        let v: Value = self.data(Method::POST, &format!("{V1}/files/share/public"), Some(json!({"item": id, "validity": 7}))).await?;
        v.get("shortUrl").and_then(Value::as_str).map(String::from).ok_or_else(|| ApiError::Api("No link returned".into()))
    }

    // MARK: upload primitives

    pub async fn create_file_meta(&self, plan: &UploadPlan, parent: &str) -> Result<FileMeta> {
        let parts: Vec<Value> = plan.slices.iter().map(|s| json!({
            "hashCtx": s.hash_ctx.iter().map(|w| w.to_string()).collect::<Vec<_>>(),
            "partNumber": s.part_number, "partOffset": s.offset, "partSize": s.size,
        })).collect();
        self.data(Method::POST, &format!("{V1}/files/create-file-meta"), Some(json!({
            "duplicateFilePolicy": "FORCE_RENAME",
            "fileName": plan.file_name,
            "fileType": plan.file_type,
            "mimeType": plan.mime_type,
            "multiParts": parts,
            "parentFolder": [parent],
            "totalSize": plan.total_size,
            "sha256": plan.sha256,
            "proofCode": plan.proof_code,
            "uploadMode": "multipart",
            "uploadType": "MULTIPART",
        }))).await
    }

    pub async fn complete_upload(&self, file_id: &str) -> Result<()> {
        self.send(Method::GET, &format!("{V1}/files/complete-status/{file_id}"), None).await.map(|_| ())
    }

    /// Plain client for presigned storage URLs (no auth headers, long timeout).
    pub fn storage_client(&self) -> Client {
        Client::builder().timeout(Duration::from_secs(60 * 60)).build().expect("client")
    }
}

fn add_cookie_header(jar: &Jar, header: &str) {
    let url = origin_url();
    for pair in header.split("; ").filter(|p| p.contains('=')) {
        jar.add_cookie_str(&format!("{pair}; Domain=gpcloud.grameenphone.com; Path=/; Secure; HttpOnly"), &url);
    }
}

fn jwt_exp(jwt: &str) -> Option<u64> {
    use base64::Engine;
    let payload = jwt.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload.trim_end_matches('=')).ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v.get("exp")?.as_f64().map(|e| e as u64)
}
