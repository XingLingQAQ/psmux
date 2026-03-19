use super::should_spawn_warm_server;
use crate::types::AppState;

#[test]
fn warm_server_is_disabled_for_destroy_unattached_sessions() {
    let mut app = AppState::new("demo".to_string());
    app.destroy_unattached = true;
    assert!(!should_spawn_warm_server(&app));
}

#[test]
fn warm_server_is_disabled_for_warm_session_itself() {
    let app = AppState::new("__warm__".to_string());
    assert!(!should_spawn_warm_server(&app));
}

#[test]
fn warm_server_is_allowed_for_normal_sessions() {
    let app = AppState::new("demo".to_string());
    assert!(should_spawn_warm_server(&app));
}

// ── Options get/set tests ───────────────────────────────────────

#[test]
fn get_option_allow_rename() {
    let app = AppState::new("test".to_string());
    let val = super::options::get_option_value(&app, "allow-rename");
    assert_eq!(val, "on");
}

#[test]
fn get_option_bell_action() {
    let app = AppState::new("test".to_string());
    let val = super::options::get_option_value(&app, "bell-action");
    assert_eq!(val, "any");
}

#[test]
fn get_option_activity_action() {
    let app = AppState::new("test".to_string());
    let val = super::options::get_option_value(&app, "activity-action");
    assert_eq!(val, "other");
}

#[test]
fn get_option_silence_action() {
    let app = AppState::new("test".to_string());
    let val = super::options::get_option_value(&app, "silence-action");
    assert_eq!(val, "other");
}

#[test]
fn get_option_update_environment() {
    let app = AppState::new("test".to_string());
    let val = super::options::get_option_value(&app, "update-environment");
    assert!(val.contains("DISPLAY"));
    assert!(val.contains("SSH_AUTH_SOCK"));
}

#[test]
fn set_option_allow_rename_off() {
    let mut app = AppState::new("test".to_string());
    super::options::apply_set_option(&mut app, "allow-rename", "off", false);
    assert!(!app.allow_rename);
}

#[test]
fn set_option_activity_action() {
    let mut app = AppState::new("test".to_string());
    super::options::apply_set_option(&mut app, "activity-action", "any", false);
    assert_eq!(app.activity_action, "any");
}

#[test]
fn set_option_silence_action() {
    let mut app = AppState::new("test".to_string());
    super::options::apply_set_option(&mut app, "silence-action", "none", false);
    assert_eq!(app.silence_action, "none");
}
