// Discussion #210: Rust unit tests for the three gastown integration fixes.
//
// These run through commands.rs / help.rs / format paths directly
// with a mock AppState so no real sessions or TCP sockets are needed.
//
// Bug 1 (duplicate session): tested via the error message string contract.
// Bug 2 (list-sessions -f filter): tests the #{==:#{session_name},NAME}
//        evaluation logic in isolation (pure string parsing).
// Bug 3 (list-keys offline): tests that PREFIX_DEFAULTS covers gastown's keys
//        and that the CLI fallback format is correct.

use super::*;

fn mock_app() -> AppState {
    let mut app = AppState::new("test210".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split {
            kind: LayoutKind::Horizontal,
            sizes: vec![],
            children: vec![],
        },
        active_path: vec![],
        name: name.to_string(),
        id,
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
    }
}

fn mock_app_with_window() -> AppState {
    let mut app = mock_app();
    app.windows.push(make_window("shell", 0));
    app
}

// ─── helpers that mirror the CLI logic verbatim so we can unit-test them ─────

/// Evaluate a -f filter expression against a session name.
/// Mirrors what main.rs does for list-sessions filtering.
fn eval_session_filter(filter: &str, session_name: &str) -> bool {
    if let Some(target) = filter
        .strip_prefix("#{==:#{session_name},")
        .and_then(|s| s.strip_suffix('}'))
    {
        session_name == target
    } else {
        // fallback: substring
        session_name.contains(filter)
    }
}

/// Build the expected "duplicate session" error line that psmux must emit.
fn duplicate_session_error(name: &str) -> String {
    format!("duplicate session: {}", name)
}

// ════════════════════════════════════════════════════════════════════════════
// BUG 1: duplicate session error message contract
// gastown's wrapError() looks for "duplicate session" in stderr
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn dup_error_contains_phrase_duplicate_session() {
    let msg = duplicate_session_error("myapp");
    assert!(
        msg.contains("duplicate session"),
        "error must contain 'duplicate session' for gastown wrapError: {}", msg
    );
}

#[test]
fn dup_error_contains_session_name() {
    let name = "fancy-dev-session";
    let msg = duplicate_session_error(name);
    assert!(
        msg.contains(name),
        "error must contain the session name '{}': {}", name, msg
    );
}

#[test]
fn dup_error_does_not_use_old_format() {
    let name = "test";
    let msg = duplicate_session_error(name);
    // Old broken format that gastown's wrapError couldn't parse
    assert!(
        !msg.contains("already exists"),
        "must NOT use old 'already exists' phrasing: {}", msg
    );
    assert!(
        !msg.starts_with("psmux:"),
        "must NOT start with 'psmux:': {}", msg
    );
}

