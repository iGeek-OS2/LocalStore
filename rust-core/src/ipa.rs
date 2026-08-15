use std::fs::File;
use std::io::Read;

use base64::Engine as _;
use plist::Value;
use serde::Serialize;
use zip::ZipArchive;

#[derive(Serialize)]
struct IpaMetadata {
    name: String,
    bundle_id: String,
    version: String,
    build: String,
    minimum_os: String,
    file_size_bytes: u64,
    icon_base64: Option<String>,
}

fn string(dict: &plist::Dictionary, key: &str) -> String {
    dict.get(key)
        .and_then(Value::as_string)
        .unwrap_or_default()
        .to_owned()
}

fn icon_names(dict: &plist::Dictionary) -> Vec<String> {
    let mut names = Vec::new();
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
        let Some(icons) = dict.get(key).and_then(Value::as_dictionary) else { continue };
        let Some(primary) = icons.get("CFBundlePrimaryIcon").and_then(Value::as_dictionary) else { continue };
        let Some(files) = primary.get("CFBundleIconFiles").and_then(Value::as_array) else { continue };
        names.extend(files.iter().filter_map(Value::as_string).map(str::to_owned));
    }
    if let Some(files) = dict.get("CFBundleIconFiles").and_then(Value::as_array) {
        names.extend(files.iter().filter_map(Value::as_string).map(str::to_owned));
    }
    names
}

pub fn metadata(path: &str) -> Result<String, String> {
    let file = File::open(path).map_err(|e| format!("IPAを開けません: {e}"))?;
    let file_size_bytes = file
        .metadata()
        .map_err(|e| format!("IPAのサイズを取得できません: {e}"))?
        .len();
    let mut zip = ZipArchive::new(file).map_err(|e| format!("IPAのZIPを読めません: {e}"))?;

    let info_name = (0..zip.len())
        .filter_map(|i| zip.name_for_index(i).map(str::to_owned))
        .find(|name| {
            let parts: Vec<_> = name.split('/').collect();
            parts.len() == 3
                && parts[0] == "Payload"
                && parts[1].ends_with(".app")
                && parts[2] == "Info.plist"
        })
        .ok_or_else(|| "IPAにPayload/*.app/Info.plistがありません".to_owned())?;

    let mut info = Vec::new();
    zip.by_name(&info_name)
        .map_err(|e| format!("Info.plistを開けません: {e}"))?
        .read_to_end(&mut info)
        .map_err(|e| format!("Info.plistを読めません: {e}"))?;
    let value = Value::from_reader(std::io::Cursor::new(info))
        .map_err(|e| format!("Info.plistを解析できません: {e}"))?;
    let dict = value
        .as_dictionary()
        .ok_or_else(|| "Info.plistの形式が正しくありません".to_owned())?;

    let bundle_id = string(dict, "CFBundleIdentifier");
    if bundle_id.is_empty() {
        return Err("IPAにBundle IDがありません".to_owned());
    }
    let name = {
        let display = string(dict, "CFBundleDisplayName");
        if !display.is_empty() { display } else {
            let bundle_name = string(dict, "CFBundleName");
            if !bundle_name.is_empty() { bundle_name } else { bundle_id.clone() }
        }
    };
    let version = string(dict, "CFBundleShortVersionString");
    let build = string(dict, "CFBundleVersion");
    let minimum_os = {
        let ios = string(dict, "MinimumOSVersion");
        if !ios.is_empty() { ios } else { string(dict, "LSMinimumSystemVersion") }
    };

    let app_prefix = info_name.trim_end_matches("Info.plist").to_owned();
    let expected = icon_names(dict);
    let mut candidates: Vec<(usize, String)> = (0..zip.len())
        .filter_map(|i| zip.name_for_index(i).map(str::to_owned))
        .filter(|entry| {
            if !entry.starts_with(&app_prefix) || !entry.to_ascii_lowercase().ends_with(".png") {
                return false;
            }
            let relative = &entry[app_prefix.len()..];
            if relative.contains('/') { return false; }
            let stem = relative.trim_end_matches(".png");
            if expected.is_empty() {
                stem.to_ascii_lowercase().contains("icon")
            } else {
                expected.iter().any(|wanted| {
                    let wanted = wanted.trim_end_matches(".png");
                    stem == wanted || stem.starts_with(&format!("{wanted}@"))
                })
            }
        })
        .map(|entry| {
            let scale = if entry.contains("@3x") { 3 } else if entry.contains("@2x") { 2 } else { 1 };
            (scale, entry)
        })
        .collect();
    candidates.sort_by(|a, b| b.0.cmp(&a.0));

    let icon_base64 = if let Some((_, entry)) = candidates.first() {
        let mut bytes = Vec::new();
        zip.by_name(entry)
            .map_err(|e| format!("アイコンを開けません: {e}"))?
            .read_to_end(&mut bytes)
            .map_err(|e| format!("アイコンを読めません: {e}"))?;
        Some(base64::engine::general_purpose::STANDARD.encode(bytes))
    } else {
        None
    };

    serde_json::to_string(&IpaMetadata {
        name,
        bundle_id,
        version,
        build,
        minimum_os,
        file_size_bytes,
        icon_base64,
    })
        .map_err(|e| format!("IPA情報を生成できません: {e}"))
}
