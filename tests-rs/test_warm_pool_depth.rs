// Unit tests for the spare shell pool: depth accounting, refill scheduling
// arithmetic, and the `warm-pool-size` option.
//
// The bug these pin: the pool used to be a bare `Option<WarmPane>`, a depth of
// one. Claim the single spare, refill, and the refill is a shell that started
// milliseconds ago -- so the NEXT creation claims a newborn and pays its whole
// startup. Sequential creations therefore alternated fast, slow, fast, slow.
//
// What is testable without a real shell is the accounting that drives it:
// `deficit()` (how many spawns the loop should hand to the background spawner
// this tick, counting the ones already in flight), FIFO claim order, and the
// option that sets the target. The end to end timings live in
// tests/test_pane_startup_perf.ps1, which asserts p90, max and bimodality.

use super::*;
use crate::types::{AppState, WarmPool, WARM_POOL_SIZE_DEFAULT, WARM_POOL_SIZE_MAX, WARM_POOL_SURGE_MAX};

// ── deficit(): the refill scheduler's only input ───────────────────

#[test]
fn empty_pool_asks_for_its_whole_target() {
    let pool = WarmPool::new(2);
    assert_eq!(pool.deficit(), 2, "an empty pool of target 2 needs 2 spawns");
}

#[test]
fn inflight_spawns_count_towards_the_target() {
    // Without this the server loop would queue one spawn per tick while the
    // first was still running: a 1ms loop would fire hundreds of shells.
    let mut pool = WarmPool::new(2);
    pool.inflight = 1;
    assert_eq!(pool.deficit(), 1);
    pool.inflight = 2;
    assert_eq!(pool.deficit(), 0);
    pool.inflight = 5;
    assert_eq!(pool.deficit(), 0, "over-supply must not underflow");
}

#[test]
fn target_zero_never_asks_for_a_spawn() {
    // `warm-pool-size 0` and `set -g warm off` both land here. A pool that
    // still refills after being switched off is an opt-out that does not opt
    // out.
    let mut pool = WarmPool::new(0);
    assert_eq!(pool.deficit(), 0);
    pool.inflight = 0;
    assert_eq!(pool.deficit(), 0);
}

// ── claim order ────────────────────────────────────────────────────

#[test]
fn claims_are_served_oldest_first() {
    // A spare is worth exactly as much as the amount of shell startup it has
    // already done, so the oldest spare is always the right one to hand out.
    // Ordering is what makes depth pay off; LIFO would hand the caller the
    // newest shell and reproduce the original bug at any depth.
    let mut pool = WarmPool::new(3);
    for id in [10usize, 11, 12] {
        pool.push(fake_spare(id));
    }
    assert_eq!(pool.take().map(|w| w.pane_id), Some(10));
    assert_eq!(pool.take().map(|w| w.pane_id), Some(11));
    assert_eq!(pool.take().map(|w| w.pane_id), Some(12));
    assert!(pool.take().is_none());
}

#[test]
fn claiming_creates_exactly_one_unit_of_deficit() {
    let mut pool = WarmPool::new(2);
    pool.push(fake_spare(1));
    pool.push(fake_spare(2));
    assert_eq!(pool.deficit(), 0, "a full pool schedules nothing");
    let _ = pool.take();
    assert_eq!(pool.deficit(), 1, "a claim must schedule its refill immediately");
    let _ = pool.take();
    assert_eq!(pool.deficit(), 2);
}

#[test]
fn kill_all_empties_the_pool_not_just_its_head() {
    // Every "the pool is stale now" site (resize, set-option, kill-server)
    // goes through this. Killing only the head would leave orphan shells.
    let mut pool = WarmPool::new(3);
    pool.push(fake_spare(1));
    pool.push(fake_spare(2));
    pool.push(fake_spare(3));
    pool.kill_all();
    assert!(pool.is_empty());
    assert_eq!(pool.len(), 0);
    assert_eq!(pool.deficit(), 3, "and the deficit is what refills it");
}

// ── the warm-pool-size option ──────────────────────────────────────

#[test]
fn option_sets_the_target_and_clamps_to_the_maximum() {
    let mut app = AppState::new("pooltest".to_string());
    crate::server::options::set_warm_pool_size(&mut app, "4");
    assert_eq!(app.warm_pane.target, 4);
    crate::server::options::set_warm_pool_size(&mut app, "999");
    assert_eq!(
        app.warm_pane.target, WARM_POOL_SIZE_MAX,
        "each spare is a real process, so the depth has to have a ceiling"
    );
}

