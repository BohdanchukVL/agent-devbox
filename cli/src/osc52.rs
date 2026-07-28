//! Streaming OSC 52 interceptor.
//!
//! Remote apps (tmux/Neovim) yank text by emitting `ESC ] 52 ; <target> ; <base64> BEL|ST`.
//! We scan the remote output stream *before* it reaches the local terminal, extract the
//! payloads (→ local OS clipboard) and pass everything else through untouched — so copy
//! works regardless of whether the local terminal supports OSC 52 itself.
//!
//! Sequences can be split across arbitrary read boundaries, so the parser is stateful.

const MAX_PAYLOAD: usize = 1 << 20; // 1 MiB cap, matches generous tmux limits

#[derive(Default)]
enum State {
    #[default]
    Ground,
    /// saw ESC, deciding whether it opens an OSC
    Esc,
    /// inside `ESC ]`, collecting the numeric prefix / params until we know if it's 52
    OscPrefix(Vec<u8>),
    /// inside a confirmed OSC 52, collecting payload until BEL / ST
    Osc52 { buf: Vec<u8>, esc_pending: bool },
    /// inside some other OSC we just pass through, tracking termination
    OscOther { esc_pending: bool },
}

pub struct Osc52Scanner {
    state: State,
    /// bytes held back while we decide whether they belong to an OSC 52 we'll swallow
    held: Vec<u8>,
    /// did the remote app enable bracketed paste (CSI ?2004h)? Decides whether Smart Paste
    /// wraps text in paste markers or sends it plain.
    pub bracketed_paste: bool,
    /// rolling window for the ?2004h/l detector
    tail: [u8; 8],
}

pub struct ScanResult {
    /// bytes to forward to the local terminal
    pub output: Vec<u8>,
    /// decoded clipboard payloads (raw bytes after base64-decode)
    pub clipboard: Vec<Vec<u8>>,
}

impl Osc52Scanner {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            held: Vec::new(),
            bracketed_paste: false,
            tail: [0; 8],
        }
    }

    fn track_paste_mode(&mut self, b: u8) {
        self.tail.rotate_left(1);
        self.tail[7] = b;
        if &self.tail[..7] == b"\x1b[?2004" {
            match b {
                b'h' => self.bracketed_paste = true,
                b'l' => self.bracketed_paste = false,
                _ => {}
            }
        }
    }

    pub fn feed(&mut self, input: &[u8]) -> ScanResult {
        let mut out = Vec::with_capacity(input.len());
        let mut clips = Vec::new();

        for &b in input {
            self.track_paste_mode(b);
            match std::mem::take(&mut self.state) {
                State::Ground => {
                    if b == 0x1b {
                        self.state = State::Esc;
                        self.held.push(b);
                    } else {
                        out.push(b);
                    }
                }
                State::Esc => {
                    if b == b']' {
                        self.state = State::OscPrefix(Vec::new());
                        self.held.push(b);
                    } else if b == 0x1b {
                        // stray ESC: release the previous one, the new one may open an OSC
                        out.append(&mut self.held);
                        self.held.push(b);
                        self.state = State::Esc;
                    } else {
                        // not an OSC — release held bytes
                        out.append(&mut self.held);
                        out.push(b);
                        self.state = State::Ground;
                    }
                }
                State::OscPrefix(mut prefix) => {
                    self.held.push(b);
                    if b == b';' {
                        if prefix == b"52" {
                            // confirmed OSC 52: swallow from here on
                            self.state = State::Osc52 {
                                buf: Vec::new(),
                                esc_pending: false,
                            };
                        } else {
                            // some other OSC: forward held bytes and track till terminator
                            out.append(&mut self.held);
                            self.state = State::OscOther { esc_pending: false };
                        }
                    } else if b == 0x07 {
                        // OSC without params terminated — pass through
                        out.append(&mut self.held);
                        self.state = State::Ground;
                    } else if prefix.len() > 16 || !(b.is_ascii_digit()) {
                        // not something we care about — forward and treat as other OSC;
                        // b may itself be ESC (e.g. `ESC ] 104 ESC \`), keep it pending
                        // so the ST terminator is still recognized
                        out.append(&mut self.held);
                        self.state = State::OscOther {
                            esc_pending: b == 0x1b,
                        };
                    } else {
                        prefix.push(b);
                        self.state = State::OscPrefix(prefix);
                    }
                }
                State::Osc52 {
                    mut buf,
                    esc_pending,
                } => {
                    let terminated = b == 0x07 || (esc_pending && b == b'\\');
                    if terminated {
                        if let Some(decoded) = decode_payload(&buf) {
                            clips.push(decoded);
                        }
                        self.held.clear();
                        self.state = State::Ground;
                    } else if b == 0x1b {
                        self.state = State::Osc52 {
                            buf,
                            esc_pending: true,
                        };
                    } else if buf.len() >= MAX_PAYLOAD {
                        // oversized: give up swallowing, forward everything we held
                        out.append(&mut self.held);
                        out.extend_from_slice(&buf);
                        out.push(b);
                        self.state = State::OscOther {
                            esc_pending: b == 0x1b,
                        };
                    } else {
                        buf.push(b);
                        self.state = State::Osc52 {
                            buf,
                            esc_pending: false,
                        };
                    }
                }
                State::OscOther { esc_pending } => {
                    out.push(b);
                    if b == 0x07 || (esc_pending && b == b'\\') {
                        self.state = State::Ground;
                    } else {
                        self.state = State::OscOther {
                            esc_pending: b == 0x1b,
                        };
                    }
                }
            }
        }

        ScanResult {
            output: out,
            clipboard: clips,
        }
    }
}

