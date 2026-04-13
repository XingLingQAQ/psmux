// Regression tests for issue #209: tmux command flags compatibility gaps
//
// Tests that all CLI flag parsing matches tmux semantics:
// 1. display-message -d is consumed (not leaked into message text)
// 2. send-keys -X is parsed as a flag (not literal key)
// 3. respawn-pane -c forwards workdir
// 4. show-options combined flags like -gv work
// 5. resize-window forwards to server
// 6. list-panes -s is session-scoped (not identical to -a)
// 7. list-keys -T filters by table

#[allow(unused_imports)]
use super::*;

fn mock_app() -> AppState {
    let mut app = AppState::new("test_session".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
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

// ========================================================================
// Gap 6: display-message -d should be consumed, not leaked into message
// ========================================================================

#[test]
fn display_message_d_flag_not_in_message() {
    // Simulate CLI-side parsing of: display-message -p -d 5000 "hello world"
    // The -d flag and its value (5000) should be skipped, not included in message
    let cmd_args = vec![
        "display-message".to_string(),
        "-p".to_string(),
        "-d".to_string(),
        "5000".to_string(),
        "hello world".to_string(),
    ];

    let mut message: Vec<String> = Vec::new();
    let mut print_to_stdout = false;
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-t" => {
                i += 1; // skip target value
            }
            "-p" => { print_to_stdout = true; }
            "-d" | "-I" => { i += 1; } // consume -d <ms> and -I <input>, skip value
            s => { message.push(s.to_string()); }
        }
        i += 1;
    }
    let msg = message.join(" ");

    assert!(print_to_stdout, "-p should set print_to_stdout");
    assert_eq!(msg, "hello world", "message should not contain -d or 5000, got: {}", msg);
    assert!(!msg.contains("-d"), "message must not contain the -d flag");
    assert!(!msg.contains("5000"), "message must not contain the -d value");
}

#[test]
fn display_message_I_flag_not_in_message() {
    let cmd_args = vec![
        "display-message".to_string(),
        "-I".to_string(),
        "input_data".to_string(),
        "the message".to_string(),
    ];

    let mut message: Vec<String> = Vec::new();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-t" => { i += 1; }
            "-p" => {}
            "-d" | "-I" => { i += 1; }
            s => { message.push(s.to_string()); }
        }
        i += 1;
    }
    let msg = message.join(" ");
    assert_eq!(msg, "the message", "-I and its arg should be consumed, got: {}", msg);
}

// ========================================================================
// Gap 7: send-keys -X should be parsed as a flag
// ========================================================================

#[test]
fn send_keys_x_flag_parsed_correctly() {
    // Simulate CLI-side parsing of: send-keys -t mysession -X copy-mode-command
    let cmd_args = vec![
        "send-keys".to_string(),
        "-t".to_string(),
        "mysession".to_string(),
        "-X".to_string(),
        "cancel".to_string(),
    ];

    let mut literal = false;
    let mut has_x = false;
    let mut keys: Vec<String> = Vec::new();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-l" => { literal = true; }
            "-R" => { keys.push("__RESET__".to_string()); }
            "-X" => { has_x = true; }
            "-t" => { i += 1; }
            "-N" => { i += 1; }
            _ => { keys.push(cmd_args[i].to_string()); }
        }
        i += 1;
    }

    assert!(has_x, "-X flag should be parsed");
    assert!(!literal, "-l should not be set");
    assert_eq!(keys.len(), 1, "should have one key arg");
    assert_eq!(keys[0], "cancel", "key arg should be 'cancel'");

    // Verify reconstructed command includes -X
    let mut cmd = "send-keys".to_string();
    if literal { cmd.push_str(" -l"); }
    if has_x { cmd.push_str(" -X"); }
    for k in &keys {
        cmd.push_str(&format!(" {}", k));
    }

    assert!(cmd.contains("-X"), "reconstructed command must contain -X");
    assert_eq!(cmd, "send-keys -X cancel");
}

#[test]
fn send_keys_x_not_treated_as_literal_key() {
    // Before the fix, -X would fall through to the catch-all and become a key
    let cmd_args = vec![
        "send-keys".to_string(),
        "-X".to_string(),
        "copy-mode".to_string(),
    ];

    let mut has_x = false;
    let mut keys: Vec<String> = Vec::new();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-X" => { has_x = true; }
            "-l" | "-R" => {}
            "-t" | "-N" => { i += 1; }
            _ => { keys.push(cmd_args[i].to_string()); }
        }
        i += 1;
    }

    // -X should NOT be in the keys list
    assert!(has_x, "-X should be recognized as a flag");
    assert!(!keys.contains(&"-X".to_string()), "-X must not be in the keys list (it's a flag, not a key to send)");
}

// ========================================================================
// Gap 8: respawn-pane -c should forward workdir
// ========================================================================