#[test]
fn option_zero_disables_the_pool() {
    let mut app = AppState::new("pooltest".to_string());
    app.warm_pane.push(fake_spare(1));
    crate::server::options::set_warm_pool_size(&mut app, "0");
    assert_eq!(app.warm_pane.target, 0);
    assert!(app.warm_pane.is_empty(), "existing spares are released too");
    assert_eq!(app.warm_pane.deficit(), 0);
}

#[test]
fn shrinking_the_target_releases_the_surplus_now() {
    let mut app = AppState::new("pooltest".to_string());
    for id in 1..=4 {
        app.warm_pane.push(fake_spare(id));
    }
    crate::server::options::set_warm_pool_size(&mut app, "2");
    assert_eq!(app.warm_pane.len(), 2, "memory asked for back is given back");
    assert_eq!(app.warm_pane.deficit(), 0);
}

#[test]
fn non_numeric_value_leaves_the_pool_alone() {
    let mut app = AppState::new("pooltest".to_string());
    let before = app.warm_pane.target;
    crate::server::options::set_warm_pool_size(&mut app, "banana");
    assert_eq!(app.warm_pane.target, before);
}

#[test]
fn default_depth_is_greater_than_one() {
    // The whole point. Depth one is what produced the alternating
    // fast/slow window creation; a default of one would reintroduce it.
    assert!(
        WARM_POOL_SIZE_DEFAULT >= 2,
        "a pool of depth one cannot serve two creations in a row"
    );
    assert!(WARM_POOL_SIZE_DEFAULT <= WARM_POOL_SIZE_MAX);
}

// ── readiness: the thing depth alone did not fix ───────────────────
//
// Depth-N with async refill removed the fast/slow ALTERNATION and left a
// slow creation every third one. The trace said why: a spare becomes a pool
// member ~25ms after it is asked for (CreateProcess plus a ConPTY) but its pwsh
// needs ~400ms more to put a prompt up. Claims were being served spares 30 and
// 40ms old, which cost the caller the whole remaining startup -- measured at
// 376ms and 395ms against 15ms for a settled spare. Counting spares by
// existence rather than by readiness was the real defect.

#[test]
fn an_unready_spare_is_not_counted_as_ready() {
    let mut pool = WarmPool::new(2);
    pool.push(fake_spare(1));           // lands, but its shell is still starting
    assert_eq!(pool.len(), 1, "it is in the pool");
    assert_eq!(pool.ready_len(), 0, "but it is not ready");
    assert!(pool.take_ready().is_none(), "so a readiness-only claim finds nothing");
}

#[test]
fn a_claim_still_takes_a_warming_spare_over_nothing() {
    // Readiness picks WHICH spare, never whether one is handed out. A spare
    // part way through its startup beats a cold spawn, which is 0ms through
    // one: refusing it made a cold `new-session` 330ms slower, because the one
    // spare such a server has is newborn by definition.
    let mut pool = WarmPool::new(2);
    pool.push(fake_spare(1));
    let (got, was_ready) = pool.claim();
    assert_eq!(got.map(|w| w.pane_id), Some(1), "the warming spare is used");
    assert!(!was_ready, "and the miss is reported, which is what opens a surge");
}

#[test]
fn a_claim_prefers_a_ready_spare_over_an_older_warming_one() {
    let mut pool = WarmPool::new(3);
    pool.push(fake_spare(1));           // older, still starting
    pool.push(ready_spare(2));
    let (got, was_ready) = pool.claim();
    assert_eq!(got.map(|w| w.pane_id), Some(2));
    assert!(was_ready);
}

#[test]
fn a_claim_on_an_empty_pool_reports_a_miss() {
    let mut pool = WarmPool::new(2);
    let (got, was_ready) = pool.claim();
    assert!(got.is_none(), "nothing to hand out, the caller cold spawns");
    assert!(!was_ready);
}

#[test]
fn a_ready_spare_is_handed_out() {
    let mut pool = WarmPool::new(2);
    pool.push(ready_spare(7));
    assert_eq!(pool.take_ready().map(|w| w.pane_id), Some(7));
}

