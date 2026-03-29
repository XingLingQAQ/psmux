# Mouse Coordinate Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix mouse alignment across all interactions when multiple clients of different terminal sizes are connected to the same psmux session.

**Architecture:** Two-layer approach: (1) server-side ratio fallback maps raw coordinates from client-space to effective-space as a safety net for all interactions, (2) client-side semantic commands replace raw coordinates for precision interactions (tab clicks, pane focus, border drag, scroll targeting, PTY mouse forwarding). The client is the authority on its own coordinate space.

**Tech Stack:** Rust, ratatui, crossterm, vt100 crate (mouse protocol detection)

---

## File Map

| File | Role | Changes |
|-|-|-|
| `src/window_ops.rs` | Server mouse handlers | Phase 0: add `map_client_coords()` to all handlers. Phase 1+: add `handle_pane_mouse()`, `handle_pane_scroll()`, `handle_split_set_sizes()` |
| `src/types.rs` | CtrlReq enum, DragState | Add `PaneMouse`, `PaneScroll`, `SplitSetSizes`, `SplitResizeDone` variants |
| `src/server/connection.rs` | Protocol command parsing | Parse `pane-mouse`, `pane-scroll`, `split-sizes`, `split-resize-done` commands |
| `src/server/mod.rs` | Server dispatch loop | Dispatch new CtrlReq variants to handlers |
| `src/client.rs` | Client rendering + mouse handlers | Track pane rects/IDs and border positions during rendering; rewrite mouse handlers to send semantic commands |
| `src/layout.rs` | LayoutJson type | Already has all needed fields (id, active, copy_mode, alternate_screen) |
| `src/tree.rs` | Layout computation | Already has `split_with_gaps`, `compute_split_borders` — no changes needed |

---

## Task 1: Phase 0 — Server-Side Ratio Fallback

**Files:**
- Modify: `src/window_ops.rs:449-784` (all `remote_mouse_*` functions)

This is the safety net. Every raw mouse coordinate arriving from a client gets mapped from the client's terminal space to the server's effective space. This instantly makes ALL mouse interactions approximately correct for mismatched terminal sizes.

- [ ] **Step 1: Add `map_client_coords` helper function**

Add this function at the top of window_ops.rs, after the existing `pane_inner_cell` helpers (after line 48):

```rust
/// Map mouse coordinates from a client's terminal space to the server's effective
/// layout space.  When a client's terminal is larger or smaller than the effective
/// size used for layout computation, raw pixel coordinates don't match pane boundaries.
/// This ratio-based mapping is a "good enough" fallback for any interaction not yet
/// handled by client-side semantic commands.
fn map_client_coords(app: &AppState, x: u16, y: u16) -> (u16, u16) {
    let cid = match app.latest_client_id {
        Some(id) => id,
        None => return (x, y),
    };
    let (cw, ch) = match app.client_sizes.get(&cid) {
        Some(&size) => size,
        None => return (x, y),
    };
    let ew = app.last_window_area.width;
    let eh = app.last_window_area.height;
    if cw == ew && ch == eh {
        return (x, y);
    }
    let mx = if cw > 0 { ((x as u32) * (ew as u32) / (cw as u32)) as u16 } else { x };
    let my = if ch > 0 { ((y as u32) * (eh as u32) / (ch as u32)) as u16 } else { y };
    (mx.min(ew.saturating_sub(1)), my.min(eh.saturating_sub(1)))
}
```

- [ ] **Step 2: Apply mapping in `remote_mouse_down`**

At the top of `remote_mouse_down` (line 449), after the function signature, before any coordinate use, add:

```rust
let (x, y) = map_client_coords(app, x, y);
```

Note: The function signature must change from `(app: &mut AppState, x: u16, y: u16)` to use the remapped values. Since Rust doesn't allow reassigning non-mut params, shadow them:

```rust
pub fn remote_mouse_down(app: &mut AppState, x: u16, y: u16) {
    let (x, y) = map_client_coords(app, x, y);
    // ... rest of function unchanged
```

- [ ] **Step 3: Apply mapping in all other remote_mouse_* functions**

Add `let (x, y) = map_client_coords(app, x, y);` as the first line of each:
- `remote_mouse_drag` (line 516)
- `remote_mouse_up` (line 552)
- `remote_mouse_button` (line 598)
- `remote_mouse_motion` (line 640) — add BEFORE the dedup check at line 642
- `remote_scroll_wheel` (line 682) — this is the private function called by `remote_scroll_up`/`remote_scroll_down`

- [ ] **Step 4: Build and verify**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -3`
Expected: `Finished` with no errors

- [ ] **Step 5: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/window_ops.rs && git commit -m "feat: add ratio-based coordinate mapping for multi-client mouse alignment

When clients have different terminal sizes than the server's effective
layout area, raw mouse coordinates miss pane boundaries.  This maps
all incoming coordinates from client-space to effective-space as a
universal safety net.

Constraint: Integer division can be off by ±1px at boundaries
Directive: Semantic commands (later commits) handle precision cases — this is the fallback layer
Confidence: high
Scope-risk: narrow"
```

