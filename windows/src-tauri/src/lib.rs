mod api;
mod demo;
mod hashing;
mod transfers;

use api::{ApiError, Cloud, CloudFile, Profile, SpaceInfo, ORIGIN};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;
use transfers::Transfers;

struct AppState {
    cloud: Arc<Cloud>,
    transfers: Arc<Transfers>,
    cache_dir: PathBuf,
}

type Res<T> = Result<T, ApiError>;

fn demo() -> bool {
    demo::enabled()
}

// MARK: - Auth

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthState {
    signed_in: bool,
    error: Option<String>,
}

#[tauri::command]
async fn auth_state(state: State<'_, AppState>) -> Result<AuthState, ()> {
    if demo() {
        return Ok(AuthState { signed_in: true, error: None });
    }
    Ok(match state.cloud.fetch_token().await {
        Ok(_) => AuthState { signed_in: true, error: None },
        Err(ApiError::SignedOut) => AuthState { signed_in: false, error: None },
        Err(e) => AuthState { signed_in: false, error: Some(e.to_string()) },
    })
}

/// Opens GP Cloud's own login page in a private window. When its session cookie appears, we copy it
/// into the app's cookie jar, confirm we can get a token, and close the window.
#[tauri::command]
async fn start_login(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    if let Some(w) = app.get_webview_window("login") {
        let _ = w.set_focus();
        return Ok(());
    }
    let win = WebviewWindowBuilder::new(&app, "login", WebviewUrl::External(ORIGIN.parse().unwrap()))
        .title("Sign in to GP Cloud")
        .inner_size(480.0, 720.0)
        .center()
        .incognito(true)
        .build()
        .map_err(|e| e.to_string())?;
    let cloud = state.cloud.clone();
    tauri::async_runtime::spawn(async move {
        let origin: url::Url = ORIGIN.parse().unwrap();
        loop {
            tokio::time::sleep(Duration::from_millis(1200)).await;
            // Window closed by the user?
            if app.get_webview_window("login").is_none() {
                let _ = app.emit("auth-changed", false);
                break;
            }
            let Ok(cookies) = win.cookies_for_url(origin.clone()) else { continue };
            if !cookies.iter().any(|c| c.name().contains("session-token")) {
                continue;
            }
            let pairs: Vec<(String, String)> = cookies.iter().map(|c| (c.name().to_string(), c.value().to_string())).collect();
            cloud.import_cookies(&pairs);
            if cloud.fetch_token().await.is_ok() {
                let _ = win.close();
                let _ = app.emit("auth-changed", true);
                break;
            }
        }
    });
    Ok(())
}

#[tauri::command]
async fn sign_out(app: AppHandle, state: State<'_, AppState>) -> Result<(), ()> {
    state.transfers.reset().await;
    state.cloud.sign_out().await;
    let _ = tokio::fs::remove_dir_all(&state.cache_dir).await;
    let _ = app.emit("auth-changed", false);
    Ok(())
}

// MARK: - Account & browsing

#[derive(Serialize)]
struct Account {
    space: SpaceInfo,
    profile: Profile,
}

#[tauri::command]
async fn account(app: AppHandle, state: State<'_, AppState>) -> Res<Account> {
    if demo() {
        return Ok(Account { space: demo::space(), profile: demo::profile() });
    }
    let (space, profile) = tokio::join!(state.cloud.space(), state.cloud.profile());
    let space = space?;
    update_tray_tooltip(&app, &space);
    Ok(Account { space, profile: profile.unwrap_or_default() })
}

#[tauri::command]
async fn list_files(state: State<'_, AppState>, section: String, folder_id: String, search: String) -> Res<Vec<CloudFile>> {
    if demo() {
        return Ok(demo::items(&section, &folder_id, &search));
    }
    let c = &state.cloud;
    let search = search.trim();
    if !search.is_empty() {
        return c.search(search, section == "trash").await;
    }
    match section.as_str() {
        "recent" => c.recent(40).await,
        "starred" => c.favorites().await,
        "trash" => c.trash().await,
        _ => c.list(&folder_id).await,
    }
}

#[tauri::command]
async fn list_folders(state: State<'_, AppState>, parent_id: String) -> Res<Vec<CloudFile>> {
    if demo() {
        return Ok(demo::items("myDrive", &parent_id, "").into_iter().filter(|f| f.is_folder()).collect());
    }
    Ok(state.cloud.list(&parent_id).await?.into_iter().filter(|f| f.is_folder()).collect())
}

// MARK: - Mutations

#[tauri::command]
async fn create_folder(state: State<'_, AppState>, name: String, parent_id: String) -> Res<()> {
    if let Some(e) = hashing::name_error(&name) { return Err(ApiError::Api(e.into())); }
    state.cloud.create_folder(&name, &parent_id).await.map(|_| ())
}

#[tauri::command]
async fn rename_file(state: State<'_, AppState>, id: String, new_name: String) -> Res<()> {
    if let Some(e) = hashing::name_error(&new_name) { return Err(ApiError::Api(e.into())); }
    state.cloud.rename(&id, &new_name).await
}

#[tauri::command]
async fn move_files(state: State<'_, AppState>, ids: Vec<String>, dest: String) -> Res<()> {
    state.cloud.move_files(&ids, &dest).await
}