#[test]
fn ready_spares_are_served_oldest_first_past_unready_ones() {
    // Claim order has to skip the warming spares rather than stop at them,
    // otherwise one newborn at the head of the queue blocks a settled spare
    // sitting right behind it.
    let mut pool = WarmPool::new(4);
    pool.push(fake_spare(1));           // warming
    pool.push(ready_spare(2));
    pool.push(ready_spare(3));
    assert_eq!(pool.take_ready().map(|w| w.pane_id), Some(2));
    assert_eq!(pool.take_ready().map(|w| w.pane_id), Some(3));
    assert!(pool.take_ready().is_none());
    assert_eq!(pool.len(), 1, "the warming spare is still there");
}

#[test]
fn readiness_needs_output_then_quiet() {
    let mut wp = fake_spare(1);
    let t0 = std::time::Instant::now();
    // No output at all: nothing to be quiet after, so not ready however long
    // we wait (short of the backstop).
    assert!(!wp.refresh_ready(t0 + std::time::Duration::from_millis(600)));
    // First byte arrives.
    wp.data_version.store(1, std::sync::atomic::Ordering::Relaxed);
    assert!(!wp.refresh_ready(t0 + std::time::Duration::from_millis(601)));
    // Still writing just under the quiet window.
    assert!(!wp.refresh_ready(t0 + std::time::Duration::from_millis(700)));
    // Quiet for long enough: the shell has settled.
    assert!(wp.refresh_ready(t0 + std::time::Duration::from_millis(601) + crate::types::WARM_READY_QUIET));
}

#[test]
fn readiness_has_a_backstop_for_a_silent_shell() {
    // A `default-shell` that prints nothing would otherwise never be handed
    // out and every creation would cold spawn for ever. Past the backstop the
    // pool behaves as it did before readiness existed.
    let mut wp = fake_spare(1);
    let late = wp.spawned_at + crate::types::WARM_READY_MAX_WAIT;
    assert!(wp.refresh_ready(late), "a silent shell must eventually count");
}

#[test]
fn readiness_is_sticky() {
    let mut wp = fake_spare(1);
    wp.data_version.store(1, std::sync::atomic::Ordering::Relaxed);
    let t = wp.spawned_at + std::time::Duration::from_millis(10);
    wp.refresh_ready(t);
    wp.refresh_ready(t + crate::types::WARM_READY_QUIET);
    assert!(wp.ready);
    // More output afterwards (the user's shell is running something) must not
    // un-ready a spare; it is already startable.
    wp.data_version.store(99, std::sync::atomic::Ordering::Relaxed);
    assert!(wp.refresh_ready(t + crate::types::WARM_READY_QUIET + std::time::Duration::from_millis(1)));
}

// ── surge: a run of creations outruns any fixed depth ──────────────

#[test]
fn a_satisfied_claim_does_not_surge() {
    // Opening one window must not cost eight shell spawns.
    let mut pool = WarmPool::new(2);
    pool.note_claim(true);
    assert!(!pool.is_surging());
    assert_eq!(pool.effective_target(false), 2);
}

#[test]
fn one_lone_miss_does_not_surge() {
    // A cold `new-session` misses by definition: the only spare it has was
    // born moments earlier. Surging there fired eight shell spawns beside the
    // session's own starting shell and cost ~100ms of startup, measured.
    let mut pool = WarmPool::new(2);
    pool.note_claim(false);
    assert!(!pool.is_surging(), "an isolated creation is not a run of creations");
    assert_eq!(pool.effective_target(false), 2);
}

#[test]
fn a_miss_following_another_claim_surges_to_the_cap() {
    // Two claims close together, the second finding nothing ready: that is a
    // run outpacing the pool. Widening the batch is what lets a run pay ONE
    // shell startup between them all instead of one each, because the spawns
    // go out concurrently.
    let mut pool = WarmPool::new(2);
    pool.note_claim(true);      // first creation, served
    pool.note_claim(false);     // second, nothing ready
    assert!(pool.is_surging());
    assert_eq!(pool.effective_target(false), WARM_POOL_SURGE_MAX);
    assert_eq!(pool.deficit_for(pool.effective_target(false)), WARM_POOL_SURGE_MAX);
}

#[test]
fn a_surge_respects_a_deliberately_small_target() {
    // Someone who set `warm-pool-size 1` to save memory must not be handed
    // eight shells by a burst.
    let mut pool = WarmPool::new(1);
    pool.note_claim(true);
    pool.note_claim(false);
    assert_eq!(pool.effective_target(false), crate::types::WARM_POOL_SURGE_FACTOR);
}