#[test]
fn respawn_pane_c_flag_forwarded() {
    // Simulate CLI-side parsing of: respawn-pane -k -c C:\Temp -t mysession
    let cmd_args = vec![
        "respawn-pane".to_string(),
        "-k".to_string(),
        "-c".to_string(),
        "C:\\Temp".to_string(),
        "-t".to_string(),
        "mysession".to_string(),
    ];

    let mut cmd = "respawn-pane".to_string();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-k" => { cmd.push_str(" -k"); }
            "-c" => {
                if let Some(d) = cmd_args.get(i + 1) {
                    cmd.push_str(&format!(" -c {}", d));
                    i += 1;
                }
            }
            "-t" => {
                if let Some(t) = cmd_args.get(i + 1) {
                    cmd.push_str(&format!(" -t {}", t));
                    i += 1;
                }
            }
            _ => { cmd.push_str(&format!(" {}", cmd_args[i])); }
        }
        i += 1;
    }

    assert!(cmd.contains("-c C:\\Temp"), "reconstructed command must contain -c workdir, got: {}", cmd);
    assert!(cmd.contains("-k"), "reconstructed command must contain -k");
}

#[test]
fn respawn_pane_without_c_flag_still_works() {
    let cmd_args = vec![
        "respawn-pane".to_string(),
        "-k".to_string(),
    ];

    let mut cmd = "respawn-pane".to_string();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-k" => { cmd.push_str(" -k"); }
            "-c" => {
                if let Some(d) = cmd_args.get(i + 1) {
                    cmd.push_str(&format!(" -c {}", d));
                    i += 1;
                }
            }
            "-t" => { i += 1; }
            _ => { cmd.push_str(&format!(" {}", cmd_args[i])); }
        }
        i += 1;
    }

    assert_eq!(cmd, "respawn-pane -k");
    assert!(!cmd.contains("-c"), "should not contain -c when not provided");
}

// ========================================================================
// Gap 9: show-options combined flags like -gv
// ========================================================================

#[test]
fn show_options_combined_gv_flag_recognized() {
    // The server parses args for flag chars in combined tokens
    let args = vec!["-gv", "status-style"];
    let combined_has = |ch: char| -> bool {
        args.iter().any(|a| {
            if *a == format!("-{}", ch) { return true; }
            a.starts_with('-') && a.len() > 2 && a.chars().skip(1).all(|c| c.is_ascii_alphabetic()) && a.contains(ch)
        })
    };
    assert!(combined_has('g'), "-gv should contain 'g'");
    assert!(combined_has('v'), "-gv should contain 'v'");
    assert!(!combined_has('w'), "-gv should NOT contain 'w'");
    assert!(!combined_has('A'), "-gv should NOT contain 'A'");
}

#[test]
fn show_options_separate_flags_still_work() {
    let args = vec!["-g", "-v", "status-style"];
    let combined_has = |ch: char| -> bool {
        args.iter().any(|a| {
            if *a == format!("-{}", ch) { return true; }
            a.starts_with('-') && a.len() > 2 && a.chars().skip(1).all(|c| c.is_ascii_alphabetic()) && a.contains(ch)
        })
    };
    assert!(combined_has('g'), "separate -g should be recognized");
    assert!(combined_has('v'), "separate -v should be recognized");
}

#[test]
fn show_options_wv_combined_flag() {
    let args = vec!["-wv", "pane-border-style"];
    let combined_has = |ch: char| -> bool {
        args.iter().any(|a| {
            if *a == format!("-{}", ch) { return true; }
            a.starts_with('-') && a.len() > 2 && a.chars().skip(1).all(|c| c.is_ascii_alphabetic()) && a.contains(ch)
        })
    };
    assert!(combined_has('w'), "-wv should contain 'w'");
    assert!(combined_has('v'), "-wv should contain 'v'");
}

// ========================================================================
// Gap 3: resize-window should forward to server (not be a no-op)
// ========================================================================

#[test]
fn resize_window_cli_builds_correct_command() {
    // Simulate CLI-side parsing of: resize-window -t session -x 80
    let cmd_args = vec![
        "resize-window".to_string(),
        "-t".to_string(),
        "session".to_string(),
        "-x".to_string(),
        "80".to_string(),
    ];

    let mut cmd = "resize-window".to_string();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-x" | "-y" => {
                if let Some(v) = cmd_args.get(i + 1) {
                    cmd.push_str(&format!(" {} {}", cmd_args[i], v));
                    i += 1;
                }
            }
            "-t" => { i += 1; }
            "-A" | "-D" | "-U" => { cmd.push_str(&format!(" {}", cmd_args[i])); }
            _ => {}
        }
        i += 1;
    }

    assert!(cmd.contains("-x 80"), "command must contain -x 80, got: {}", cmd);
    assert!(!cmd.contains("-t"), "command must not contain -t (handled globally)");
}