---

## Task 2: Protocol Extension — New CtrlReq Variants

**Files:**
- Modify: `src/types.rs:769-778` (CtrlReq enum, after existing Mouse variants)

- [ ] **Step 1: Add new CtrlReq variants**

After the existing `ScrollDown` variant (line 778), add:

```rust
    /// Client-side semantic mouse event: pane-relative coordinates, targeted by pane ID.
    /// Fields: client_id, pane_id, sgr_button, col_0based, row_0based, press
    PaneMouse(u64, usize, u8, i16, i16, bool),
    /// Client-side semantic scroll: targeted by pane ID.
    /// Fields: client_id, pane_id, up (true=up, false=down)
    PaneScroll(u64, usize, bool),
    /// Client-side semantic split resize: set sizes at a tree path.
    /// Fields: client_id, path (dot-separated), new sizes
    SplitSetSizes(u64, Vec<usize>, Vec<u16>),
    /// Client signals border drag is complete — trigger PTY resize.
    /// Fields: client_id
    SplitResizeDone(u64),
```

- [ ] **Step 2: Build to verify syntax**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -5`
Expected: warnings about unused variants (no errors)

- [ ] **Step 3: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/types.rs && git commit -m "feat: add CtrlReq variants for semantic mouse commands

PaneMouse, PaneScroll, SplitSetSizes, SplitResizeDone enable
client-side mouse handling with pane-relative coordinates instead
of raw terminal-absolute coordinates.

Confidence: high
Scope-risk: narrow"
```

---

## Task 3: Protocol Parsing — Connection Handler

**Files:**
- Modify: `src/server/connection.rs:656-659` (after `scroll-down` parsing block)

- [ ] **Step 1: Add command parsing for new semantic commands**

After the `"scroll-down"` block (around line 659), add:

```rust
    "pane-mouse" => {
        // pane-mouse PANE_ID BUTTON COL ROW M|m
        if args.len() >= 5 {
            if let (Ok(pane_id), Ok(button), Ok(col), Ok(row)) = (
                args[0].parse::<usize>(), args[1].parse::<u8>(),
                args[2].parse::<i16>(), args[3].parse::<i16>()
            ) {
                let press = args[4] != "m";
                let _ = tx.send(CtrlReq::PaneMouse(client_id, pane_id, button, col, row, press));
            }
        }
    }
    "pane-scroll" => {
        // pane-scroll PANE_ID up|down
        if args.len() >= 2 {
            if let Ok(pane_id) = args[0].parse::<usize>() {
                let up = args[1] == "up";
                let _ = tx.send(CtrlReq::PaneScroll(client_id, pane_id, up));
            }
        }
    }
    "split-sizes" => {
        // split-sizes PATH SIZE1,SIZE2,...
        // PATH is dot-separated tree indices: "0.1" or "0"
        if args.len() >= 2 {
            let path: Vec<usize> = args[0].split('.').filter_map(|s| s.parse().ok()).collect();
            let sizes: Vec<u16> = args[1].split(',').filter_map(|s| s.parse().ok()).collect();
            if !path.is_empty() && sizes.len() >= 2 {
                let _ = tx.send(CtrlReq::SplitSetSizes(client_id, path, sizes));
            }
        }
    }
    "split-resize-done" => {
        let _ = tx.send(CtrlReq::SplitResizeDone(client_id));
    }
```

- [ ] **Step 2: Build to verify parsing compiles**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -3`
Expected: `Finished` with no errors (may have unused-variant warnings)

- [ ] **Step 3: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/server/connection.rs && git commit -m "feat: parse semantic mouse commands in connection handler

Adds parsing for pane-mouse, pane-scroll, split-sizes, and
split-resize-done commands.  These carry pane-relative coordinates
and semantic intent instead of raw terminal coordinates.

Confidence: high
Scope-risk: narrow"
```

---

## Task 4: Server Handlers — Semantic Mouse Functions

**Files:**
- Modify: `src/window_ops.rs` (add new public functions after `remote_scroll_down`, around line 784)

- [ ] **Step 1: Add `handle_pane_mouse` function**

This handles a mouse event targeted at a specific pane with pane-relative coordinates. Add after `remote_scroll_down`:

