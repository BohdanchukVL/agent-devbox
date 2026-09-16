/**
 * Uploads Manager: File & photo upload, drag-and-drop, and progress reporting.
 */

export class UploadsManager {
  constructor(options = {}) {
    this.sessionName = options.sessionName || "main";
    this.token = options.token || "";
    this.onUploadSuccess = options.onUploadSuccess || (() => {});
    this.onToast = options.onToast || (() => {});

    this.createDom();
  }

  createDom() {
    this.photoInput = document.createElement("input");
    this.photoInput.type = "file";
    this.photoInput.accept = "image/*";
    this.photoInput.capture = "environment";
    this.photoInput.style.display = "none";
    document.body.appendChild(this.photoInput);

    this.fileInput = document.createElement("input");
    this.fileInput.type = "file";
    this.fileInput.style.display = "none";
    document.body.appendChild(this.fileInput);

    this.photoInput.addEventListener("change", (e) => {
      if (e.target.files && e.target.files[0]) {
        this.uploadFile(e.target.files[0]);
        this.photoInput.value = "";
      }
    });

    this.fileInput.addEventListener("change", (e) => {
      if (e.target.files && e.target.files[0]) {
        this.uploadFile(e.target.files[0]);
        this.fileInput.value = "";
      }
    });

    // Paste listener (e.g. Cmd+V images from clipboard)
    window.addEventListener("paste", (e) => {
      const items = (e.clipboardData || e.originalEvent?.clipboardData)?.items;
      if (!items) return;
      for (const item of items) {
        if (item.kind === "file") {
          const file = item.getAsFile();
          if (file) {
            e.preventDefault();
            this.uploadFile(file);
            break;
          }
        }
      }
    });
  }

  triggerPhoto() {
    if (this.photoInput) this.photoInput.click();
  }

  triggerFile() {
    if (this.fileInput) this.fileInput.click();
  }

  async uploadFile(file) {
    if (!file) return;
    this.onToast("Завантаження " + file.name + "...", "success", 4000);

    const formData = new FormData();
    formData.append("file", file);

    try {
      const headers = {};
      if (this.token) headers["Authorization"] = "Bearer " + this.token;

      const res = await fetch("/api/upload?session=" + encodeURIComponent(this.sessionName), {
        method: "POST",
        headers,
        body: formData
      });

      const json = await res.json();
      if (json.ok && json.file) {
        this.onToast("✓ Завантажено: " + json.file.path, "success", 4000);
        this.onUploadSuccess(json.file);
      } else {
        this.onToast("Помилка: " + (json.error || "не вдалося завантажити"), "error", 4000);
      }
    } catch (err) {
      this.onToast("Помилка мережі: " + err.message, "error", 4000);
    }
  }
}
