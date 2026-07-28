//! Streaming bracketed-paste interceptor for the stdin side.
//!
//! When the local terminal has bracketed paste enabled, a ⌘V (or a drag-and-drop
//! in Ghostty) arrives as `ESC[200~ <body> ESC[201~`. We split those bodies out
//! of the keystroke stream so the proxy can decide whether the pasted text is a
//! set of local file paths to upload. Everything else passes through byte-exact.
//!
//! Markers can be split across read boundaries, so the matcher is stateful.

const START: &[u8] = b"\x1b[200~";
const END: &[u8] = b"\x1b[201~";
/// Give up buffering a paste with no end marker past this size (forward as-is).
const MAX_BODY: usize = 16 << 20;

#[derive(Debug, PartialEq)]
pub enum PasteEvent {
    /// bytes outside any paste — forward to the remote unchanged
    Pass(Vec<u8>),
    /// a complete paste body, markers stripped
    Paste(Vec<u8>),
}

#[derive(Default)]
pub struct PasteScanner {
    in_paste: bool,
    body: Vec<u8>,
    /// bytes that so far partially match the current target marker
    pend: Vec<u8>,
}

impl PasteScanner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn feed(&mut self, input: &[u8]) -> Vec<PasteEvent> {
        let mut events = Vec::new();
        let mut pass = Vec::new();

        for &b in input {
            let target = if self.in_paste { END } else { START };
            let mut candidate = std::mem::take(&mut self.pend);
            candidate.push(b);

            if target.starts_with(&candidate) {
                if candidate.len() == target.len() {
                    // full marker
                    if self.in_paste {
                        events.push(PasteEvent::Paste(std::mem::take(&mut self.body)));
                        self.in_paste = false;
                    } else {
                        if !pass.is_empty() {
                            events.push(PasteEvent::Pass(std::mem::take(&mut pass)));
                        }
                        self.in_paste = true;
                        self.body.clear();
                    }
                } else {
                    self.pend = candidate;
                }
                continue;
            }

            // not a marker prefix: the held bytes belong to the stream. Release
            // all but the last (which may itself start a fresh marker), then
            // reconsider that last byte against an empty pend.
            candidate.pop();
            self.release(&candidate, &mut pass);
            if START.first() == Some(&b) && !self.in_paste
                || END.first() == Some(&b) && self.in_paste
            {
                self.pend.push(b);
            } else {
                self.release(&[b], &mut pass);
            }
        }

        if !pass.is_empty() {
            events.push(PasteEvent::Pass(pass));
        }
        if self.in_paste && self.body.len() > MAX_BODY {
            // runaway paste with no end marker: bail out, forward what we have
            let mut raw = START.to_vec();
            raw.append(&mut self.body);
            self.in_paste = false;
            events.push(PasteEvent::Pass(raw));
        }
        events
    }

    fn release(&mut self, bytes: &[u8], pass: &mut Vec<u8>) {
        if self.in_paste {
            self.body.extend_from_slice(bytes);
        } else {
            pass.extend_from_slice(bytes);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_all(s: &mut PasteScanner, chunks: &[&[u8]]) -> Vec<PasteEvent> {
        let mut out = Vec::new();
        for c in chunks {
            out.extend(s.feed(c));
        }
        out
    }

    #[test]
    fn plain_input_passes_through() {
        let mut s = PasteScanner::new();
        assert_eq!(
            s.feed(b"ls -la\r"),
            vec![PasteEvent::Pass(b"ls -la\r".to_vec())]
        );
    }

    #[test]
    fn extracts_paste_body() {
        let mut s = PasteScanner::new();
        let ev = s.feed(b"a\x1b[200~/tmp/x\x1b[201~b");
        assert_eq!(
            ev,
            vec![
                PasteEvent::Pass(b"a".to_vec()),
                PasteEvent::Paste(b"/tmp/x".to_vec()),
                PasteEvent::Pass(b"b".to_vec()),
            ]
        );
    }

    #[test]
    fn markers_split_across_chunks() {
        let mut s = PasteScanner::new();
        let ev = feed_all(&mut s, &[b"\x1b[2", b"00~body", b" more\x1b[20", b"1~"]);
        assert_eq!(ev, vec![PasteEvent::Paste(b"body more".to_vec())]);
    }

    #[test]
    fn esc_that_is_not_a_marker_passes() {
        let mut s = PasteScanner::new();
        // a bare ESC followed by unrelated bytes
        assert_eq!(
            s.feed(b"\x1b[A"),
            vec![PasteEvent::Pass(b"\x1b[A".to_vec())]
        );
    }

    #[test]
    fn esc_inside_paste_body_is_kept() {
        let mut s = PasteScanner::new();
        let ev = s.feed(b"\x1b[200~a\x1bb\x1b[201~");
        assert_eq!(ev, vec![PasteEvent::Paste(b"a\x1bb".to_vec())]);
    }

    #[test]
    fn false_marker_start_recovers() {
        let mut s = PasteScanner::new();
        // ESC [ 2 0 1 ~ is the END marker, invalid as a start → passes through
        assert_eq!(
            s.feed(b"\x1b[201~x"),
            vec![PasteEvent::Pass(b"\x1b[201~x".to_vec())]
        );
    }
}
