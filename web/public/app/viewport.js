/**
 * Viewport & Virtual Keyboard Controller
 * Uses window.visualViewport to dynamically pin UI above OSK
 */

export class ViewportController {
  constructor(options = {}) {
    this.onResize = options.onResize || null;
    this.isKeyboardOpen = false;
    this.lastHeight = 0;
    this.rafId = null;

    this.init();
  }

  init() {
    this.update();

    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", () => this.scheduleUpdate());
      window.visualViewport.addEventListener("scroll", () => this.scheduleUpdate());
    }

    window.addEventListener("resize", () => this.scheduleUpdate());
    window.addEventListener("orientationchange", () => {
      setTimeout(() => this.scheduleUpdate(), 100);
    });
  }

  scheduleUpdate() {
    if (this.rafId) cancelAnimationFrame(this.rafId);
    this.rafId = requestAnimationFrame(() => {
      this.update();
      this.rafId = null;
    });
  }

  update() {
    const vv = window.visualViewport;
    const height = vv ? Math.round(vv.height) : window.innerHeight;
    const offsetTop = vv ? Math.round(vv.offsetTop) : 0;
    
    // Virtual keyboard detection heuristic
    const heightDiff = window.innerHeight - height;
    const keyboardOpen = heightDiff > 140;

    this.isKeyboardOpen = keyboardOpen;
    document.documentElement.style.setProperty("--app-height", height + "px");
    document.documentElement.style.setProperty("--keyboard-offset", offsetTop + "px");

    if (this.lastHeight !== height) {
      this.lastHeight = height;
      if (typeof this.onResize === "function") {
        this.onResize({ height, offsetTop, isKeyboardOpen: keyboardOpen });
      }
    }
  }

  getHeight() {
    return this.lastHeight || window.innerHeight;
  }
}
