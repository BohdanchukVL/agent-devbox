/**
 * Terminal Controller: xterm.js setup, FitAddon, WebGL, CSI query swallow, and key forwarding.
 */

export class TerminalController {
  constructor(container, options = {}) {
    this.container = container;
    this.isMobile = options.isMobile || false;
    this.onData = options.onData || (() => {});
    this.onResize = options.onResize || (() => {});

    this.term = null;
    this.fitAddon = null;
    this.webglAddon = null;
    this.fontSize = this.isMobile ? 14 : 15;
    this.resizeTimer = null;
  }

  init() {
    if (typeof Terminal === "undefined" || typeof FitAddon === "undefined") {
      throw new Error("XTerm or FitAddon not loaded");
    }

    this.term = new Terminal({
      cursorBlink: true,
      fontSize: this.fontSize,
      fontFamily: "ui-monospace, \"SF Mono\", Menlo, Monaco, \"Cascadia Code\", monospace",
      theme: {
        background: "#121212",
        foreground: "#d4d4d4",
        cursor: "#20b2aa",
        selectionBackground: "#005f5f",
        black: "#1c1c1c",
        red: "#d75f5f",
        green: "#87af87",
        yellow: "#dfaf5f",
        blue: "#87afd7",
        magenta: "#af87af",
        cyan: "#5fafaf",
        white: "#e4e4e4",
        brightBlack: "#4e4e4e",
        brightRed: "#ff5f5f",
        brightGreen: "#afdfaf",
        brightYellow: "#ffff87",
        brightBlue: "#afffff",
        brightMagenta: "#dfafff",
        brightCyan: "#87ffff",
        brightWhite: "#ffffff"
      },
      allowProposedApi: true
    });

    this.fitAddon = new FitAddon.FitAddon();
    this.term.loadAddon(this.fitAddon);

    if (typeof WebglAddon !== "undefined") {
      try {
        this.webglAddon = new WebglAddon.WebglAddon();
        this.webglAddon.onContextLoss(() => {
          this.webglAddon.dispose();
          this.webglAddon = null;
        });
        this.term.loadAddon(this.webglAddon);
      } catch (e) {
        console.warn("WebGL addon unavailable, using default canvas renderer", e);
      }
    }

    this.term.open(this.container);
    this.fit();

    // Swallow Device Attributes queries so xterm.js doesn't emit responses (e.g. \x1b[>0;276;0c) into stdin
    if (this.term.parser && this.term.parser.registerCsiHandler) {
      this.term.parser.registerCsiHandler({ prefix: ">", final: "c" }, () => true);
      this.term.parser.registerCsiHandler({ final: "c" }, () => true);
    }

    this.term.onData(data => {
      this.onData(data);
    });
  }

  fit() {
    if (!this.fitAddon || !this.container) return;
    try {
      this.fitAddon.fit();
      if (this.term) {
        this.onResize(this.term.cols, this.term.rows);
      }
    } catch {}
  }

  scheduleFit(delay = 80) {
    if (this.resizeTimer) clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout(() => {
      this.fit();
    }, delay);
  }

  write(data) {
    if (this.term) {
      this.term.write(data);
    }
  }

  focus() {
    if (this.term) {
      this.term.focus();
    }
  }

  get cols() {
    return this.term ? this.term.cols : 80;
  }

  get rows() {
    return this.term ? this.term.rows : 24;
  }

  setFontSize(size) {
    this.fontSize = Math.max(10, Math.min(24, size));
    if (this.term) {
      this.term.options.fontSize = this.fontSize;
      this.scheduleFit(30);
    }
  }
}