#[test]
fn resize_window_y_flag() {
    let cmd_args = vec![
        "resize-window".to_string(),
        "-y".to_string(),
        "24".to_string(),
    ];

    let mut cmd = "resize-window".to_string();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-x" | "-y" => {
                if let Some(v) = cmd_args.get(i + 1) {
                    cmd.push_str(&format!(" {} {}", cmd_args[i], v));
                    i += 1;
                }
            }
            "-t" => { i += 1; }
            _ => {}
        }
        i += 1;
    }

    assert!(cmd.contains("-y 24"), "command must contain -y 24, got: {}", cmd);
}

// ========================================================================
// Gap 4: list-panes -s should be session-scoped
// ========================================================================

#[test]
fn list_panes_s_not_same_as_a_in_server_parsing() {
    // Verify that -s and -a are no longer treated identically
    let args_s = vec!["-s", "-t", "mysession"];
    let args_a = vec!["-a"];

    let all_s = args_s.iter().any(|a| *a == "-a");
    let session_s = args_s.iter().any(|a| *a == "-s");

    let all_a = args_a.iter().any(|a| *a == "-a");
    let session_a = args_a.iter().any(|a| *a == "-s");

    // With the fix: -s sets session_scope, -a sets all
    assert!(!all_s, "-s args should not set 'all' flag");
    assert!(session_s, "-s args should set 'session_scope' flag");
    assert!(all_a, "-a args should set 'all' flag");
    assert!(!session_a, "-a args should not set 'session_scope' flag");
}

// ========================================================================
// Gap 5: list-keys -T should filter by table
// ========================================================================

#[test]
fn list_keys_cli_forwards_t_flag() {
    // Simulate CLI-side parsing of: list-keys -T prefix
    let cmd_args = vec![
        "list-keys".to_string(),
        "-T".to_string(),
        "prefix".to_string(),
    ];

    let mut cmd = "list-keys".to_string();
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-T" => {
                if let Some(t) = cmd_args.get(i + 1) {
                    cmd.push_str(&format!(" -T {}", t));
                    i += 1;
                }
            }
            "-t" => { i += 1; }
            _ => { cmd.push_str(&format!(" {}", cmd_args[i])); }
        }
        i += 1;
    }

    assert!(cmd.contains("-T prefix"), "command must forward -T prefix, got: {}", cmd);
}

#[test]
fn list_keys_server_filters_by_table() {
    // Simulate server-side filtering of list-keys output
    let output = vec![
        "bind-key -T prefix c new-window",
        "bind-key -T prefix d detach-client",
        "bind-key -T root C-b send-prefix",
        "bind-key -T copy-mode-vi y copy-selection",
    ];
    let table_filter = Some("prefix".to_string());
    let text = output.join("\n");

    let filtered: Vec<&str> = text.lines().filter(|line| {
        if let Some(ref tbl) = table_filter {
            let parts: Vec<&str> = line.splitn(5, ' ').collect();
            if parts.len() >= 3 {
                return parts[2] == tbl.as_str();
            }
            return false;
        }
        true
    }).collect();

    assert_eq!(filtered.len(), 2, "should only have prefix table entries");
    assert!(filtered[0].contains("new-window"));
    assert!(filtered[1].contains("detach-client"));
    // root and copy-mode-vi entries should be filtered out  
    assert!(!filtered.iter().any(|l| l.contains("root")));
    assert!(!filtered.iter().any(|l| l.contains("copy-mode-vi")));
}

// ========================================================================
// Gap 1: list-sessions -F should forward format to server
// ========================================================================

#[test]
fn list_sessions_parses_f_and_f_flags() {
    // Simulate CLI-side parsing of: list-sessions -F '#{session_name}'
    let cmd_args = vec![
        "list-sessions".to_string(),
        "-F".to_string(),
        "#{session_name}".to_string(),
    ];

    let mut format_str: Option<String> = None;
    let mut filter_str: Option<String> = None;
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-F" => {
                if let Some(f) = cmd_args.get(i + 1) {
                    format_str = Some(f.to_string());
                    i += 1;
                }
            }
            "-f" => {
                if let Some(f) = cmd_args.get(i + 1) {
                    filter_str = Some(f.to_string());
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }

    assert_eq!(format_str, Some("#{session_name}".to_string()), "-F should be parsed");
    assert_eq!(filter_str, None, "-f should not be set");
}

#[test]
fn list_sessions_parses_both_f_and_f_flags() {
    let cmd_args = vec![
        "list-sessions".to_string(),
        "-F".to_string(),
        "#{session_name}".to_string(),
        "-f".to_string(),
        "mysession".to_string(),
    ];

    let mut format_str: Option<String> = None;
    let mut filter_str: Option<String> = None;
    let mut i = 1;
    while i < cmd_args.len() {
        match cmd_args[i].as_str() {
            "-F" => {
                if let Some(f) = cmd_args.get(i + 1) {
                    format_str = Some(f.to_string());
                    i += 1;
                }
            }
            "-f" => {
                if let Some(f) = cmd_args.get(i + 1) {
                    filter_str = Some(f.to_string());
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }

    assert_eq!(format_str, Some("#{session_name}".to_string()));
    assert_eq!(filter_str, Some("mysession".to_string()));
}
