//! Suppress transient terminal-mode flaps in the remote → local stream.
//!
//! tmux 3.4 and 3.5a reset the client terminal whenever a *non-active* pane
//! writes a multi-byte cell (the synchronized-update marker in
//! `screen_write_initctx` leaks into `tty_cmd_cell`, which then calls
//! `tty_invalidate`): mouse tracking goes off and the cursor is shown, and a
//! moment later `server_client_reset_state` restores both. A lazygit frame in
//! a side pane does this several times per second. Inside a local tmux the
//! momentary "mouse off" lets a wheel event fall into the *local* copy-mode,
//! and the "cursor shown" flashes the input cursor.
//!
//! The filter holds the first half of such a pair for [`HOLD`] and drops it
//! when the second half follows in time; the second half is always passed on. Mode changes do not interact with
//! drawing output, so delaying or dropping a cancelled pair is safe; a lone
//! change is released unchanged after the hold expires.
use std::time::{Duration, Instant};

/// How long the first half of a pair may be held before it is passed on.
pub const HOLD: Duration = Duration::from_millis(300);

/// (held sequence, sequence that cancels it)
const PAIRS: &[(&[u8], &[u8])] = &[
    (b"\x1b[?1000l", b"\x1b[?1000h"),
    (b"\x1b[?1002l", b"\x1b[?1002h"),
    (b"\x1b[?1003l", b"\x1b[?1003h"),
    (b"\x1b[?1006l", b"\x1b[?1006h"),
    (b"\x1b[?25h", b"\x1b[?25l"),
];

pub struct FlapFilter {
    /// bytes that are so far a prefix of at least one tracked sequence
    pend: Vec<u8>,
    pend_since: Option<Instant>,
    /// held first halves: pair index + when it was seen, oldest first
    held: Vec<(usize, Instant)>,
}

impl Default for FlapFilter {
    fn default() -> Self {
        Self::new()
    }
}

impl FlapFilter {
    pub fn new() -> Self {
        Self {
            pend: Vec::new(),
            pend_since: None,
            held: Vec::new(),
        }
    }

    fn is_prefix_of_tracked(bytes: &[u8]) -> bool {
        PAIRS
            .iter()
            .any(|(a, b)| a.starts_with(bytes) || b.starts_with(bytes))
    }

    /// Feed remote output; returns the bytes to write to the terminal now.
    pub fn feed(&mut self, input: &[u8], now: Instant) -> Vec<u8> {
        let mut out = Vec::with_capacity(input.len());
        for &b in input {
            if self.pend.is_empty() {
                if b == 0x1b {
                    self.pend.push(b);
                    self.pend_since = Some(now);
                } else {
                    out.push(b);
                }
                continue;
            }
            self.pend.push(b);
            if Self::is_prefix_of_tracked(&self.pend) {
                if let Some(i) = PAIRS.iter().position(|(a, _)| *a == self.pend.as_slice()) {
                    if !self.held.iter().any(|(h, _)| *h == i) {
                        self.held.push((i, now));
                    }
                    self.pend.clear();
                } else if let Some(i) = PAIRS.iter().position(|(_, c)| *c == self.pend.as_slice()) {
                    // The second half always goes through: re-enabling a mode that is
                    // already on, or hiding an already hidden cursor, is a no-op, while
                    // dropping it would lose the enable whenever the previous state was
                    // off (tmux starts a client with "mouse off" and only then "mouse on").
                    if let Some(pos) = self.held.iter().position(|(h, _)| *h == i) {
                        self.held.remove(pos); // the held first half is what we drop
                    }
                    out.extend_from_slice(&self.pend);
                    self.pend.clear();
                }
                // else: still a prefix, keep collecting
                continue;
            }
            // not a tracked sequence: release what we held back, then re-examine this byte
            self.pend.pop();
            out.append(&mut self.pend);
            if b == 0x1b {
                self.pend.push(b);
                self.pend_since = Some(now);
            } else {
                out.push(b);
            }
        }
        if self.pend.is_empty() {
            self.pend_since = None;
        }
        out
    }

