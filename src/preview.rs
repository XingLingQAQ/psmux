//! Live preview helpers for the choose-tree / choose-session pickers.
//!
//! Fetches `capture-pane` output from any reachable session via TCP and
//! caches results briefly so navigation through the picker stays snappy.
//!
//! See issue #257 (preview support like tmux's `screen_write_preview`).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::session::{fetch_authed_response_multi, read_session_key};
use crate::util::LayoutSimple;

/// Cache key: "session\twin_id\tpane_id" (pane_id == usize::MAX means
/// "use the active pane of the targeted window").
pub type PreviewCache = HashMap<String, (String, Instant)>;

pub const PREVIEW_TTL: Duration = Duration::from_millis(1500);
const CONNECT_TIMEOUT: Duration = Duration::from_millis(150);
const READ_TIMEOUT: Duration = Duration::from_millis(400);

pub fn cache_key(sess: &str, win_id: usize, pane_id: usize) -> String {
    format!("{}\t{}\t{}", sess, win_id, pane_id)
}

/// Fetch capture-pane text for the given target. Returns None if the
/// session is not reachable or the response is empty.
///
/// `pane_id == usize::MAX` => target the window only (server captures the
/// active pane). Otherwise targets a specific pane id within the window.
pub fn fetch_pane_preview(home: &str, sess: &str, win_id: usize, pane_id: usize) -> Option<String> {
    let port_path = format!("{}\\.psmux\\{}.port", home, sess);
    let port: u16 = std::fs::read_to_string(&port_path).ok()?.trim().parse().ok()?;
    let key = read_session_key(sess).ok()?;
    let target = if pane_id == usize::MAX {
        format!(":@{}", win_id)
    } else {
        format!(":@{}.%{}", win_id, pane_id)
    };
    let cmd = format!("capture-pane -p -t {}\n", target);
    let resp = fetch_authed_response_multi(
        &format!("127.0.0.1:{}", port),
        &key,
        cmd.as_bytes(),
        CONNECT_TIMEOUT,
        READ_TIMEOUT,
    )?;
    if resp.trim().is_empty() {
        None
    } else {
        Some(resp)
    }
}

/// Get a preview, using the cache if fresh, fetching otherwise.
pub fn get_or_fetch(
    cache: &mut PreviewCache,
    home: &str,
    sess: &str,
    win_id: usize,
    pane_id: usize,
) -> Option<String> {
    let key = cache_key(sess, win_id, pane_id);
    if let Some((text, ts)) = cache.get(&key) {
        if ts.elapsed() < PREVIEW_TTL {
            return Some(text.clone());
        }
    }
    let text = fetch_pane_preview(home, sess, win_id, pane_id)?;
    cache.insert(key, (text.clone(), Instant::now()));
    Some(text)
}

/// Render preview text into a Vec of lines clipped to the given dimensions.
/// Strips trailing whitespace and keeps the most recent (bottom) `height`
/// non-empty lines so the active prompt is visible.
pub fn clip_lines(text: &str, width: u16, height: u16) -> Vec<String> {
    let max_w = width as usize;
    let max_h = height as usize;
    if max_h == 0 || max_w == 0 {
        return Vec::new();
    }
    // Split, trim trailing whitespace, drop the trailing empty noise but
    // keep blank lines that appear between content.
    let raw: Vec<&str> = text.split('\n').collect();
    // Trim trailing empty lines so the last visible line is real content.
    let mut end = raw.len();
    while end > 0 && raw[end - 1].trim_end().is_empty() {
        end -= 1;
    }
    let slice = &raw[..end];
    let start = slice.len().saturating_sub(max_h);
    slice[start..]
        .iter()
        .map(|l| {
            let t = l.trim_end_matches(['\r', ' ', '\t'][..].as_ref());
            // Truncate by characters to avoid splitting on a UTF-8 boundary.
            let mut out = String::new();
            let mut w = 0;
            for ch in t.chars() {
                // Crude width: 1 per char. ratatui will handle wide chars
                // when the Paragraph is rendered.
                if w + 1 > max_w {
                    break;
                }
                out.push(ch);
                w += 1;
            }
            out
        })
        .collect()
}

// ---------------------------------------------------------------------
// Layout-aware preview (issue #257 follow-up): show every pane in a
// window with its real split layout, mirroring tmux's
// `screen_write_preview` per pane in `window_tree_draw_window`.
// ---------------------------------------------------------------------

/// Cache for window layout JSON keyed by "sess\twin_id".
pub type LayoutCache = HashMap<String, (LayoutSimple, Instant)>;

pub const LAYOUT_TTL: Duration = Duration::from_millis(2500);

/// Fetch the simplified layout for a window in any session via TCP.
pub fn fetch_window_layout(home: &str, sess: &str, win_id: usize) -> Option<LayoutSimple> {
    let port_path = format!("{}\\.psmux\\{}.port", home, sess);
    let port: u16 = std::fs::read_to_string(&port_path).ok()?.trim().parse().ok()?;
    let key = read_session_key(sess).ok()?;
    let cmd = format!("window-layout {}\n", win_id);
    let resp = fetch_authed_response_multi(
        &format!("127.0.0.1:{}", port),
        &key,
        cmd.as_bytes(),
        CONNECT_TIMEOUT,
        READ_TIMEOUT,
    )?;
    let trimmed = resp.trim();
    if trimmed.is_empty() || trimmed == "{}" {
        return None;
    }
    serde_json::from_str::<LayoutSimple>(trimmed).ok()
}

