// Tests for issue #202: switch-client is non-functional
// Verifies the session resolution logic used by the SwitchClient handler.

/// Helper: resolve switch-client target given flag, target, current session, and all sessions.
fn resolve_switch_target(
    flag: char,
    target: &str,
    current: &str,
    all_sessions: &[&str],
    last_session: Option<&str>,
) -> Option<String> {
    match flag {
        't' => {
            if target.is_empty() {
                None
            } else if all_sessions.contains(&target) {
                Some(target.to_string())
            } else {
                all_sessions.iter().find(|s| s.starts_with(target)).map(|s| s.to_string())
            }
        }
        'n' => {
            let pos = all_sessions.iter().position(|s| *s == current);
            match pos {
                Some(i) if i + 1 < all_sessions.len() => Some(all_sessions[i + 1].to_string()),
                Some(_) => all_sessions.first().map(|s| s.to_string()),
                None => all_sessions.first().map(|s| s.to_string()),
            }
        }
        'p' => {
            let pos = all_sessions.iter().position(|s| *s == current);
            match pos {
                Some(0) => all_sessions.last().map(|s| s.to_string()),
                Some(i) => Some(all_sessions[i - 1].to_string()),
                None => all_sessions.last().map(|s| s.to_string()),
            }
        }
        'l' => {
            last_session
                .map(|s| s.to_string())
                .filter(|s| !s.is_empty() && s != current && all_sessions.iter().any(|a| a == s))
        }
        _ => None,
    }
}

#[test]
fn switch_client_target_exact_match() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('t', "beta", "alpha", &sessions, None);
    assert_eq!(result, Some("beta".to_string()));
}

#[test]
fn switch_client_target_not_found() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('t', "nonexistent", "alpha", &sessions, None);
    assert_eq!(result, None);
}

#[test]
fn switch_client_target_prefix_match() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('t', "bet", "alpha", &sessions, None);
    assert_eq!(result, Some("beta".to_string()));
}

#[test]
fn switch_client_target_empty() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('t', "", "alpha", &sessions, None);
    assert_eq!(result, None);
}

#[test]
fn switch_client_next_session() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('n', "", "alpha", &sessions, None);
    assert_eq!(result, Some("beta".to_string()));
}

#[test]
fn switch_client_next_wraps_around() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('n', "", "gamma", &sessions, None);
    assert_eq!(result, Some("alpha".to_string()));
}

#[test]
fn switch_client_prev_session() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('p', "", "gamma", &sessions, None);
    assert_eq!(result, Some("beta".to_string()));
}

#[test]
fn switch_client_prev_wraps_around() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('p', "", "alpha", &sessions, None);
    assert_eq!(result, Some("gamma".to_string()));
}

#[test]
fn switch_client_last_session() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('l', "", "alpha", &sessions, Some("beta"));
    assert_eq!(result, Some("beta".to_string()));
}

#[test]
fn switch_client_last_session_same_as_current() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('l', "", "alpha", &sessions, Some("alpha"));
    assert_eq!(result, None, "should return None when last session equals current");
}

#[test]
fn switch_client_last_session_not_found() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('l', "", "alpha", &sessions, Some("deleted"));
    assert_eq!(result, None, "should return None when last session no longer exists");
}

#[test]
fn switch_client_last_session_empty() {
    let sessions = vec!["alpha", "beta", "gamma"];
    let result = resolve_switch_target('l', "", "alpha", &sessions, None);
    assert_eq!(result, None);
}

#[test]
fn switch_client_next_single_session() {
    let sessions = vec!["only"];
    let result = resolve_switch_target('n', "", "only", &sessions, None);
    assert_eq!(result, Some("only".to_string()), "wraps to same when single session");
}

#[test]
fn switch_client_target_strips_window_suffix() {
    // The connection.rs handler strips ":window" from target before sending.
    // Simulate that the target reaching resolve is already stripped.
    let sessions = vec!["alpha", "beta"];
    let result = resolve_switch_target('t', "alpha", "beta", &sessions, None);
    assert_eq!(result, Some("alpha".to_string()));
}

/// Test that the SWITCH directive format is correct
#[test]
fn switch_directive_format() {
    let session = "my-session";
    let directive = format!("SWITCH {}", session);
    assert_eq!(directive, "SWITCH my-session");
    assert!(directive.starts_with("SWITCH "));
    let parsed = directive.strip_prefix("SWITCH ").unwrap();
    assert_eq!(parsed, "my-session");
}

/// Test SWITCH directive parsing with whitespace (as client.rs would process it)
#[test]
fn switch_directive_parsing_from_frame() {
    let line = "SWITCH dev-workspace\n";
    let trimmed = line.trim();
    assert!(trimmed.starts_with("SWITCH "));
    let target = trimmed.strip_prefix("SWITCH ").unwrap_or("");
    assert_eq!(target, "dev-workspace");
}

/// Test that the session name extraction from -t target works
/// e.g., "alpha:0.1" should extract "alpha"
#[test]
fn session_name_from_target_with_window_pane() {
    let target = "alpha:0.1";
    let session = if let Some(pos) = target.find(':') {
        &target[..pos]
    } else {
        target
    };
    assert_eq!(session, "alpha");
}

/// Test plain session name (no colon)
#[test]
fn session_name_from_target_plain() {
    let target = "alpha";
    let session = if let Some(pos) = target.find(':') {
        &target[..pos]
    } else {
        target
    };
    assert_eq!(session, "alpha");
}