```rust
/// Handle a semantic mouse event from the client.
/// The client has already determined the target pane and computed pane-relative
/// coordinates, so no coordinate translation is needed.
pub fn handle_pane_mouse(app: &mut AppState, pane_id: usize, button: u8, col: i16, row: i16, press: bool) {
    // Find the pane by ID and focus it
    let win = &mut app.windows[app.active_idx];
    let mut found_path: Option<Vec<usize>> = None;
    let mut rects: Vec<(Vec<usize>, Rect)> = Vec::new();
    compute_rects(&win.root, app.last_window_area, &mut rects);
    for (path, _area) in &rects {
        if let Some(pid) = crate::tree::get_active_pane_id(&win.root, path) {
            if pid == pane_id {
                found_path = Some(path.clone());
                break;
            }
        }
    }

    let Some(path) = found_path else { return; };

    // Focus the target pane
    if win.active_path != path {
        win.active_path = path.clone();
        if let Some(pid) = crate::tree::get_active_pane_id(&win.root, &path) {
            crate::tree::touch_mru(&mut win.pane_mru, pid);
        }
    }

    // Handle copy mode: position cursor with pane-relative coordinates
    if matches!(app.mode, Mode::CopyMode | Mode::CopySearch { .. }) {
        let r = row.max(0) as u16;
        let c = col.max(0) as u16;
        if button == 0 && press {
            // Left press: position cursor, clear selection
            app.copy_anchor = None;
            app.copy_pos = Some((r, c));
        } else if button == 32 {
            // Left drag: extend selection
            if app.copy_anchor.is_none() {
                app.copy_anchor = Some((r, c));
                app.copy_anchor_scroll_offset = app.copy_scroll_offset;
                app.copy_selection_mode = crate::types::SelectionMode::Char;
            }
            app.copy_pos = Some((r, c));
        } else if button == 0 && !press {
            // Left release: finalize, auto-yank if selection exists
            if app.copy_anchor.is_none() {
                app.copy_anchor = Some((r, c));
                app.copy_anchor_scroll_offset = app.copy_scroll_offset;
            }
            app.copy_pos = Some((r, c));
            if let (Some(a), Some(p)) = (app.copy_anchor, app.copy_pos) {
                if a != p { let _ = yank_selection(app); }
            }
        }
        return;
    }

    // Forward mouse event to PTY if pane wants it
    let win = &mut app.windows[app.active_idx];
    let win_name = win.name.clone();
    if let Some(pane) = active_pane_mut(&mut win.root, &win.active_path) {
        if pane_wants_mouse(pane) {
            let button_state = match (button, press) {
                (0, true) => mouse_inject::FROM_LEFT_1ST_BUTTON_PRESSED,
                (1, true) => mouse_inject::FROM_LEFT_2ND_BUTTON_PRESSED,
                (2, true) => mouse_inject::RIGHTMOST_BUTTON_PRESSED,
                _ => 0,
            };
            let event_flags = if button == 32 || button == 35 { mouse_inject::MOUSE_MOVED } else { 0 };
            inject_mouse_combined(pane, col, row, button, press, button_state, event_flags, &win_name);
        }
    }
}
```

- [ ] **Step 2: Add `handle_pane_scroll` function**

```rust
/// Handle a semantic scroll event targeted at a specific pane.
/// The client has already determined which pane to scroll.
pub fn handle_pane_scroll(app: &mut AppState, pane_id: usize, up: bool) {
    // Ignore scroll in popup mode (#110)
    if matches!(app.mode, Mode::PopupMode { .. }) { return; }

    // Handle scroll while already in copy mode (coordinates irrelevant)
    if matches!(app.mode, Mode::CopyMode | Mode::CopySearch { .. }) {
        if up {
            scroll_copy_up(app, 3);
        } else {
            scroll_copy_down(app, 3);
            if app.copy_scroll_offset == 0 && app.copy_anchor.is_none() {
                exit_copy_mode(app);
            }
        }
        return;
    }

    // Focus the target pane
    let win = &mut app.windows[app.active_idx];
    let mut rects: Vec<(Vec<usize>, Rect)> = Vec::new();
    compute_rects(&win.root, app.last_window_area, &mut rects);
    for (path, _area) in &rects {
        if let Some(pid) = crate::tree::get_active_pane_id(&win.root, path) {
            if pid == pane_id {
                win.active_path = path.clone();
                break;
            }
        }
    }

    // Check if target pane is in alternate screen (TUI app)
    let alt = active_pane(&win.root, &win.active_path)
        .map_or(false, |p| {
            p.term.lock().ok().map_or(false, |t| t.screen().alternate_screen())
        });

    if alt {
        // Forward scroll to TUI app — use center of pane as coordinates
        let win = &mut app.windows[app.active_idx];
        let win_name = win.name.clone();
        let sgr_btn: u8 = if up { 64 } else { 65 };
        let wheel_delta: i16 = if up { 120 } else { -120 };
        let button_state = ((wheel_delta as i32) << 16) as u32;
        if let Some(pane) = active_pane_mut(&mut win.root, &win.active_path) {
            // Use (0,0) as pane-relative coords — scroll events don't need precise position
            inject_mouse_combined(pane, 0, 0, sgr_btn, true,
                button_state, mouse_inject::MOUSE_WHEELED, &win_name);
        }
    } else if up {
        // Shell prompt — enter copy mode and scroll
        enter_copy_mode(app);
        scroll_copy_up(app, 3);
    }
    // Scroll down at shell without copy mode is a no-op
}
```

- [ ] **Step 3: Add `handle_split_set_sizes` and `handle_split_resize_done` functions**

