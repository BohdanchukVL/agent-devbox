/**
 * Panes Manager: Fetches windows/panes, renders bottom sheet, and handles pane switching.
 */

export class PanesManager {
  constructor(options = {}) {
    this.sessionName = options.sessionName || "main";
    this.token = options.token || "";
    this.onPaneSelected = options.onPaneSelected || (() => {});
    this.onZoomToggled = options.onZoomToggled || (() => {});

    this.windows = [];
    this.panes = [];
    this.activePane = null;
    this.activeWindow = null;
    this.isSheetOpen = false;

    this.createSheetDom();
  }

  createSheetDom() {
    // Backdrop
    this.backdrop = document.createElement("div");
    this.backdrop.className = "sheet-backdrop";
    document.body.appendChild(this.backdrop);

    // Sheet
    this.sheet = document.createElement("div");
    this.sheet.className = "bottom-sheet";
    this.sheet.innerHTML = `
      <div class="sheet-header">
        <span class="sheet-title">Вибір вікна та панелі</span>
        <button type="button" class="btn-sheet-close" id="btn-sheet-close">✕</button>
      </div>
      <div style="display: flex; gap: 6px; margin-bottom: 12px;">
        <button type="button" class="btn-header" id="btn-sheet-zoom" style="flex: 1;">
          🔍 Збільшити для всіх (Zoom)
        </button>
      </div>
      <div class="pane-list" id="pane-list-container">
        <div style="color: var(--text-muted); font-size: 13px; text-align: center; padding: 20px;">
          Завантаження панелей...
        </div>
      </div>
    `;
    document.body.appendChild(this.sheet);

    this.listContainer = this.sheet.querySelector("#pane-list-container");
    this.zoomBtn = this.sheet.querySelector("#btn-sheet-zoom");

    this.backdrop.addEventListener("click", () => this.close());
    this.sheet.querySelector("#btn-sheet-close").addEventListener("click", () => this.close());
    this.zoomBtn.addEventListener("click", () => {
      this.onZoomToggled();
      this.close();
    });
  }

  async fetchPanes() {
    try {
      const headers = {};
      if (this.token) headers["Authorization"] = "Bearer " + this.token;
      const res = await fetch("/api/panes?session=" + encodeURIComponent(this.sessionName), { headers });
      const json = await res.json();
      if (json.ok) {
        this.updateData(json.windows, json.panes);
      }
    } catch (e) {
      console.warn("Failed to fetch panes:", e);
    }
  }

  updateData(windows = [], panes = []) {
    this.windows = windows;
    this.panes = panes;

    this.activeWindow = windows.find(w => w.active) || windows[0] || null;
    this.activePane = panes.find(p => p.active) || panes[0] || null;

    if (this.isSheetOpen) {
      this.renderList();
    }
  }

  renderList() {
    if (!this.listContainer) return;
    if (this.panes.length === 0) {
      this.listContainer.innerHTML = `
        <div style="color: var(--text-muted); font-size: 13px; text-align: center; padding: 20px;">
          Панелей не знайдено
        </div>
      `;
      return;
    }

    this.listContainer.innerHTML = "";
    for (const pane of this.panes) {
      const win = this.windows.find(w => w.id === pane.windowId);
      const winLabel = win ? (win.index + ":" + win.name) : "Window";
      const cmdName = pane.command || "shell";
      const pathLabel = pane.path ? pane.path.split("/").slice(-2).join("/") : "";
      const isActive = pane.active;

      const item = document.createElement("div");
      item.className = "pane-item" + (isActive ? " active" : "");
      item.innerHTML = `
        <div class="pane-item-info">
          <div class="pane-item-name">
            ${winLabel} · ${cmdName} ${pane.index ? ("(" + pane.index + ")") : ""}
          </div>
          <div class="pane-item-path">${pathLabel || pane.path}</div>
        </div>
        ${isActive ? `<span class="pane-item-badge">Активна</span>` : ""}
      `;

      item.addEventListener("click", () => {
        this.selectPane(pane);
      });

      this.listContainer.appendChild(item);
    }

    if (this.activeWindow && this.activeWindow.zoomed) {
      this.zoomBtn.textContent = "🔍 Зняти збільшення (Unzoom)";
      this.zoomBtn.classList.add("active");
    } else {
      this.zoomBtn.textContent = "🔍 Збільшити для всіх (Shared Zoom)";
      this.zoomBtn.classList.remove("active");
    }
  }

  selectPane(pane) {
    this.activePane = pane;
    this.onPaneSelected(pane);
    this.close();
  }

  open() {
    this.isSheetOpen = true;
    this.backdrop.classList.add("show");
    this.sheet.classList.add("show");
    this.fetchPanes().then(() => this.renderList());
  }

  close() {
    this.isSheetOpen = false;
    this.backdrop.classList.remove("show");
    this.sheet.classList.remove("show");
  }

  getActivePaneLabel() {
    if (!this.activePane) return "Термінал";
    const win = this.windows.find(w => w.id === this.activePane.windowId);
    const winPrefix = win ? (win.index + ": ") : "";
    const cmd = this.activePane.command || "shell";
    return winPrefix + cmd;
  }
}
