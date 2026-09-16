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
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, \"Roboto Mono\", \"Noto Sans Mono\", monospace",
      scrollback: this.isMobile ? 0 : 1000,
      scrollOnUserInput: false,
      macOptionClickForcesSelection: true,
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
    this.initTouchScrolling();

    // Comprehensively swallow all Device Attributes, Status, and Color queries
    if (this.term.parser) {
      if (this.term.parser.registerCsiHandler) {
        this.term.parser.registerCsiHandler({ final: "c" }, () => true);
        this.term.parser.registerCsiHandler({ prefix: ">", final: "c" }, () => true);
        this.term.parser.registerCsiHandler({ prefix: "?", final: "c" }, () => true);
        this.term.parser.registerCsiHandler({ prefix: "=", final: "c" }, () => true);
        this.term.parser.registerCsiHandler({ final: "n" }, () => true);
        this.term.parser.registerCsiHandler({ prefix: "?", final: "n" }, () => true);
        this.term.parser.registerCsiHandler({ prefix: "?", final: "p" }, () => true);
        this.term.parser.registerCsiHandler({ prefix: "$", final: "p" }, () => true);
        this.term.parser.registerCsiHandler({ final: "t" }, () => true);
      }
      if (this.term.parser.registerOscHandler) {
        this.term.parser.registerOscHandler(4, () => true);
        this.term.parser.registerOscHandler(10, () => true);
        this.term.parser.registerOscHandler(11, () => true);
        this.term.parser.registerOscHandler(12, () => true);
      }
    }

    this.term.onData(data => {
      if (this.isDeviceResponse(data)) return;
      this.onData(data);
    });
  }

  isDeviceResponse(data) {
    if (typeof data !== "string") return false;
    if (data === "\x1b[0n" || data === "0n") return true;
    if (/^\x1b\[[>?=]?[\d;]*c/.test(data) || /^0;276;0c/.test(data)) return true;
    if (/^\x1b\[\d+(;\d+)?R/.test(data)) return true;
    if (/^\x1b\](10|11|12|4);/.test(data)) return true;
    return false;
  }

  initTouchScrolling() {
    let touchId = null;
    let startY = 0;
    let startX = 0;
    let lastY = 0;
    let accumulatedY = 0;
    let isTouchActive = false;
    let isScrolling = false;

    const onTouchStart = (e) => {
      if (e.touches.length !== 1) return;
      const touch = e.touches[0];
      touchId = touch.identifier;
      startY = touch.clientY;
      startX = touch.clientX;
      lastY = touch.clientY;
      accumulatedY = 0;
      isTouchActive = true;
      isScrolling = false;
    };

    const onTouchMove = (e) => {
      if (!isTouchActive) return;
      let touch = null;
      for (let i = 0; i < e.touches.length; i++) {
        if (e.touches[i].identifier === touchId) {
          touch = e.touches[i];
          break;
        }
      }
      if (!touch) return;

      const deltaY = touch.clientY - lastY;
      const totalY = Math.abs(touch.clientY - startY);
      const totalX = Math.abs(touch.clientX - startX);

      if (!isScrolling && totalY > 6) {
        if (totalY > totalX) {
          isScrolling = true;
        } else {
          isTouchActive = false;
          return;
        }
      }

      if (isScrolling) {
        if (e.cancelable) {
          e.preventDefault();
        }

        accumulatedY += deltaY;
        lastY = touch.clientY;

        const rect = this.container.getBoundingClientRect();
        const cols = this.term ? this.term.cols : 80;
        const rows = this.term ? this.term.rows : 24;
        const cellHeight = rect.height / Math.max(1, rows);
        const cellWidth = rect.width / Math.max(1, cols);

        // Step: ~30px per wheel tick
        const step = Math.max(28, Math.round(cellHeight * 2));

        if (Math.abs(accumulatedY) >= step) {
          const lines = Math.floor(Math.abs(accumulatedY) / step);
          const isScrollUp = accumulatedY > 0;
          accumulatedY = accumulatedY % step;

          const col = Math.max(1, Math.min(cols, Math.floor((touch.clientX - rect.left) / cellWidth) + 1));
          const row = Math.max(1, Math.min(rows, Math.floor((touch.clientY - rect.top) / cellHeight) + 1));

          const seq = isScrollUp
            ? `\x1b[<64;${col};${row}M`
            : `\x1b[<65;${col};${row}M`;

          const count = Math.min(lines, 3);
          for (let i = 0; i < count; i++) {
            this.onData(seq);
          }
        }
      }
    };

    const onTouchEnd = (e) => {
      if (isScrolling && e.cancelable) {
        e.preventDefault();
      }
      isTouchActive = false;
      isScrolling = false;
      touchId = null;
    };

    this.container.addEventListener("touchstart", onTouchStart, { passive: true });
    this.container.addEventListener("touchmove", onTouchMove, { passive: false });
    this.container.addEventListener("touchend", onTouchEnd, { passive: false });
    this.container.addEventListener("touchcancel", onTouchEnd, { passive: false });
  }

  fit() {
    if (!this.container || !this.term) return;
    try {
      const core = this.term._core;
      if (core && core._renderService && core._renderService.dimensions) {
        const cellWidth = core._renderService.dimensions.css.cell.width;
        const cellHeight = core._renderService.dimensions.css.cell.height;
        if (cellWidth > 0 && cellHeight > 0) {
          const containerWidth = this.container.clientWidth;
          const containerHeight = this.container.clientHeight;
          if (containerWidth > 0 && containerHeight > 0) {
            const maxCols = Math.max(20, Math.floor(containerWidth / cellWidth));
            const maxRows = Math.max(10, Math.floor(containerHeight / cellHeight));
            if (this.term.cols !== maxCols || this.term.rows !== maxRows) {
              this.term.resize(maxCols, maxRows);
            }
            this.onResize(this.term.cols, this.term.rows);
            return;
          }
        }
      }
      if (this.fitAddon) {
        this.fitAddon.fit();
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