```rust
/// Set split sizes at a given tree path.  Called during border drag — the client
/// computes percentage deltas in its own coordinate space and sends new sizes.
pub fn handle_split_set_sizes(app: &mut AppState, path: &[usize], sizes: &[u16]) {
    let win = &mut app.windows[app.active_idx];
    // Navigate to the split node at the given path
    let mut cur: &mut Node = &mut win.root;
    for &idx in path.iter() {
        match cur {
            Node::Split { children, .. } => {
                if idx < children.len() {
                    cur = &mut children[idx];
                } else {
                    return;
                }
            }
            Node::Leaf(_) => return,
        }
    }
    // Set the sizes on the split node
    if let Node::Split { sizes: node_sizes, children, .. } = cur {
        if sizes.len() == children.len() && sizes.len() == node_sizes.len() {
            *node_sizes = sizes.to_vec();
        }
    }
    // Don't call resize_all_panes here — that happens on SplitResizeDone
    // (PTY resize is expensive, only do it when drag ends)
}

/// Finalize a border resize: apply PTY resizes to match the new layout.
pub fn handle_split_resize_done(app: &mut AppState) {
    resize_all_panes(app);
}
```

- [ ] **Step 4: Build and verify**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -5`
Expected: `Finished` (may have unused warnings for new functions until dispatch is wired)

- [ ] **Step 5: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/window_ops.rs && git commit -m "feat: add server handlers for semantic mouse commands

handle_pane_mouse: processes mouse events with pane-relative coords
handle_pane_scroll: scrolls a specific pane by ID
handle_split_set_sizes: sets split sizes during border drag
handle_split_resize_done: triggers PTY resize after drag completes

These work with pane IDs and pane-relative coordinates, eliminating
the coordinate mismatch between different-sized client terminals.

Confidence: high
Scope-risk: moderate"
```

---

## Task 5: Server Dispatch — Wire New Variants

**Files:**
- Modify: `src/server/mod.rs:1216` (after `ScrollDown` dispatch, before `NextWindow`)

- [ ] **Step 1: Add dispatch for new CtrlReq variants**

After the `CtrlReq::ScrollDown` line (1216), add:

```rust
                CtrlReq::PaneMouse(cid, pane_id, button, col, row, press) => { if app.mouse_enabled { app.latest_client_id = Some(cid); handle_pane_mouse(&mut app, pane_id, button, col, row, press); state_dirty = true; meta_dirty = true; echo_pending_until = Some(Instant::now()); } }
                CtrlReq::PaneScroll(cid, pane_id, up) => { if app.mouse_enabled { app.latest_client_id = Some(cid); handle_pane_scroll(&mut app, pane_id, up); state_dirty = true; meta_dirty = true; echo_pending_until = Some(Instant::now()); } }
                CtrlReq::SplitSetSizes(cid, path, sizes) => { if app.mouse_enabled { app.latest_client_id = Some(cid); handle_split_set_sizes(&mut app, &path, &sizes); state_dirty = true; meta_dirty = true; echo_pending_until = Some(Instant::now()); } }
                CtrlReq::SplitResizeDone(cid) => { if app.mouse_enabled { app.latest_client_id = Some(cid); handle_split_resize_done(&mut app); state_dirty = true; meta_dirty = true; } }
```

- [ ] **Step 2: Add imports for new handler functions**

Find the existing import line in server/mod.rs that imports `remote_mouse_down` etc. (around line 33). Add the new functions to it:

```rust
use crate::window_ops::{..., handle_pane_mouse, handle_pane_scroll, handle_split_set_sizes, handle_split_resize_done};
```

- [ ] **Step 3: Build and verify — full compilation must pass**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -3`
Expected: `Finished` with no errors. All new CtrlReq variants are now handled.

- [ ] **Step 4: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/server/mod.rs && git commit -m "feat: dispatch semantic mouse commands in server event loop

Wires PaneMouse, PaneScroll, SplitSetSizes, SplitResizeDone to
their handler functions.  All gated on mouse_enabled.

Confidence: high
Scope-risk: narrow"
```

---

## Task 6: Client — Track Pane Rects and Border Positions During Rendering

**Files:**
- Modify: `src/client.rs` (state declarations ~line 604, rendering section ~line 2213)

This task extracts pane layout information from the render closure so the mouse handler can use it.

- [ ] **Step 1: Add client-side state variables for pane layout tracking**

Near line 607 (where `client_tab_positions`, `client_status_row`, `client_base_index` were added in the tab fix), add:

```rust
    // Pane layout tracking for semantic mouse commands.
    // Populated during rendering, used by mouse handler.
    let mut client_pane_rects: Vec<(usize, Rect)> = Vec::new(); // (pane_id, absolute_rect)
    let mut client_borders: Vec<(Vec<usize>, String, usize, u16, u16, Vec<u16>)> = Vec::new();
        // (tree_path_to_parent, kind_str, child_index, border_position, total_pixels, sizes_snapshot)
    let mut client_content_area: Rect = Rect::default();
    let mut client_copy_mode: bool = false;
    let mut client_zoomed: bool = false;
```

Also add a client-side border drag state struct and variable. Place the struct definition before `run_remote()` (or at the top of the file near other helper structs):

