/**
 * Prompt Composer: Native multiline textarea with per-pane drafts,
 * IME composition protection, and explicit Insert vs Enter.
 */

export class Composer {
  constructor(container, options = {}) {
    this.container = container;
    this.onSend = options.onSend || (() => {});
    this.currentPaneId = options.currentPaneId || "default";

    this.drafts = {};
    this.isComposing = false;
    this.isOpen = false;

    this.loadDraftsFromStorage();
    this.render();
  }

  loadDraftsFromStorage() {
    try {
      const saved = sessionStorage.getItem("devbox_pane_drafts");
      if (saved) this.drafts = JSON.parse(saved);
    } catch {}
  }

  saveDraftsToStorage() {
    try {
      sessionStorage.setItem("devbox_pane_drafts", JSON.stringify(this.drafts));
    } catch {}
  }

  setPaneId(newPaneId) {
    if (this.currentPaneId === newPaneId) return;

    // Save current draft
    if (this.textarea) {
      this.drafts[this.currentPaneId] = this.textarea.value;
      this.saveDraftsToStorage();
    }

    this.currentPaneId = newPaneId;
    if (this.textarea) {
      this.textarea.value = this.drafts[newPaneId] || "";
      this.autoResize();
    }
  }

  render() {
    this.container.innerHTML = `
      <div class="composer-header">
        <span id="composer-pane-label">Редактор промпта</span>
        <button type="button" class="btn-control-toggle" id="btn-composer-close">✕ Згорнути</button>
      </div>
      <div class="composer-input-row">
        <textarea
          id="composer-textarea"
          placeholder="Введіть запит для агента або команду..."
          rows="2"
        ></textarea>
        <div class="composer-actions">
          <button type="button" class="btn-composer insert" id="btn-composer-insert" title="Вставити текст у термінал без виконання">
            Вставити
          </button>
          <button type="button" class="btn-composer send" id="btn-composer-send" title="Вставити та виконати (Enter)">
            ↵ Надіслати
          </button>
        </div>
      </div>
    `;

    this.textarea = this.container.querySelector("#composer-textarea");
    this.textarea.value = this.drafts[this.currentPaneId] || "";

    // IME composition events
    this.textarea.addEventListener("compositionstart", () => {
      this.isComposing = true;
    });
    this.textarea.addEventListener("compositionend", () => {
      this.isComposing = false;
    });

    // Auto-save on input
    this.textarea.addEventListener("input", () => {
      this.drafts[this.currentPaneId] = this.textarea.value;
      this.saveDraftsToStorage();
      this.autoResize();
    });

    // Keydown handling
    this.textarea.addEventListener("keydown", (e) => {
      if (this.isComposing) return;
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        this.submit(true);
      }
    });

    this.container.querySelector("#btn-composer-insert").addEventListener("click", () => {
      this.submit(false);
    });

    this.container.querySelector("#btn-composer-send").addEventListener("click", () => {
      this.submit(true);
    });

    this.container.querySelector("#btn-composer-close").addEventListener("click", () => {
      this.toggle(false);
    });
  }

  autoResize() {
    if (!this.textarea) return;
    this.textarea.style.height = "auto";
    const newHeight = Math.min(this.textarea.scrollHeight, 140);
    this.textarea.style.height = Math.max(newHeight, 48) + "px";
  }

  submit(withEnter = false) {
    if (!this.textarea) return;
    const text = this.textarea.value;
    if (!text && !withEnter) return;

    this.onSend({
      text,
      withEnter,
      paneId: this.currentPaneId
    });

    // Clear draft for this pane
    this.textarea.value = "";
    delete this.drafts[this.currentPaneId];
    this.saveDraftsToStorage();
    this.autoResize();
  }

  toggle(forceState) {
    this.isOpen = typeof forceState === "boolean" ? forceState : !this.isOpen;
    if (this.isOpen) {
      this.container.classList.add("open");
      if (this.textarea) {
        this.textarea.focus();
        this.autoResize();
      }
    } else {
      this.container.classList.remove("open");
    }
    return this.isOpen;
  }

  insertText(text) {
    if (!this.textarea) return;
    const start = this.textarea.selectionStart;
    const end = this.textarea.selectionEnd;
    const current = this.textarea.value;
    this.textarea.value = current.substring(0, start) + text + current.substring(end);
    this.textarea.selectionStart = this.textarea.selectionEnd = start + text.length;
    this.drafts[this.currentPaneId] = this.textarea.value;
    this.saveDraftsToStorage();
    this.autoResize();
    this.toggle(true);
  }
}