#[test]
fn a_disabled_pool_never_surges() {
    let mut pool = WarmPool::new(0);
    pool.note_claim(true);
    pool.note_claim(false);
    assert_eq!(pool.effective_target(false), 0);
    assert_eq!(pool.deficit_for(pool.effective_target(false)), 0);
}

#[test]
fn a_standby_is_held_at_one_spare_and_never_surges() {
    // A `__warm__` helper creates no windows of its own, so spares beyond the
    // one its claimant wants first are idle memory in a process that may sit
    // around for days.
    let mut pool = WarmPool::new(5);
    assert_eq!(pool.effective_target(true), 1);
    pool.note_claim(true);
    pool.note_claim(false);
    assert_eq!(pool.effective_target(true), 1, "not even a burst deepens a standby");
}

#[test]
fn surplus_from_a_finished_surge_is_given_back() {
    // Without this a single burst would leave the pool permanently deep: eight
    // idle shells for a user who configured two.
    let mut pool = WarmPool::new(2);
    for id in 1..=6 {
        pool.push(ready_spare(id));
    }
    pool.note_claim(true);
    pool.note_claim(false);
    assert_eq!(pool.trim_surplus(), 0, "nothing is released while the surge is live");
    assert_eq!(pool.len(), 6);
    pool.end_surge_for_test();
    assert_eq!(pool.trim_surplus(), 4);
    assert_eq!(pool.len(), 2, "back to the configured depth");
}

#[test]
fn trimming_keeps_the_oldest_spares() {
    // The oldest spares are the ones whose startup is furthest along, so they
    // are the ones worth keeping; dropping them would throw away the readiness
    // the pool just spent 400ms acquiring.
    let mut pool = WarmPool::new(2);
    for id in 1..=5 {
        pool.push(ready_spare(id));
    }
    pool.end_surge_for_test();
    pool.trim_surplus();
    assert_eq!(pool.take_ready().map(|w| w.pane_id), Some(1));
    assert_eq!(pool.take_ready().map(|w| w.pane_id), Some(2));
}

// ── helper: a spare with no shell behind it ────────────────────────
//
// The pool only ever inspects `pane_id`, `rows`/`cols`, `spawned_at`, `ready`
// and the child's liveness, so a dummy process stands in fine.
//
// The dummy must STAY ALIVE: claims reap dead spares (#450), so a `cmd /c exit`
// here would be reaped out from under the ordering assertions depending on how
// fast Windows got round to it. `pause` blocks on stdin for ever and exits on
// its own when the PTY master drops at the end of the test.
//
// `reap_dead` is deliberately not tested here: it depends on when the OS reaps
// the dummy, which is a race, and it is covered end to end by
// tests/test_issue450_dead_warm_pane.ps1.
fn fake_spare(pane_id: usize) -> crate::types::WarmPane {
    let pty = portable_pty::native_pty_system();
    let pair = pty
        .openpty(portable_pty::PtySize { rows: 40, cols: 120, pixel_width: 0, pixel_height: 0 })
        .expect("openpty");
    let mut cmd = portable_pty::CommandBuilder::new("cmd.exe");
    cmd.arg("/c");
    cmd.arg("pause");
    let child = pair.slave.spawn_command(cmd).expect("spawn dummy");
    let writer = pair.master.take_writer().expect("writer");
    let now = std::time::Instant::now();
    crate::types::WarmPane {
        master: pair.master,
        writer,
        child,
        term: std::sync::Arc::new(std::sync::Mutex::new(vt100::Parser::new(40, 120, 100))),
        data_version: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
        cursor_shape: std::sync::Arc::new(std::sync::atomic::AtomicU8::new(0)),
        bell_pending: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
        cpr_pending: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
        color_query_pending: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
        child_pid: None,
        pane_id,
        rows: 40,
        cols: 120,
        output_ring: std::sync::Arc::new(std::sync::Mutex::new(std::collections::VecDeque::new())),
        spawned_at: now,
        ready: false,
        last_dv: 0,
        last_change: now,
        trace_settled: false,
        host_colors: None,
    }
}

/// A spare already past its shell startup, which is the only kind a caller is
/// ever handed.
fn ready_spare(pane_id: usize) -> crate::types::WarmPane {
    let mut wp = fake_spare(pane_id);
    wp.ready = true;
    wp
}