/// payload is `<targets>;<base64>` where targets are selection chars like `c`, `p`, `cp`.
/// `?` instead of data is a query — ignore.
fn decode_payload(buf: &[u8]) -> Option<Vec<u8>> {
    use base64::Engine;
    let s = std::str::from_utf8(buf).ok()?;
    let (_targets, b64) = s.split_once(';').unwrap_or(("", s));
    if b64 == "?" || b64.is_empty() {
        return None;
    }
    base64::engine::general_purpose::STANDARD
        .decode(b64.trim_end())
        .ok()
        .filter(|d| !d.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full(scanner: &mut Osc52Scanner, chunks: &[&[u8]]) -> (Vec<u8>, Vec<String>) {
        let mut out = Vec::new();
        let mut clips = Vec::new();
        for c in chunks {
            let r = scanner.feed(c);
            out.extend(r.output);
            clips.extend(
                r.clipboard
                    .into_iter()
                    .map(|c| String::from_utf8_lossy(&c).into_owned()),
            );
        }
        (out, clips)
    }

    #[test]
    fn plain_passthrough() {
        let mut s = Osc52Scanner::new();
        let (out, clips) = full(&mut s, &[b"hello \x1b[31mred\x1b[0m world"]);
        assert_eq!(out, b"hello \x1b[31mred\x1b[0m world");
        assert!(clips.is_empty());
    }

    #[test]
    fn captures_osc52_bel() {
        let mut s = Osc52Scanner::new();
        // "hi" base64 = aGk=
        let (out, clips) = full(&mut s, &[b"A\x1b]52;c;aGk=\x07B"]);
        assert_eq!(out, b"AB");
        assert_eq!(clips, vec!["hi"]);
    }

    #[test]
    fn captures_osc52_st_split_across_chunks() {
        let mut s = Osc52Scanner::new();
        let (out, clips) = full(&mut s, &[b"X\x1b]5", b"2;c;a", b"Gk=\x1b", b"\\Y"]);
        assert_eq!(out, b"XY");
        assert_eq!(clips, vec!["hi"]);
    }

    #[test]
    fn other_osc_passes_through() {
        let mut s = Osc52Scanner::new();
        let seq = b"\x1b]0;window title\x07tail";
        let (out, clips) = full(&mut s, &[seq]);
        assert_eq!(out, seq);
        assert!(clips.is_empty());
    }

    #[test]
    fn query_ignored() {
        let mut s = Osc52Scanner::new();
        let (out, clips) = full(&mut s, &[b"\x1b]52;c;?\x07"]);
        assert!(out.is_empty());
        assert!(clips.is_empty());
    }

    #[test]
    fn tracks_bracketed_paste_mode() {
        let mut s = Osc52Scanner::new();
        assert!(!s.bracketed_paste);
        s.feed(b"prompt\x1b[?2004h");
        assert!(s.bracketed_paste);
        s.feed(b"\x1b[?20");
        s.feed(b"04l bye");
        assert!(!s.bracketed_paste);
    }

    #[test]
    fn st_terminated_osc_without_params_then_osc52() {
        // `ESC ] 104 ESC \` (reset colors, no params, ST terminator) must not
        // desync the scanner: the following OSC 52 still gets captured
        let mut s = Osc52Scanner::new();
        let (out, clips) = full(&mut s, &[b"\x1b]104\x1b\\mid\x1b]52;c;aGk=\x07end"]);
        assert_eq!(out, b"\x1b]104\x1b\\midend");
        assert_eq!(clips, vec!["hi"]);
    }

    #[test]
    fn hyperlink_st_terminated_passthrough_then_osc52() {
        // OSC 8 hyperlinks routinely use ST — the most common ST neighbour in the wild
        let mut s = Osc52Scanner::new();
        let (out, clips) = full(&mut s, &[b"\x1b]8;;http://x\x1b\\link\x1b]52;c;aGk=\x07"]);
        assert_eq!(out, b"\x1b]8;;http://x\x1b\\link");
        assert_eq!(clips, vec!["hi"]);
    }

    #[test]
    fn stray_esc_before_osc52() {
        let mut s = Osc52Scanner::new();
        let (out, clips) = full(&mut s, &[b"\x1b\x1b]52;c;aGk=\x07end"]);
        assert_eq!(out, b"\x1bend");
        assert_eq!(clips, vec!["hi"]);
    }

    #[test]
    fn csi_not_confused() {
        let mut s = Osc52Scanner::new();
        let seq = b"\x1b[200~pasted\x1b[201~";
        let (out, clips) = full(&mut s, &[seq]);
        assert_eq!(out, seq);
        assert!(clips.is_empty());
    }
}
