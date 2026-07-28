//! Passive OSC 7 tracker: watches the remote output stream for the shell's
//! `ESC ] 7 ; file://host/path ST|BEL` cwd reports and extracts the path. It
//! does not consume bytes — the same stream still flows through the OSC 52
//! scanner and on to the terminal. Used to scope uploads to the current project.

const PREFIX: &[u8] = b"\x1b]7;";
const MAX: usize = 4096;

#[derive(Default)]
pub struct Osc7Tracker {
    /// bytes of PREFIX matched so far (before the payload)
    prefix: usize,
    /// payload accumulator once inside the sequence
    buf: Option<Vec<u8>>,
    esc_pending: bool,
}

impl Osc7Tracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the new absolute cwd when a complete OSC 7 is parsed.
    pub fn feed(&mut self, input: &[u8]) -> Option<String> {
        let mut result = None;
        for &b in input {
            match self.buf.as_mut() {
                Some(buf) => {
                    if b == 0x07 || (self.esc_pending && b == b'\\') {
                        let payload = std::mem::take(buf);
                        self.reset();
                        if let Some(p) = parse_osc7(&payload) {
                            result = Some(p);
                        }
                    } else if b == 0x1b {
                        self.esc_pending = true;
                    } else if buf.len() >= MAX {
                        self.reset();
                    } else {
                        if self.esc_pending {
                            buf.push(0x1b);
                            self.esc_pending = false;
                        }
                        buf.push(b);
                    }
                }
                None => {
                    if b == PREFIX[self.prefix] {
                        self.prefix += 1;
                        if self.prefix == PREFIX.len() {
                            self.buf = Some(Vec::new());
                            self.esc_pending = false;
                        }
                    } else {
                        self.prefix = usize::from(b == PREFIX[0]);
                    }
                }
            }
        }
        result
    }

    fn reset(&mut self) {
        self.prefix = 0;
        self.buf = None;
        self.esc_pending = false;
    }
}

/// `file://host/path` → decoded absolute path.
fn parse_osc7(buf: &[u8]) -> Option<String> {
    let s = std::str::from_utf8(buf).ok()?;
    let rest = s.strip_prefix("file://")?;
    let slash = rest.find('/')?; // skip the host, path starts at the first '/'
    let path = percent_decode(&rest[slash..]);
    (path.starts_with('/')).then_some(path)
}

fn percent_decode(s: &str) -> String {
    fn hex(b: u8) -> Option<u8> {
        (b as char).to_digit(16).map(|d| d as u8)
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(hi * 16 + lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bel_terminated() {
        let mut t = Osc7Tracker::new();
        assert_eq!(
            t.feed(b"x\x1b]7;file://host/home/dev/proj\x07y"),
            Some("/home/dev/proj".into())
        );
    }

    #[test]
    fn parses_st_terminated_and_percent() {
        let mut t = Osc7Tracker::new();
        assert_eq!(
            t.feed(b"\x1b]7;file://h/tmp/a%20b\x1b\\"),
            Some("/tmp/a b".into())
        );
    }

    #[test]
    fn split_across_chunks() {
        let mut t = Osc7Tracker::new();
        assert_eq!(t.feed(b"\x1b]7;file:"), None);
        assert_eq!(t.feed(b"//h/srv\x07"), Some("/srv".into()));
    }

    #[test]
    fn ignores_other_output() {
        let mut t = Osc7Tracker::new();
        assert_eq!(t.feed(b"\x1b]0;title\x07ls\r\n"), None);
    }
}