#[tauri::command]
async fn copy_files(state: State<'_, AppState>, ids: Vec<String>, dest: String) -> Res<()> {
    state.cloud.copy_files(&ids, &dest).await
}

#[tauri::command]
async fn trash_files(state: State<'_, AppState>, files: Vec<CloudFile>, permanent: bool) -> Res<()> {
    state.cloud.delete(&files, permanent).await
}

#[tauri::command]
async fn restore_files(state: State<'_, AppState>, ids: Vec<String>) -> Res<()> {
    state.cloud.restore(&ids).await
}

#[tauri::command]
async fn empty_trash(state: State<'_, AppState>) -> Res<()> {
    state.cloud.empty_trash().await
}

#[tauri::command]
async fn set_star(state: State<'_, AppState>, ids: Vec<String>, on: bool) -> Res<()> {
    state.cloud.set_favorite(&ids, on).await
}

#[tauri::command]
async fn public_link(state: State<'_, AppState>, id: String) -> Res<String> {
    state.cloud.public_link(&id).await
}

#[tauri::command]
fn name_error(name: String) -> Option<String> {
    hashing::name_error(&name).map(String::from)
}

#[tauri::command]
fn sanitize_name(name: String) -> String {
    hashing::sanitize_name(&name)
}

// MARK: - Transfers & local files

#[tauri::command]
fn upload(state: State<'_, AppState>, paths: Vec<String>, folder_id: String) {
    state.transfers.upload(paths.into_iter().map(PathBuf::from).collect(), folder_id);
}

#[tauri::command]
fn download(app: AppHandle, state: State<'_, AppState>, files: Vec<CloudFile>, dir: Option<String>) -> Result<(), String> {
    let dir = match dir {
        Some(d) => PathBuf::from(d),
        None => app.path().download_dir().map_err(|e| e.to_string())?,
    };
    state.transfers.download(files, dir);
    Ok(())
}

#[tauri::command]
fn cancel_transfer(state: State<'_, AppState>, id: String) {
    state.transfers.cancel(&id);
}

#[tauri::command]
async fn open_file(app: AppHandle, state: State<'_, AppState>, file: CloudFile) -> Result<(), String> {
    if demo() { return Ok(()); }
    let path = state.transfers.fetch_for_open(&file, &state.cache_dir).await?;
    app.opener().open_path(path.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    app.opener().reveal_item_in_dir(path).map_err(|e| e.to_string())
}

// MARK: - Tray

fn update_tray_tooltip(app: &AppHandle, space: &SpaceInfo) {
    if let Some(tray) = app.tray_by_id("main") {
        let fmt = |b: u64| format!("{:.1} GB", b as f64 / 1e9);
        let tip = match (space.space_used, space.capacity) {
            (Some(u), Some(c)) => format!("GP Cloud: {} of {} used", fmt(u), fmt(c)),
            _ => "GP Cloud".into(),
        };
        let _ = tray.set_tooltip(Some(tip));
    }
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open GP Cloud", true, None::<&str>)?;
    let up_files = MenuItem::with_id(app, "upload-files", "Upload files to My Drive…", true, None::<&str>)?;
    let up_folder = MenuItem::with_id(app, "upload-folder", "Upload a folder to My Drive…", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit GP Cloud", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &PredefinedMenuItem::separator(app)?, &up_files, &up_folder, &PredefinedMenuItem::separator(app)?, &quit])?;
    TrayIconBuilder::with_id("main")
        .icon(app.default_window_icon().cloned().expect("icon"))
        .tooltip("GP Cloud")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app),
            "upload-files" | "upload-folder" => {
                let folder = event.id().as_ref() == "upload-folder";
                let handle = app.clone();
                let dialog = app.dialog().file().set_title("Upload to My Drive");
                let done = move |paths: Option<Vec<tauri_plugin_dialog::FilePath>>| {
                    let paths: Vec<PathBuf> = paths.unwrap_or_default().into_iter().filter_map(|p| p.into_path().ok()).collect();
                    if paths.is_empty() { return; }
                    show_main(&handle);
                    handle.state::<AppState>().transfers.upload(paths, "root".into());
                    let _ = handle.emit("show-transfers", ());
                };
                if folder {
                    dialog.pick_folders(done);
                } else {
                    dialog.pick_files(done);
                }
            }
            "quit" => {
                app.state::<AppState>().transfers.cancel_all();
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_main(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

// MARK: - Entry

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main(app)))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let data = app.path().app_local_data_dir()?;
            let cache = app.path().app_cache_dir()?.join("open");
            let cloud = Arc::new(Cloud::new(data));
            let transfers = Arc::new(Transfers::new(app.handle().clone(), cloud.clone()));
            app.manage(AppState { cloud, transfers, cache_dir: cache });
            build_tray(app.handle())?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the main window keeps GP Cloud running in the tray (like Google Drive).
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" && !demo() {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            auth_state, start_login, sign_out, account, list_files, list_folders,
            create_folder, rename_file, move_files, copy_files, trash_files, restore_files,
            empty_trash, set_star, public_link, name_error, sanitize_name,
            upload, download, cancel_transfer, open_file, reveal
        ])
        .run(tauri::generate_context!())
        .expect("error while running GP Cloud");
}