    /// Anything waiting on a timer?
    pub fn has_pending(&self) -> bool {
        !self.held.is_empty() || !self.pend.is_empty()
    }

    /// Time until the oldest pending item expires.
    pub fn wait(&self, now: Instant) -> Duration {
        let oldest = self
            .held
            .iter()
            .map(|(_, t)| *t)
            .chain(self.pend_since)
            .min();
        match oldest {
            Some(t) => HOLD.saturating_sub(now.duration_since(t)),
            None => HOLD,
        }
    }

    /// Release held halves and stale partial prefixes older than [`HOLD`].
    pub fn expire(&mut self, now: Instant) -> Vec<u8> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < self.held.len() {
            if now.duration_since(self.held[i].1) >= HOLD {
                let (idx, _) = self.held.remove(i);
                out.extend_from_slice(PAIRS[idx].0);
            } else {
                i += 1;
            }
        }
        if let Some(t) = self.pend_since {
            if now.duration_since(t) >= HOLD {
                out.append(&mut self.pend);
                self.pend_since = None;
            }
        }
        out
    }

    /// Release everything immediately (session end).
    pub fn flush(&mut self) -> Vec<u8> {
        let mut out = Vec::new();
        for (idx, _) in self.held.drain(..) {
            out.extend_from_slice(PAIRS[idx].0);
        }
        out.append(&mut self.pend);
        self.pend_since = None;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OFF: &[u8] = b"\x1b[?1006l\x1b[?1000l\x1b[?1002l\x1b[?1003l";
    const ON: &[u8] = b"\x1b[?1006h\x1b[?1000h\x1b[?1002h\x1b[?1003h";

    fn feed_all(f: &mut FlapFilter, chunks: &[&[u8]], now: Instant) -> Vec<u8> {
        let mut out = Vec::new();
        for c in chunks {
            out.extend(f.feed(c, now));
        }
        out
    }

    #[test]
    fn plain_and_untracked_sequences_pass_through() {
        let mut f = FlapFilter::new();
        let seq = b"hello \x1b[31mred\x1b[0m \x1b[?2004h\x1b[?1049h\x1b[?1005l tail";
        let out = feed_all(&mut f, &[seq], Instant::now());
        assert_eq!(out, seq);
        assert!(!f.has_pending());
    }

    #[test]
    fn cancelled_mouse_flap_is_dropped_and_drawing_kept_in_order() {
        let mut f = FlapFilter::new();
        let now = Instant::now();
        let mut input = Vec::new();
        input.extend_from_slice(b"A\x1b[?25h");
        input.extend_from_slice(OFF);
        input.extend_from_slice(b"\x1b[1;1H\x1b[1;64rredraw\x1b[?25l");
        input.extend_from_slice(ON);
        input.extend_from_slice(b"Z");
        let out = feed_all(&mut f, &[&input], now);
        let mut want = b"A\x1b[1;1H\x1b[1;64rredraw\x1b[?25l".to_vec();
        want.extend_from_slice(ON);
        want.extend_from_slice(b"Z");
        assert_eq!(out, want);
        assert!(!f.has_pending());
    }

    #[test]
    fn flap_split_across_chunks_within_hold_is_dropped() {
        let mut f = FlapFilter::new();
        let now = Instant::now();
        let out = feed_all(
            &mut f,
            &[
                b"x\x1b[?10",
                b"00l\x1b[?1002l",
                b"draw",
                b"\x1b[?1000h\x1b[?1002hy",
            ],
            now,
        );
        assert_eq!(out, b"xdraw\x1b[?1000h\x1b[?1002hy");
        assert!(!f.has_pending());
    }

    #[test]
    fn lone_off_is_released_after_hold() {
        let mut f = FlapFilter::new();
        let t0 = Instant::now();
        let out = f.feed(b"a\x1b[?1000lb", t0);
        assert_eq!(out, b"ab");
        assert!(f.has_pending());
        assert!(f.expire(t0 + Duration::from_millis(10)).is_empty());
        assert_eq!(f.expire(t0 + HOLD), b"\x1b[?1000l");
        assert!(!f.has_pending());
    }

    #[test]
    fn on_without_held_off_passes_through() {
        let mut f = FlapFilter::new();
        let out = f.feed(b"\x1b[?1000h\x1b[?25l", Instant::now());
        assert_eq!(out, b"\x1b[?1000h\x1b[?25l");
    }

    #[test]
    fn cursor_show_hide_flap_is_dropped_but_plain_show_is_released() {
        let mut f = FlapFilter::new();
        let t0 = Instant::now();
        assert_eq!(f.feed(b"\x1b[?25h..\x1b[?25l", t0), b"..\x1b[?25l");
        assert!(!f.has_pending());
        assert_eq!(f.feed(b"\x1b[?25h", t0), b"");
        assert_eq!(f.expire(t0 + HOLD), b"\x1b[?25h");
    }

    #[test]
    fn stale_partial_escape_is_released() {
        let mut f = FlapFilter::new();
        let t0 = Instant::now();
        assert_eq!(f.feed(b"q\x1b[?1", t0), b"q");
        assert!(f.has_pending());
        assert_eq!(f.expire(t0 + HOLD), b"\x1b[?1");
        assert!(!f.has_pending());
    }

    #[test]
    fn prefix_that_diverges_is_released_intact() {
        let mut f = FlapFilter::new();
        // \e[?1005l shares the prefix \e[?100 with the tracked \e[?1000l
        let out = f.feed(b"\x1b[?1005l\x1b[?12l\x1b[?25h!\x1b[?25l", Instant::now());
        assert_eq!(out, b"\x1b[?1005l\x1b[?12l!\x1b[?25l");
    }

    #[test]
    fn real_tmux34_invalidate_cycle_is_cleaned() {
        let cycle: &[u8] = include_bytes!("../tests/fixtures/tmux34-invalidate-cycle.bin");
        let mut f = FlapFilter::new();
        let now = Instant::now();
        let out = f.feed(cycle, now);
        assert!(!f.has_pending(), "everything in the cycle should pair up");
        for needle in [OFF, b"\x1b[?25h".as_slice()] {
            assert!(
                !out.windows(needle.len()).any(|w| w == needle),
                "leaked {needle:?}"
            );
        }
        for needle in [ON, b"\x1b[?25l".as_slice()] {
            assert!(
                out.windows(needle.len()).any(|w| w == needle),
                "second half must pass: {needle:?}"
            );
        }
        // everything else is preserved in order
        let mut expected = cycle.to_vec();
        for needle in [OFF, b"\x1b[?25h".as_slice()] {
            let s = expected.clone();
            expected.clear();
            let mut i = 0;
            while i < s.len() {
                if s[i..].starts_with(needle) {
                    i += needle.len();
                } else {
                    expected.push(s[i]);
                    i += 1;
                }
            }
        }
        assert_eq!(out, expected);
    }

    #[test]
    fn startup_off_then_on_leaves_mouse_enabled() {
        // tmux tty_start_tty: modes off first, enabled a little later
        let mut f = FlapFilter::new();
        let now = Instant::now();
        let out = feed_all(
            &mut f,
            &[
                b"\x1b[?1049h\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1005l",
                b"\x1b[H\x1b[J",
                ON,
            ],
            now,
        );
        let mut want = b"\x1b[?1049h\x1b[?1005l\x1b[H\x1b[J".to_vec();
        want.extend_from_slice(ON);
        assert_eq!(out, want);
        assert!(!f.has_pending());
    }
}
