//! Offline demo data (GPCLOUD_DEMO=1) for screenshots: no account or network needed.

use crate::api::{CloudFile, DownloadLink, Profile, SpaceInfo, FOLDER_MIME};

pub fn enabled() -> bool {
    std::env::var("GPCLOUD_DEMO").map(|v| v == "1").unwrap_or(false)
}

pub fn space() -> SpaceInfo {
    SpaceInfo { cloud_user_id: Some("0".into()), capacity: Some(107_374_182_400), space_used: Some(25_125_558_272) }
}

pub fn profile() -> Profile {
    Profile { name: Some("Demo User".into()), mobile_number: Some("Demo account".into()), ..Default::default() }
}

fn ago(hours: f64) -> String {
    let t = chrono::Utc::now() - chrono::Duration::seconds((hours * 3600.0) as i64);
    t.format("%Y-%m-%dT%H:%M:%S%.3f").to_string()
}

/// Simple landscape thumbnail as an SVG data URI.
fn thumb(sky1: &str, sky2: &str, land: &str, sun: Option<&str>) -> String {
    let sun = sun.map(|c| format!("<circle cx='330' cy='120' r='36' fill='{c}'/>")).unwrap_or_default();
    let svg = format!(
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 480 320'><defs><linearGradient id='g' x1='0' y1='0' x2='0' y2='1'>\
         <stop offset='0' stop-color='{sky1}'/><stop offset='1' stop-color='{sky2}'/></linearGradient></defs>\
         <rect width='480' height='320' fill='url(#g)'/>{sun}\
         <path d='M0 320 L0 250 L144 144 L264 224 L384 128 L480 208 L480 320 Z' fill='{land}' opacity='.8'/>\
         <rect y='250' width='480' height='70' fill='{land}'/></svg>"
    );
    format!("data:image/svg+xml;utf8,{}", svg.replace('#', "%23"))
}

fn folder(id: &str, name: &str, hours: f64, star: bool) -> CloudFile {
    CloudFile {
        id: id.into(), file_name: name.into(), file_type: Some("FOLDER".into()), file_suffix: None,
        mime_type: Some(FOLDER_MIME.into()), parent_folder: Some(vec!["root".into()]), file_size: None,
        recycled: Some(false), favorite: Some(star), created_time: Some(ago(hours)), edited_time: Some(ago(hours)),
        download_links: None,
    }
}

#[allow(clippy::too_many_arguments)]
fn file(id: &str, name: &str, ty: &str, mime: &str, size: u64, hours: f64, star: bool, th: Option<String>, parent: &str, recycled: bool) -> CloudFile {
    CloudFile {
        id: id.into(), file_name: name.into(), file_type: Some(ty.into()),
        file_suffix: name.rsplit('.').next().map(String::from), mime_type: Some(mime.into()),
        parent_folder: Some(vec![parent.into()]), file_size: Some(size), recycled: Some(recycled), favorite: Some(star),
        created_time: Some(ago(hours + 30.0)), edited_time: Some(ago(hours)),
        download_links: th.map(|t| vec![DownloadLink { usage: Some("thumbnail".into()), download_link: Some(t) }]),
    }
}

fn root() -> Vec<CloudFile> {
    vec![
        folder("f-docs", "Documents", 3.0, true),
        folder("f-photos", "Photos", 20.0, false),
        folder("f-projects", "Projects", 50.0, false),
        folder("f-music", "Music", 400.0, false),
        file("p1", "Coxs-Bazar-sunset.jpg", "PICTURE", "image/jpeg", 4_812_330, 1.2, true, Some(thumb("#ff9f43", "#ee5a8f", "#2a1f40", Some("#ffd93d"))), "root", false),
        file("p2", "Sajek-valley.jpg", "PICTURE", "image/jpeg", 6_204_118, 5.0, false, Some(thumb("#48c6ef", "#c3ecff", "#2f7a52", Some("#ffffff"))), "root", false),
        file("d1", "Annual-Report-2026.pdf", "OTHER", "application/pdf", 2_311_908, 2.0, false, None, "root", false),
        file("v1", "Family-trip.mp4", "VIDEO", "video/mp4", 412_993_211, 26.0, false, Some(thumb("#2e86de", "#48dbfb", "#0a3d62", Some("#feca57"))), "root", false),
        file("x1", "Budget-2026.xlsx", "EXCEL", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", 88_412, 30.0, true, None, "root", false),
        file("k1", "Pitch-Deck.pptx", "PPT", "application/vnd.openxmlformats-officedocument.presentationml.presentation", 9_412_002, 72.0, false, None, "root", false),
        file("p3", "Tea-garden-Sylhet.jpg", "PICTURE", "image/jpeg", 5_118_004, 100.0, false, Some(thumb("#b8e994", "#78e08f", "#1e5631", None)), "root", false),
        file("z1", "Backup-2025.zip", "ARCHIVE", "application/zip", 1_204_993_118, 700.0, false, None, "root", false),
        file("t1", "Notes.txt", "OTHER", "text/plain", 4_120, 0.3, false, None, "root", false),
    ]
}

pub fn items(section: &str, folder_id: &str, search: &str) -> Vec<CloudFile> {
    let all = root();
    if !search.trim().is_empty() {
        let q = search.to_lowercase();
        return all.into_iter().filter(|f| f.file_name.to_lowercase().contains(&q)).collect();
    }
    match section {
        "recent" => ["p1", "d1", "k1", "p2", "v1", "x1"].iter().filter_map(|id| all.iter().find(|f| f.id == *id).cloned()).collect(),
        "starred" => all.into_iter().filter(|f| f.favorite == Some(true)).collect(),
        "trash" => vec![
            file("r1", "Old-draft.docx", "WORD", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", 31_002, 48.0, false, None, "root", true),
        ],
        _ if folder_id == "root" => all,
        _ => vec![],
    }
}
