/**
 * Status Manager: Readable HTML status bar, ownership pills, and toasts.
 */

export class StatusManager {
  constructor(elements = {}, options = {}) {
    this.dot = elements.statusDot;
    this.projectName = elements.projectName;
    this.paneLabel = elements.paneLabel;
    this.controlPill = elements.controlPill;
    this.controlBtn = elements.controlBtn;
    this.toast = elements.toast;

    this.onToggleControl = options.onToggleControl || (() => {});
    this.sessionName = options.sessionName || "main";
    this.token = options.token || "";

    this.controller = "desktop";
    this.readonly = false;
    this.pollInterval = null;

    if (this.controlBtn) {
      this.controlBtn.addEventListener("click", () => {
        this.onToggleControl(this.controller !== "mobile");
      });
    }

    this.initVisibility();
    this.startPolling();
  }

  setConnectionState(state) {
    if (!this.dot) return;
    this.dot.className = "status-dot";
    if (state === "live") {
      this.dot.classList.add("connected");
      this.dot.title = "Підключено (" + this.sessionName + ")";
    } else if (state === "connecting" || state === "reconnecting") {
      this.dot.title = "Підключення...";
    } else {
      this.dot.classList.add("disconnected");
      this.dot.title = "Відключено";
    }
  }

  setControlState(controller, readonly = false) {
    this.controller = controller;
    this.readonly = readonly;

    if (!this.controlPill || !this.controlBtn) return;

    if (controller === "mobile") {
      this.controlPill.className = "control-pill controlled";
      this.controlPill.textContent = "🎮 Телефон керує";
      this.controlBtn.textContent = "Повернути ноутбуку";
    } else {
      this.controlPill.className = "control-pill observer";
      this.controlPill.textContent = "👁️ Перегляд (ноутбук)";
      this.controlBtn.textContent = "Керувати з телефона";
    }
  }

  setPaneInfo(label) {
    if (this.paneLabel) {
      this.paneLabel.textContent = label;
    }
  }

  setProjectName(name) {
    if (this.projectName) {
      this.projectName.textContent = name;
    }
  }

  showToast(message, type = "success", duration = 3000) {
    if (!this.toast) return;
    this.toast.textContent = message;
    this.toast.className = "show " + type;
    setTimeout(() => {
      this.toast.className = "";
    }, duration);
  }

  initVisibility() {
    if (typeof document !== "undefined" && document.addEventListener) {
      document.addEventListener("visibilitychange", () => {
        if (document.hidden) {
          this.stopPolling();
        } else {
          this.startPolling();
          this.fetchStatus();
        }
      });
    }
  }

  startPolling() {
    this.stopPolling();
    this.pollInterval = setInterval(() => this.fetchStatus(), 4000);
  }

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  async fetchStatus() {
    try {
      const headers = {};
      if (this.token) headers["Authorization"] = "Bearer " + this.token;
      const res = await fetch("/api/status?session=" + encodeURIComponent(this.sessionName), { headers });
      const json = await res.json();
      if (json.ok) {
        if (json.cwd) {
          const parts = json.cwd.split("/").filter(Boolean);
          const project = parts[parts.length - 1] || "devbox";
          this.setProjectName(project);
        }
        if (json.controller) {
          this.setControlState(json.controller, this.readonly);
        }
      }
    } catch {}
  }
}