pub fn get_or_fetch_layout(
    cache: &mut LayoutCache,
    home: &str,
    sess: &str,
    win_id: usize,
) -> Option<LayoutSimple> {
    let key = format!("{}\t{}", sess, win_id);
    if let Some((layout, ts)) = cache.get(&key) {
        if ts.elapsed() < LAYOUT_TTL {
            return Some(layout.clone());
        }
    }
    let layout = fetch_window_layout(home, sess, win_id)?;
    cache.insert(key, (layout.clone(), Instant::now()));
    Some(layout)
}

/// Recursively split a Rect according to the layout tree, returning a
/// list of (pane_id, active, area) tuples for every leaf.
///
/// `Horizontal` => children laid out left/right (columns), `Vertical`
/// => top/bottom (rows). One cell between children is reserved as a
/// separator so the user can see the split structure.
pub fn flatten_layout_to_rects(
    layout: &LayoutSimple,
    area: ratatui::layout::Rect,
) -> Vec<(usize, bool, ratatui::layout::Rect)> {
    use ratatui::layout::Rect;
    let mut out: Vec<(usize, bool, Rect)> = Vec::new();
    fn rec(node: &LayoutSimple, area: Rect, out: &mut Vec<(usize, bool, Rect)>) {
        match node {
            LayoutSimple::Leaf { id, active } => {
                if area.width > 0 && area.height > 0 {
                    out.push((*id, *active, area));
                }
            }
            LayoutSimple::Split { kind, sizes, children } => {
                if children.is_empty() {
                    return;
                }
                let total: u32 = sizes.iter().map(|s| *s as u32).sum::<u32>().max(1);
                let is_horiz = kind.as_str() == "Horizontal";
                let span = if is_horiz { area.width as u32 } else { area.height as u32 };
                let sep_count = children.len().saturating_sub(1) as u32;
                let usable = span.saturating_sub(sep_count);
                let n = children.len();
                let mut alloc: Vec<u32> = sizes.iter().take(n)
                    .map(|s| (*s as u32 * usable) / total)
                    .collect();
                while alloc.len() < n { alloc.push(0); }
                let used: u32 = alloc.iter().sum();
                let mut leftover = usable.saturating_sub(used);
                let alen = alloc.len();
                let mut idx = 0;
                while leftover > 0 && alen > 0 {
                    alloc[idx % alen] += 1;
                    idx += 1;
                    leftover -= 1;
                }
                let mut cursor: u32 = 0;
                for (i, child) in children.iter().enumerate() {
                    let size = alloc[i] as u16;
                    let sub = if is_horiz {
                        Rect { x: area.x + cursor as u16, y: area.y, width: size, height: area.height }
                    } else {
                        Rect { x: area.x, y: area.y + cursor as u16, width: area.width, height: size }
                    };
                    rec(child, sub, out);
                    cursor += size as u32;
                    if i + 1 < children.len() {
                        cursor += 1;
                    }
                }
            }
        }
    }
    rec(layout, area, &mut out);
    out
}

/// Compute separator line segments (vertical and horizontal) drawn
/// between children of every Split node, for visual delineation.
/// Returns a list of (Rect, is_vertical) where Rect is a 1-cell wide
/// vertical bar or 1-cell tall horizontal bar.
pub fn layout_separators(
    layout: &LayoutSimple,
    area: ratatui::layout::Rect,
) -> Vec<(ratatui::layout::Rect, bool)> {
    use ratatui::layout::Rect;
    let mut out: Vec<(Rect, bool)> = Vec::new();
    fn rec(node: &LayoutSimple, area: Rect, out: &mut Vec<(Rect, bool)>) {
        if let LayoutSimple::Split { kind, sizes, children } = node {
            if children.is_empty() { return; }
            let total: u32 = sizes.iter().map(|s| *s as u32).sum::<u32>().max(1);
            let is_horiz = kind.as_str() == "Horizontal";
            let span = if is_horiz { area.width as u32 } else { area.height as u32 };
            let sep_count = children.len().saturating_sub(1) as u32;
            let usable = span.saturating_sub(sep_count);
            let n = children.len();
            let mut alloc: Vec<u32> = sizes.iter().take(n)
                .map(|s| (*s as u32 * usable) / total)
                .collect();
            while alloc.len() < n { alloc.push(0); }
            let used: u32 = alloc.iter().sum();
            let mut leftover = usable.saturating_sub(used);
            let alen = alloc.len();
            let mut idx = 0;
            while leftover > 0 && alen > 0 {
                alloc[idx % alen] += 1;
                idx += 1;
                leftover -= 1;
            }
            let mut cursor: u32 = 0;
            for (i, child) in children.iter().enumerate() {
                let size = alloc[i] as u16;
                let sub = if is_horiz {
                    Rect { x: area.x + cursor as u16, y: area.y, width: size, height: area.height }
                } else {
                    Rect { x: area.x, y: area.y + cursor as u16, width: area.width, height: size }
                };
                rec(child, sub, out);
                cursor += size as u32;
                if i + 1 < children.len() {
                    if is_horiz {
                        out.push((Rect { x: area.x + cursor as u16, y: area.y, width: 1, height: area.height }, true));
                    } else {
                        out.push((Rect { x: area.x, y: area.y + cursor as u16, width: area.width, height: 1 }, false));
                    }
                    cursor += 1;
                }
            }
        }
    }
    rec(layout, area, &mut out);
    out
}