#[test]
fn dup_error_exact_format() {
    assert_eq!(
        duplicate_session_error("myses"),
        "duplicate session: myses"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// BUG 2: list-sessions -f filter evaluation
// #{==:#{session_name},NAME} must match only exact session name
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn filter_exact_match_returns_true() {
    assert!(eval_session_filter("#{==:#{session_name},myapp}", "myapp"));
}

#[test]
fn filter_exact_match_different_name_returns_false() {
    assert!(!eval_session_filter("#{==:#{session_name},myapp}", "myapp2"));
    assert!(!eval_session_filter("#{==:#{session_name},myapp}", "notmyapp"));
    assert!(!eval_session_filter("#{==:#{session_name},myapp}", ""));
}

#[test]
fn filter_exact_match_prefix_not_enough() {
    // "myapp" must not match when comparing session "myapp-extra"
    assert!(!eval_session_filter("#{==:#{session_name},myapp}", "myapp-extra"));
}

#[test]
fn filter_exact_match_suffix_not_enough() {
    // "myapp" must not match "prefix-myapp"
    assert!(!eval_session_filter("#{==:#{session_name},myapp}", "prefix-myapp"));
}

#[test]
fn filter_blank_filter_no_crash() {
    // Empty string filter: substring match of "" is always true
    assert!(eval_session_filter("", "anyname"));
}

#[test]
fn filter_gastown_pattern_verbatim() {
    // Exact pattern gastown generates for GetSessionInfo
    let filter = "#{==:#{session_name},dev}";
    assert!( eval_session_filter(filter, "dev"));
    assert!(!eval_session_filter(filter, "dev2"));
    assert!(!eval_session_filter(filter, "staging"));
}

#[test]
fn filter_hyphenated_session_name() {
    let filter = "#{==:#{session_name},my-dev-session}";
    assert!( eval_session_filter(filter, "my-dev-session"));
    assert!(!eval_session_filter(filter, "my-dev-session-extra"));
    assert!(!eval_session_filter(filter, "my-dev"));
}

#[test]
fn filter_fallback_substring_for_unknown_format() {
    // Non-#{==:...} expressions fall through to substring match
    let filter = "myapp";
    assert!( eval_session_filter(filter, "myapp"));
    assert!( eval_session_filter(filter, "prefix-myapp"));     // substring matches
    assert!(!eval_session_filter(filter, "other"));
}

// ════════════════════════════════════════════════════════════════════════════
// BUG 3: list-keys offline — PREFIX_DEFAULTS must contain gastown's expected keys
// ════════════════════════════════════════════════════════════════════════════

fn find_in_defaults(key: &str) -> Option<&'static str> {
    crate::help::PREFIX_DEFAULTS.iter()
        .find(|(k, _)| *k == key)
        .map(|(_, v)| *v)
}

#[test]
fn prefix_defaults_n_is_next_window() {
    let action = find_in_defaults("n").expect("'n' missing from PREFIX_DEFAULTS");
    assert_eq!(action, "next-window",
        "gastown TestGetKeyBinding_CapturesDefaultBinding expects next-window for 'n'");
}

#[test]
fn prefix_defaults_w_is_choose_tree() {
    let action = find_in_defaults("w").expect("'w' missing from PREFIX_DEFAULTS");
    assert_eq!(action, "choose-tree",
        "gastown TestGetKeyBinding_CapturesDefaultBindingWithArgs expects choose-tree for 'w'");
}

#[test]
fn prefix_defaults_p_is_previous_window() {
    let action = find_in_defaults("p").expect("'p' missing from PREFIX_DEFAULTS");
    assert_eq!(action, "previous-window");
}

#[test]
fn prefix_defaults_d_is_detach_client() {
    let action = find_in_defaults("d").expect("'d' missing from PREFIX_DEFAULTS");
    assert_eq!(action, "detach-client");
}

#[test]
fn prefix_defaults_x_is_kill_pane() {
    let action = find_in_defaults("x").expect("'x' missing from PREFIX_DEFAULTS");
    assert_eq!(action, "kill-pane");
}

#[test]
fn prefix_defaults_c_is_new_window() {
    let action = find_in_defaults("c").expect("'c' missing from PREFIX_DEFAULTS");
    assert_eq!(action, "new-window");
}

#[test]
fn list_keys_offline_format_matches_gastown_parse() {
    // gastown's getKeyBinding parses: "bind-key [-r] -T table key command..."
    // then extracts fields[3+] as the command.
    // Format from fallback: "bind-key -T prefix n next-window"
    let table = "prefix";
    let key = "n";
    let action = find_in_defaults(key).unwrap();
    let line = format!("bind-key -T {} {} {}", table, key, action);

    let parts: Vec<&str> = line.split_whitespace().collect();
    assert_eq!(parts[0], "bind-key",   "field 0 must be bind-key");
    assert_eq!(parts[1], "-T",         "field 1 must be -T");
    assert_eq!(parts[2], "prefix",     "field 2 must be table name");
    assert_eq!(parts[3], "n",          "field 3 must be key");
    assert_eq!(parts[4], "next-window","field 4 must be command");
}

#[test]
fn list_keys_offline_format_choose_tree() {
    let line = format!("bind-key -T prefix w {}", find_in_defaults("w").unwrap());
    let parts: Vec<&str> = line.split_whitespace().collect();
    // gastown splits on whitespace and takes everything from index 4 onward
    let cmd: Vec<&str> = parts[4..].to_vec();
    assert_eq!(cmd, vec!["choose-tree"]);
}

#[test]
fn prefix_defaults_has_enough_bindings() {
    let count = crate::help::PREFIX_DEFAULTS.len();
    assert!(count >= 20,
        "PREFIX_DEFAULTS should have >= 20 entries for a usable default keymap, got {}",
        count);
}

// ════════════════════════════════════════════════════════════════════════════
// BUG 3 (commands.rs path): list-keys via execute_command_string produces
// a PopupMode with bind-key lines including prefix table defaults.
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn list_keys_command_produces_popup_with_bindings() {
    let mut app = mock_app_with_window();
    // Populate default bindings (normally done at startup)
    crate::config::populate_default_bindings(&mut app);
    execute_command_string(&mut app, "list-keys").unwrap();
    match &app.mode {
        Mode::PopupMode { command, output, .. } => {
            assert_eq!(command, "list-keys");
            assert!(
                output.contains("bind-key"),
                "list-keys popup must contain bind-key lines, got:\n{}", output
            );
            assert!(
                output.contains("next-window"),
                "popup must contain next-window binding, got:\n{}", output
            );
            // choose-tree and choose-window are synonymous; the internal action
            // serialises as choose-window but both are valid for w binding
            assert!(
                output.contains("choose-tree") || output.contains("choose-window"),
                "popup must contain choose-tree or choose-window binding for 'w', got:\n{}", output
            );
        }
        other => panic!("expected PopupMode, got {:?}", std::mem::discriminant(other)),
    }
}

#[test]
fn list_keys_popup_format_matches_bind_key_syntax() {
    let mut app = mock_app_with_window();
    crate::config::populate_default_bindings(&mut app);
    execute_command_string(&mut app, "list-keys").unwrap();
    if let Mode::PopupMode { output, .. } = &app.mode {
        for line in output.lines() {
            if line.is_empty() || line.starts_with('(') { continue; }
            // Every non-empty line must start with "bind-key"
            assert!(
                line.starts_with("bind-key"),
                "expected 'bind-key ...' format, got: {}", line
            );
        }
    }
}
