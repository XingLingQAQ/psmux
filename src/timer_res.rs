//! Windows timer resolution for the interactive path.
//!
//! Since Windows 10 2004 the timer resolution is per process: a process that
//! has never called `timeBeginPeriod` gets the default 15.6ms tick for its own
//! waits no matter what resolution any other process on the box has requested.
//! Every sub-tick wait in such a process rounds UP to that tick, so a
//! `thread::sleep(1ms)` sleeps for 15.6ms and a `recv_timeout(1ms)` waits
//! 15.6ms.
//!
//! That is not a rounding curiosity on the keystroke path, it is the whole
//! budget. The pane parser thread waits one tick to coalesce a burst of pty
//! bytes, and the server event loop waits one tick before it notices the flag
//! that says new pty data is ready. Two 15.6ms ticks in series is 31ms of
//! keystroke to screen latency added to every character typed, measured on a
//! machine whose GLOBAL resolution was already 1ms.
//!
//! Measured with tests/test_keystroke_latency_bench.ps1, single keystroke at an
//! idle pwsh prompt: 32.4ms median before, 1.5ms median after, against a bare
//! conhost baseline of 1.07ms.
//!
//! Requesting 1ms costs power, so it is held only while it buys something: for
//! the whole life of a client process (a client only exists while a terminal is
//! attached), and in the server only while a client is actually attached. A
//! detached server sitting in the background keeps the default tick.
//!
//! `PSMUX_NO_TIMER_RES=1` opts out entirely, which is also how the benchmark
//! A/Bs the change against the same build.

#[cfg(windows)]
mod imp {
    use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};

    #[link(name = "winmm")]
    extern "system" {
        fn timeBeginPeriod(uPeriod: u32) -> u32;
        fn timeEndPeriod(uPeriod: u32) -> u32;
    }

    const PERIOD_MS: u32 = 1;

    /// Whether this process currently holds the 1ms period.
    static HELD: AtomicBool = AtomicBool::new(false);
    /// 0 = not looked up yet, 1 = allowed, 2 = disabled by env.
    static OPT_OUT: AtomicU8 = AtomicU8::new(0);

    fn opted_out() -> bool {
        match OPT_OUT.load(Ordering::Relaxed) {
            1 => false,
            2 => true,
            _ => {
                let off = std::env::var_os("PSMUX_NO_TIMER_RES").is_some_and(|v| v != "0");
                OPT_OUT.store(if off { 2 } else { 1 }, Ordering::Relaxed);
                off
            }
        }
    }

    /// Acquire or release the 1ms timer period. Idempotent and cheap enough to
    /// call from the server event loop every iteration: the common case is one
    /// relaxed atomic load.
    pub fn set_high(on: bool) {
        if on == HELD.load(Ordering::Relaxed) {
            return;
        }
        if on {
            if opted_out() {
                return;
            }
            // SAFETY: timeBeginPeriod takes a period in milliseconds and only
            // affects this process's scheduling granularity.
            unsafe { timeBeginPeriod(PERIOD_MS) };
            HELD.store(true, Ordering::Relaxed);
        } else {
            // SAFETY: paired with the timeBeginPeriod above; only reached when
            // HELD says this process actually took the period.
            unsafe { timeEndPeriod(PERIOD_MS) };
            HELD.store(false, Ordering::Relaxed);
        }
    }

    /// Whether the 1ms period is held right now. Test hook.
    pub fn is_high() -> bool {
        HELD.load(Ordering::Relaxed)
    }
}

#[cfg(not(windows))]
mod imp {
    // POSIX timed waits are not quantised to a 15.6ms tick, so there is nothing
    // to raise.
    pub fn set_high(_on: bool) {}
    pub fn is_high() -> bool {
        false
    }
}

pub use imp::set_high;
#[cfg(test)]
pub use imp::is_high;

#[cfg(test)]
#[path = "../tests-rs/test_timer_resolution.rs"]
mod test_timer_resolution;
