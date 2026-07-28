//! Local clipboard adapter: classify what the user copied.
//!
//! Sources: image data and text via arboard, plus the native macOS file list
//! (`public.file-url`) which arboard can't read — so a plain Finder ⌘C on a
//! file works, not only "Copy as Pathname". Text that is itself existing local
//! paths is also treated as files (drag-and-drop, `file://` URIs, escaped
//! paths). Windows CF_HDROP — v0.3.

use anyhow::{Context, Result};
use std::path::PathBuf;

pub enum ClipContent {
    Empty,
    Text(String),
    /// RGBA image encoded to PNG bytes
    Png(Vec<u8>),
    /// existing local files (from path-looking text)
    Files(Vec<PathBuf>),
    /// existing local directory — not supported in v0.1
    Dir(PathBuf),
}

pub fn read() -> Result<ClipContent> {
    let mut cb = arboard::Clipboard::new().context("open clipboard")?;

    if let Ok(img) = cb.get_image() {
        return Ok(ClipContent::Png(encode_png(&img)?));
    }

    // native file list (macOS Finder ⌘C) before text — a file copy carries no
    // usable text representation
    #[cfg(target_os = "macos")]
    if let Some(content) = classify_paths(macos_pb::file_urls()) {
        return Ok(content);
    }

    let text = match cb.get_text() {
        Ok(t) if !t.is_empty() => t,
        _ => return Ok(ClipContent::Empty),
    };

    Ok(classify_text(text))
}

pub fn write_text(data: &[u8]) -> Result<()> {
    let text = String::from_utf8_lossy(data).into_owned();
    let mut cb = arboard::Clipboard::new().context("open clipboard")?;
    cb.set_text(text).context("set clipboard")?;
    Ok(())
}

/// Lines that are all existing local paths → Files/Dir; anything else → Text.
pub fn classify_text(text: String) -> ClipContent {
    let candidates: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if candidates.len() <= 64 {
        let paths: Vec<PathBuf> = candidates
            .iter()
            .map(|c| PathBuf::from(unescape_dnd(c)))
            .collect();
        if let Some(content) = classify_paths(paths) {
            return content;
        }
    }
    ClipContent::Text(text)
}

/// A list of paths → Files (all existing regular files) or Dir (a single
/// existing directory); None if they aren't all existing absolute paths.
fn classify_paths(paths: Vec<PathBuf>) -> Option<ClipContent> {
    if paths.is_empty() || !paths.iter().all(|p| p.is_absolute() && p.exists()) {
        return None;
    }
    if paths.len() == 1 && paths[0].is_dir() {
        return Some(ClipContent::Dir(paths.into_iter().next().unwrap()));
    }
    if paths.iter().all(|p| p.is_file()) {
        return Some(ClipContent::Files(paths));
    }
    None
}

/// terminals escape dragged paths differently: `\ ` (backslash-space), quoted, or file:// URI
fn unescape_dnd(s: &str) -> String {
    let s = s.trim_matches('\'').trim_matches('"');
    if let Some(rest) = s.strip_prefix("file://") {
        let path = rest.strip_prefix("localhost").unwrap_or(rest);
        return percent_decode(path);
    }
    s.replace("\\ ", " ")
}

fn percent_decode(s: &str) -> String {
    // byte-wise on purpose: slicing the &str could panic on a multi-byte
    // char right after '%' (non-char-boundary)
    fn hex(b: u8) -> Option<u8> {
        (b as char).to_digit(16).map(|d| d as u8)
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(hi * 16 + lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Reads the native `public.file-url` list from the general pasteboard — what
/// Finder's plain ⌘C puts there (and arboard ignores).
#[cfg(target_os = "macos")]
mod macos_pb {
    use super::{unescape_dnd, PathBuf};
    use objc2_app_kit::NSPasteboard;
    use objc2_foundation::NSString;

    pub fn file_urls() -> Vec<PathBuf> {
        let mut out = Vec::new();
        let pb = NSPasteboard::generalPasteboard();
        let Some(items) = pb.pasteboardItems() else {
            return out;
        };
        let ty = NSString::from_str("public.file-url");
        for item in items.iter() {
            if let Some(s) = item.stringForType(&ty) {
                out.push(PathBuf::from(unescape_dnd(&s.to_string())));
            }
        }
        out
    }
}

fn encode_png(img: &arboard::ImageData) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, img.width as u32, img.height as u32);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().context("png header")?;
        writer.write_image_data(&img.bytes).context("png data")?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_stays_text() {
        match classify_text("just some words".into()) {
            ClipContent::Text(t) => assert_eq!(t, "just some words"),
            _ => panic!("expected text"),
        }
    }

    #[test]
    fn existing_file_becomes_files() {
        let tmp = std::env::temp_dir().join("devbox-test-file.txt");
        std::fs::write(&tmp, "x").unwrap();
        match classify_text(tmp.to_string_lossy().into_owned()) {
            ClipContent::Files(f) => assert_eq!(f, vec![tmp.clone()]),
            _ => panic!("expected files"),
        }
        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn nonexistent_path_stays_text() {
        match classify_text("/no/such/file/anywhere.png".into()) {
            ClipContent::Text(_) => {}
            _ => panic!("expected text"),
        }
    }

    #[test]
    fn file_uri_decoded() {
        assert_eq!(unescape_dnd("file:///tmp/a%20b.png"), "/tmp/a b.png");
        assert_eq!(unescape_dnd("/tmp/a\\ b.png"), "/tmp/a b.png");
    }

    #[test]
    fn percent_decode_multibyte_no_panic() {
        // '%' followed by a multi-byte char used to panic on a non-boundary slice
        assert_eq!(unescape_dnd("file:///tmp/%€.png"), "/tmp/%€.png");
        // percent-encoded UTF-8 decodes properly
        assert_eq!(unescape_dnd("file:///tmp/%D1%84.png"), "/tmp/ф.png");
        // trailing lone '%' passes through
        assert_eq!(unescape_dnd("file:///tmp/x%"), "/tmp/x%");
    }
}