```rust
/// Client-side border drag state — tracks an in-progress separator resize.
struct ClientDragState {
    /// Tree path to the parent split node
    path: Vec<usize>,
    /// "Horizontal" or "Vertical"
    kind: String,
    /// Index of the left/top child in the split
    index: usize,
    /// Mouse position at drag start (in client terminal coords)
    start_pos: u16,
    /// Initial split sizes snapshot
    initial_sizes: Vec<u16>,
    /// Total pixels along the split axis in client's content area
    total_pixels: u16,
}
```

And the tracking variable near the other state (line ~607):

```rust
    let mut client_drag: Option<ClientDragState> = None;
```

- [ ] **Step 2: Add helper function to collect pane rects from LayoutJson**

Add near the existing `is_on_separator` function (around line 155):

```rust
/// Collect all leaf pane IDs and their absolute rects from a LayoutJson tree.
fn collect_pane_rects(node: &LayoutJson, area: Rect, out: &mut Vec<(usize, Rect)>) {
    match node {
        LayoutJson::Leaf { id, .. } => {
            out.push((*id, area));
        }
        LayoutJson::Split { kind, sizes, children } => {
            let effective_sizes: Vec<u16> = if sizes.len() == children.len() {
                sizes.clone()
            } else {
                vec![(100 / children.len().max(1)) as u16; children.len()]
            };
            let is_horizontal = kind == "Horizontal";
            let rects = split_with_gaps(is_horizontal, &effective_sizes, area);
            for (i, child) in children.iter().enumerate() {
                if i < rects.len() {
                    collect_pane_rects(child, rects[i], out);
                }
            }
        }
    }
}

/// Collect all split border positions from a LayoutJson tree.
/// Returns: (tree_path_to_parent, kind, child_index, border_pixel_pos, total_pixels, sizes_snapshot)
fn collect_layout_borders(
    node: &LayoutJson,
    area: Rect,
    path: &mut Vec<usize>,
    out: &mut Vec<(Vec<usize>, String, usize, u16, u16, Vec<u16>)>,
) {
    if let LayoutJson::Split { kind, sizes, children } = node {
        let effective_sizes: Vec<u16> = if sizes.len() == children.len() {
            sizes.clone()
        } else {
            vec![(100 / children.len().max(1)) as u16; children.len()]
        };
        let is_horizontal = kind == "Horizontal";
        let rects = split_with_gaps(is_horizontal, &effective_sizes, area);
        let total_px = if is_horizontal { area.width } else { area.height };
        for i in 0..children.len().saturating_sub(1) {
            if i < rects.len() {
                let pos = if is_horizontal {
                    rects[i].x + rects[i].width
                } else {
                    rects[i].y + rects[i].height
                };
                out.push((path.clone(), kind.clone(), i, pos, total_px, effective_sizes.clone()));
            }
        }
        for (i, child) in children.iter().enumerate() {
            if i < rects.len() {
                path.push(i);
                collect_layout_borders(child, rects[i], path, out);
                path.pop();
            }
        }
    }
}
```

- [ ] **Step 3: Populate pane rects and borders during rendering**

Inside the `terminal.draw(|f| { ... })` closure, after the layout tree (`root`) is available and `content_chunk` is computed (around line 2227 after `let (content_chunk, status_chunk) = ...`), add:

```rust
            // Populate client-side pane and border layout for mouse handling
            client_content_area = content_chunk;
            client_pane_rects.clear();
            collect_pane_rects(&root, content_chunk, &mut client_pane_rects);
            client_borders.clear();
            let mut border_path = Vec::new();
            collect_layout_borders(&root, content_chunk, &mut border_path, &mut client_borders);
```

