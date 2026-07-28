//! Raw-mode guard: the local terminal becomes a dumb pipe; restore on any exit path.

use anyhow::Result;
use std::io::Write;

/// DEC private modes a remote full-screen app (tmux/vim) may have switched on in
/// *our* terminal: mouse tracking (normal/button/any-motion, UTF-8/SGR/urxvt
/// encodings), focus reporting, bracketed paste, and the alternate screen. If we
/// exit without turning them back off, the local shell is left echoing raw mouse
/// and focus escape sequences on every pointer move. Mirror what a normal
/// SSH/tmux detach emits. Show the cursor too, in case a TUI hid it.
const RESTORE: &[u8] = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?2004l\x1b[?25h\x1b[?1049l";

pub struct RawGuard;

impl RawGuard {
    pub fn enable() -> Result<Self> {
        crossterm::terminal::enable_raw_mode()?;
        Ok(RawGuard)
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        // undo any remote-enabled input modes before handing the terminal back
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(RESTORE);
        let _ = out.flush();
        crossterm::terminal::disable_raw_mode().ok();
    }
}

pub fn size() -> (u16, u16) {
    crossterm::terminal::size().unwrap_or((80, 24))
}
