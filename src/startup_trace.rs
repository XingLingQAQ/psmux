//! Env gated hop trace of launch to prompt, `PSMUX_STARTUP_TRACE=<file>`.
//!
//! With the variable unset every probe is one relaxed atomic load and returns,
//! so the shipped startup path is unchanged. It exists to answer one question
//! with timestamps rather than inference: of the time between a user typing
//! `psmux new-session <cmd>` and the pane's shell reaching its first prompt,
//! which hop owns which milliseconds.
//!
//! Timestamps are raw `QueryPerformanceCounter` ticks, which are system wide on
//! Windows, so a line written by the client process, a line written by the
//! server process and a `Stopwatch` timestamp taken by a test harness can all
//! be compared directly. The header line records the frequency.
//!
//! Every process that has the variable set writes its own `<path>.<pid>`, so
//! the client's and the server's lines never interleave; merge and sort by the
//! first column to read the whole path.
//!
//! Labels, in path order (`cli.` is the foreground CLI, `srv.` the server):
//!   `cli.entry`        first line of `main`
//!   `cli.dispatch`     argv parsed, about to act on the subcommand
//!   `cli.warm.claimed` a warm standby server was claimed (fast path)
//!   `cli.server.spawn` `spawn_server_hidden` returned (cold path)
//!   `cli.ready`        the readiness gate accepted the server
//!   `cli.attach`       the attach/TUI path is entered
//!   `srv.entry`        first line of `run_server`
//!   `srv.bound`        control listener bound, `.port`/`.key` written
//!   `srv.config`       `load_config` returned
//!   `srv.pane.spawn`   the initial pane's ConPTY child was created
//!   `srv.loop`         the main request loop is about to run

use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Mutex, OnceLock};

/// 0 = not looked up yet, 1 = on, 2 = off.
static GATE: AtomicU8 = AtomicU8::new(0);
static SINK: OnceLock<Option<Mutex<BufWriter<File>>>> = OnceLock::new();

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn QueryPerformanceCounter(out: *mut i64) -> i32;
    fn QueryPerformanceFrequency(out: *mut i64) -> i32;
}

#[cfg(windows)]
fn qpc() -> i64 {
    let mut v: i64 = 0;
    // SAFETY: writes one i64 through a valid pointer to a local.
    unsafe { QueryPerformanceCounter(&mut v) };
    v
}

#[cfg(windows)]
fn qpf() -> i64 {
    let mut v: i64 = 1;
    // SAFETY: writes one i64 through a valid pointer to a local.
    unsafe { QueryPerformanceFrequency(&mut v) };
    v
}

#[cfg(not(windows))]
fn qpc() -> i64 {
    0
}
#[cfg(not(windows))]
fn qpf() -> i64 {
    1
}

/// Whether tracing is on. One relaxed load in the steady state.
#[inline]
pub fn on() -> bool {
    match GATE.load(Ordering::Relaxed) {
        1 => true,
        2 => false,
        _ => {
            let want = std::env::var_os("PSMUX_STARTUP_TRACE").is_some();
            GATE.store(if want { 1 } else { 2 }, Ordering::Relaxed);
            want
        }
    }
}

fn sink() -> Option<&'static Mutex<BufWriter<File>>> {
    SINK.get_or_init(|| {
        let path = format!(
            "{}.{}",
            std::env::var("PSMUX_STARTUP_TRACE").ok()?,
            std::process::id()
        );
        let f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok()?;
        let mut w = BufWriter::new(f);
        let _ = writeln!(w, "# qpf {} pid {}", qpf(), std::process::id());
        let _ = w.flush();
        Some(Mutex::new(w))
    })
    .as_ref()
}

/// Record one startup hop.
pub fn mark(label: &str) {
    if !on() {
        return;
    }
    let t = qpc();
    if let Some(m) = sink() {
        if let Ok(mut w) = m.lock() {
            let _ = writeln!(w, "{} {}", t, label);
            let _ = w.flush();
        }
    }
}

/// Record one startup hop with a short detail field (a command line, a count).
pub fn mark_detail(label: &str, detail: &str) {
    if !on() {
        return;
    }
    let t = qpc();
    if let Some(m) = sink() {
        if let Ok(mut w) = m.lock() {
            let shown: String = detail.chars().take(200).collect();
            let _ = writeln!(w, "{} {} {}", t, label, shown);
            let _ = w.flush();
        }
    }
}