Also track copy mode and zoom state. Find where `root` is obtained from DumpState (search for where `state.layout` or the layout tree variable is set — it's typically parsed from DumpState before the draw closure). Near where `client_base_index = base_index;` was added (line ~2049), add:

```rust
        client_copy_mode = active_pane_in_copy_mode(&root);
        client_zoomed = state.zoomed;
```

(`active_pane_in_copy_mode` is already defined in client.rs and used for the existing server_copy check.)

- [ ] **Step 4: Build and verify**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -5`
Expected: `Finished` (may have unused-variable warnings for the new state vars until mouse handler uses them)

- [ ] **Step 5: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/client.rs && git commit -m "feat: track pane rects and border positions during client rendering

Adds collect_pane_rects() and collect_layout_borders() to extract
layout geometry from the LayoutJson tree.  Results are stored in
client-side state variables for use by the mouse handler.

Confidence: high
Scope-risk: narrow"
```

---

## Task 7: Client — Rewrite Left-Click Handler (Pane Focus + Border Drag Start)

**Files:**
- Modify: `src/client.rs:1702-1761` (the `MouseEventKind::Down(MouseButton::Left)` block)

This replaces the raw `mouse-down X Y` with semantic commands for tab clicks (done), pane focus, border drag, copy mode, and PTY mouse forwarding.

- [ ] **Step 1: Rewrite the left-click handler**

Replace the entire `MouseEventKind::Down(MouseButton::Left)` block (lines 1702-1761) with:

```rust
                            MouseEventKind::Down(MouseButton::Left) => {
                                // Check if click is on a status bar tab
                                if me.row == client_status_row {
                                    let mut clicked_tab: Option<usize> = None;
                                    for &(win_idx, x_start, x_end) in &client_tab_positions {
                                        if me.column >= x_start && me.column < x_end {
                                            clicked_tab = Some(win_idx);
                                            break;
                                        }
                                    }
                                    if let Some(idx) = clicked_tab {
                                        let display_idx = idx + client_base_index;
                                        cmd_batch.push(format!("select-window -t :{}\n", display_idx));
                                    }
                                    // Status bar click — no text selection or mouse-down
                                } else {
                                    // Check if click is on a border (start resize drag)
                                    let mut on_border = false;
                                    if !client_zoomed {
                                        let tol = 1u16;
                                        for (bpath, bkind, bidx, bpos, btotal, bsizes) in &client_borders {
                                            let hit = if bkind == "Horizontal" {
                                                me.column >= bpos.saturating_sub(tol) && me.column <= bpos + tol
                                            } else {
                                                me.row >= bpos.saturating_sub(tol) && me.row <= bpos + tol
                                            };
                                            if hit {
                                                client_drag = Some(ClientDragState {
                                                    path: bpath.clone(),
                                                    kind: bkind.clone(),
                                                    index: *bidx,
                                                    start_pos: if bkind == "Horizontal" { me.column } else { me.row },
                                                    initial_sizes: bsizes.clone(),
                                                    total_pixels: *btotal,
                                                });
                                                border_drag = true;
                                                on_border = true;
                                                // Don't send anything to server yet — sizes sent on drag
                                                rsel_start = None;
                                                rsel_end = None;
                                                selection_changed = true;
                                                break;
                                            }
                                        }
                                    }

                                    if !on_border {
                                        // Find which pane was clicked
                                        let clicked_pane = client_pane_rects.iter().find(|(_, rect)| {
                                            rect.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                        });

                                        if let Some(&(pane_id, pane_rect)) = clicked_pane {
                                            // Focus the pane
                                            cmd_batch.push(format!("select-pane -t %{}\n", pane_id));

                                            // Compute pane-relative coordinates
                                            let rel_col = me.column as i16 - pane_rect.x as i16;
                                            let rel_row = me.row as i16 - pane_rect.y as i16;

                                            if client_copy_mode {
                                                // Copy mode: send pane-mouse for cursor positioning
                                                cmd_batch.push(format!("pane-mouse {} 0 {} {} M\n",
                                                    pane_id, rel_col, rel_row));
                                                rsel_start = None;
                                                rsel_end = None;
                                                selection_changed = true;
                                            } else {
                                                // Normal click: send pane-mouse for PTY forwarding
                                                // (server checks pane_wants_mouse internally)
                                                cmd_batch.push(format!("pane-mouse {} 0 {} {} M\n",
                                                    pane_id, rel_col, rel_row));

                                                // Start text selection (client-side)
                                                border_drag = false;
                                                rsel_start = Some((me.column, me.row));
                                                rsel_end = Some((me.column, me.row));
                                                rsel_dragged = false;
                                                selection_changed = true;
                                            }
                                        } else {
                                            // Click outside any pane — fallback to raw coords
                                            cmd_batch.push(format!("mouse-down {} {}\n", me.column, me.row));
                                        }
                                    }
                                }
                            }
```

- [ ] **Step 2: Build and verify**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -3`
Expected: `Finished` with no errors

- [ ] **Step 3: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/client.rs && git commit -m "feat: client-side pane focus and border drag detection on left-click

Left clicks now send semantic commands:
- Tab click: select-window (unchanged from prior commit)
- Pane click: select-pane + pane-mouse with pane-relative coords
- Border click: starts client-side drag tracking
- Copy mode: pane-mouse for cursor positioning

Falls back to raw mouse-down for clicks outside any pane.

Rejected: server-side detection | coordinates wrong when client size differs
Confidence: high
Scope-risk: moderate"
```

---

## Task 8: Client — Rewrite Drag and Mouse-Up Handlers

**Files:**
- Modify: `src/client.rs` (Drag(Left), Up(Left) sections)

- [ ] **Step 1: Rewrite the left-drag handler**

Find `MouseEventKind::Drag(MouseButton::Left)` (currently around line 1792 after our Task 7 changes). Replace the entire block:

```rust
                            MouseEventKind::Drag(MouseButton::Left) => {
                                if border_drag {
                                    // Client-side border resize: compute new split sizes
                                    if let Some(ref d) = client_drag {
                                        let current_pos = if d.kind == "Horizontal" { me.column } else { me.row };
                                        let pixel_delta = current_pos as i32 - d.start_pos as i32;
                                        let total_pct: i32 = d.initial_sizes.iter().map(|&s| s as i32).sum();
                                        let total_px = d.total_pixels.max(1) as i32;
                                        let pct_delta = (pixel_delta * total_pct) / total_px;
                                        let min_pct = 5i32;

                                        let mut new_sizes = d.initial_sizes.clone();
                                        let left = (d.initial_sizes[d.index] as i32 + pct_delta)
                                            .clamp(min_pct, d.initial_sizes[d.index] as i32 + d.initial_sizes[d.index + 1] as i32 - min_pct) as u16;
                                        let right = d.initial_sizes[d.index] + d.initial_sizes[d.index + 1] - left;
                                        new_sizes[d.index] = left;
                                        new_sizes[d.index + 1] = right;

                                        let path_str = d.path.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(".");
                                        let sizes_str = new_sizes.iter().map(|s| s.to_string()).collect::<Vec<_>>().join(",");
                                        cmd_batch.push(format!("split-sizes {} {}\n", path_str, sizes_str));
                                    }
                                } else if rsel_start.is_none() {
                                    // No client selection in progress (copy mode or suppressed)
                                    // Send pane-mouse for copy-mode drag selection
                                    if client_copy_mode {
                                        if let Some(&(pane_id, pane_rect)) = client_pane_rects.iter().find(|(_, r)| {
                                            r.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                        }) {
                                            let rel_col = me.column as i16 - pane_rect.x as i16;
                                            let rel_row = me.row as i16 - pane_rect.y as i16;
                                            cmd_batch.push(format!("pane-mouse {} 32 {} {} M\n",
                                                pane_id, rel_col, rel_row));
                                        }
                                    } else {
                                        // Fallback: raw coords (ratio mapping on server handles it)
                                        cmd_batch.push(format!("mouse-drag {} {}\n", me.column, me.row));
                                    }
                                } else {
                                    // Left-drag: extend text selection (client-side, pwsh behavior)
                                    if rsel_start.is_some() {
                                        rsel_end = Some((me.column, me.row));
                                        rsel_dragged = true;
                                        selection_changed = true;
                                    }
                                }
                            }
```

- [ ] **Step 2: Rewrite the left-up handler**

Find `MouseEventKind::Up(MouseButton::Left)` (around line 1810 after Task 7). Replace the entire block:

```rust
                            MouseEventKind::Up(MouseButton::Left) => {
                                if border_drag {
                                    // Border drag complete — tell server to resize PTYs
                                    cmd_batch.push(format!("split-resize-done\n"));
                                    border_drag = false;
                                    client_drag = None;
                                } else if rsel_dragged {
                                    // Left-drag completed — copy selected text to clipboard
                                    rsel_end = Some((me.column, me.row));
                                    if let (Some(s), Some(e)) = (rsel_start, rsel_end) {
                                        if let Ok(state) = serde_json::from_str::<DumpState>(&prev_dump_buf) {
                                            let text = extract_selection_text(&state.layout, content_height, s, e);
                                            if !text.is_empty() {
                                                copy_to_system_clipboard(&text);
                                                pending_osc52 = Some(text);
                                            }
                                        }
                                    }
                                    rsel_start = None;
                                    rsel_end = None;
                                    rsel_dragged = false;
                                    selection_changed = true;
                                } else {
                                    // Plain click release — send pane-mouse for copy-mode finalize
                                    rsel_start = None;
                                    rsel_end = None;
                                    selection_changed = true;
                                    if client_copy_mode {
                                        if let Some(&(pane_id, pane_rect)) = client_pane_rects.iter().find(|(_, r)| {
                                            r.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                        }) {
                                            let rel_col = me.column as i16 - pane_rect.x as i16;
                                            let rel_row = me.row as i16 - pane_rect.y as i16;
                                            cmd_batch.push(format!("pane-mouse {} 0 {} {} m\n",
                                                pane_id, rel_col, rel_row));
                                        }
                                    } else {
                                        // Fallback for non-copy-mode release
                                        cmd_batch.push(format!("mouse-up {} {}\n", me.column, me.row));
                                    }
                                }
                            }
```

- [ ] **Step 3: Build and verify**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -3`
Expected: `Finished` with no errors

- [ ] **Step 4: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/client.rs && git commit -m "feat: client-side border drag and semantic mouse-up handling

Border drag: client computes percentage deltas in its own coordinate
space using split-sizes command.  PTY resize deferred to drag end
via split-resize-done.

Mouse-up: pane-mouse with pane-relative coords for copy mode.
Raw fallback for non-copy non-border releases.

Rejected: server-side pixel→pct conversion | uses wrong total_pixels when client size differs
Confidence: high
Scope-risk: moderate"
```

---

## Task 9: Client — Rewrite Right-Click, Middle-Click, Scroll, and Hover Handlers

**Files:**
- Modify: `src/client.rs` (remaining mouse event handlers)

- [ ] **Step 1: Rewrite right-click handler**

Find `MouseEventKind::Down(MouseButton::Right)`. The existing code sends `mouse-down-right X Y` when TUI is active. Change the TUI branch to use pane-mouse:

In the `if tui_active` branch, replace `cmd_batch.push(format!("mouse-down-right {} {}\n", me.column, me.row));` with:

```rust
                                    // TUI app: send pane-relative right-click
                                    if let Some(&(pane_id, pane_rect)) = client_pane_rects.iter().find(|(_, r)| {
                                        r.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                    }) {
                                        let rel_col = me.column as i16 - pane_rect.x as i16;
                                        let rel_row = me.row as i16 - pane_rect.y as i16;
                                        cmd_batch.push(format!("pane-mouse {} 2 {} {} M\n",
                                            pane_id, rel_col, rel_row));
                                    }
```

- [ ] **Step 2: Rewrite middle-click handler**

Find `MouseEventKind::Down(MouseButton::Middle)`. Replace the `cmd_batch.push(format!("mouse-down-middle {} {}\n", ...))` with:

```rust
                            MouseEventKind::Down(MouseButton::Middle) => {
                                if let Some(&(pane_id, pane_rect)) = client_pane_rects.iter().find(|(_, r)| {
                                    r.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                }) {
                                    let rel_col = me.column as i16 - pane_rect.x as i16;
                                    let rel_row = me.row as i16 - pane_rect.y as i16;
                                    cmd_batch.push(format!("pane-mouse {} 1 {} {} M\n",
                                        pane_id, rel_col, rel_row));
                                } else {
                                    cmd_batch.push(format!("mouse-down-middle {} {}\n", me.column, me.row));
                                }
                            }
```

- [ ] **Step 3: Rewrite scroll-up and scroll-down handlers**

Find `MouseEventKind::ScrollUp`. Replace the existing block:

```rust
                            MouseEventKind::ScrollUp => {
                                rsel_start = None;
                                rsel_end = None;
                                rsel_dragged = false;
                                selection_changed = true;
                                if let Some(&(pane_id, _)) = client_pane_rects.iter().find(|(_, r)| {
                                    r.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                }) {
                                    cmd_batch.push(format!("pane-scroll {} up\n", pane_id));
                                } else {
                                    cmd_batch.push(format!("scroll-up {} {}\n", me.column, me.row));
                                }
                            }
```

Find `MouseEventKind::ScrollDown`. Replace similarly:

```rust
                            MouseEventKind::ScrollDown => {
                                rsel_start = None;
                                rsel_end = None;
                                rsel_dragged = false;
                                selection_changed = true;
                                if let Some(&(pane_id, _)) = client_pane_rects.iter().find(|(_, r)| {
                                    r.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                }) {
                                    cmd_batch.push(format!("pane-scroll {} down\n", pane_id));
                                } else {
                                    cmd_batch.push(format!("scroll-down {} {}\n", me.column, me.row));
                                }
                            }
```

- [ ] **Step 4: Rewrite mouse-move (hover) handler**

Find `MouseEventKind::Moved`. Replace:

```rust
                            MouseEventKind::Moved => {
                                if let Some(&(pane_id, pane_rect)) = client_pane_rects.iter().find(|(_, r)| {
                                    r.contains(ratatui::layout::Position { x: me.column, y: me.row })
                                }) {
                                    let rel_col = me.column as i16 - pane_rect.x as i16;
                                    let rel_row = me.row as i16 - pane_rect.y as i16;
                                    cmd_batch.push(format!("pane-mouse {} 35 {} {} M\n",
                                        pane_id, rel_col, rel_row));
                                } else {
                                    cmd_batch.push(format!("mouse-move {} {}\n", me.column, me.row));
                                }
                            }
```

- [ ] **Step 5: Build and verify**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -3`
Expected: `Finished` with no errors

- [ ] **Step 6: Commit**

```bash
cd "C:/1-Git/psmux-mouse-fix" && git add src/client.rs && git commit -m "feat: semantic right-click, middle-click, scroll, and hover handling

All remaining mouse interactions now use pane-relative coordinates
via pane-mouse and pane-scroll commands.  Raw coordinate fallbacks
remain for edge cases (click outside all panes) and are protected
by the server-side ratio mapping.

Confidence: high
Scope-risk: moderate"
```

---

## Task 10: Final Build, Clippy, and Test

**Files:** All modified files

- [ ] **Step 1: Full build**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors

- [ ] **Step 2: Clippy**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo clippy 2>&1 | tail -20`
Expected: No warnings in changed files (pre-existing warnings in portable-pty-psmux are OK)

Fix any clippy warnings that appear in our changed code.

- [ ] **Step 3: Run tests**

Run: `cd "C:/1-Git/psmux-mouse-fix" && cargo test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 4: Review the full diff**

Run: `cd "C:/1-Git/psmux-mouse-fix" && git diff upstream/master --stat`

Verify all changes are in expected files: `client.rs`, `window_ops.rs`, `types.rs`, `server/connection.rs`, `server/mod.rs`

- [ ] **Step 5: Verify git log shows clean commit history**

Run: `cd "C:/1-Git/psmux-mouse-fix" && git log --oneline upstream/master..HEAD`

Expected: Clean sequence of commits, each with a focused purpose.
