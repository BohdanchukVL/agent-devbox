/**
 * Main Application Coordinator
 * Wires together Terminal, Transport, Viewport, Panes, Composer, Status, and Dock.
 */

import { ViewportController } from "./viewport.js";
import { Transport } from "./transport.js";
import { TerminalController } from "./terminal.js";
import { Composer } from "./composer.js";
import { PanesManager } from "./panes.js";
import { StatusManager } from "./status.js";
import { UploadsManager } from "./uploads.js";

function initApp() {
  const isMobile = window.innerWidth <= 768 || ("ontouchstart" in window);
  const clientType = isMobile ? "mobile" : "desktop";

  // URL parameters & session persistence
  const urlParams = new URLSearchParams(window.location.search);
  const token = urlParams.get("token") || sessionStorage.getItem("devbox_token") || "";
  if (urlParams.get("token")) {
    sessionStorage.setItem("devbox_token", urlParams.get("token"));
  }

  let sessionName = sessionStorage.getItem("devbox_client_session");
  if (!sessionName) {
    const rand = Math.random().toString(36).slice(2, 8);
    sessionName = "web-" + clientType + "-" + rand;
    sessionStorage.setItem("devbox_client_session", sessionName);
  }

  // DOM references
  const terminalContainer = document.getElementById("terminal-container");
  const composerContainer = document.getElementById("composer-dock");
  const statusDot = document.getElementById("status-dot");
  const projectName = document.getElementById("project-name");
  const paneLabel = document.getElementById("pane-label");
  const controlPill = document.getElementById("control-pill");
  const btnControlToggle = document.getElementById("btn-control-toggle");
  const btnPanes = document.getElementById("btn-panes");
  const toast = document.getElementById("toast");

  // 1. Status Manager
  const statusManager = new StatusManager({
    statusDot,
    projectName,
    paneLabel,
    controlPill,
    controlBtn: btnControlToggle,
    toast
  }, {
    sessionName,
    token,
    onToggleControl: (requestMobile) => {
      if (requestMobile) {
        transport.requestControl();
      } else {
        transport.releaseControl();
      }
    }
  });

  // 2. Terminal Controller
  const terminalController = new TerminalController(document.getElementById("terminal"), {
    isMobile,
    onData: (data) => {
      transport.sendRaw(data);
    },
    onResize: (cols, rows) => {
      transport.sendResize(cols, rows);
    }
  });
  terminalController.init();

  // 3. Transport
  const transport = new Transport({
    clientType,
    sessionName,
    token,
    cols: terminalController.cols,
    rows: terminalController.rows,
    onOutput: (data) => {
      terminalController.write(data);
    },
    onStatusChange: (state) => {
      statusManager.setConnectionState(state);
    },
    onControlChanged: (controller, readonly) => {
      statusManager.setControlState(controller, readonly);
      if (controller === "mobile") {
        terminalController.scheduleFit(50);
      }
    },
    onPanesUpdate: (data) => {
      if (data && data.windows && data.panes) {
        panesManager.updateData(data.windows, data.panes);
        statusManager.setPaneInfo(panesManager.getActivePaneLabel());
      }
    },
    onError: (msg) => {
      statusManager.showToast(msg, "error");
    },
    onSessionAssigned: (name) => {
      sessionName = name;
      sessionStorage.setItem("devbox_client_session", sessionName);
    }
  });

  // 4. Viewport Controller
  const viewportController = new ViewportController({
    onResize: ({ height, isKeyboardOpen }) => {
      terminalController.scheduleFit(60);
    }
  });

  // 5. Composer
  const composer = new Composer(composerContainer, {
    currentPaneId: "default",
    onSend: ({ text, withEnter, paneId }) => {
      if (text) {
        transport.sendInput(text + (withEnter ? "\r" : ""), paneId);
      } else if (withEnter) {
        transport.sendRaw("\r");
      }
    }
  });

  // 6. Panes Manager
  const panesManager = new PanesManager({
    sessionName,
    token,
    onPaneSelected: (pane) => {
      transport.sendAction("select-pane", pane.id);
      composer.setPaneId(pane.id);
      statusManager.setPaneInfo(panesManager.getActivePaneLabel());
    },
    onZoomToggled: () => {
      transport.sendAction("zoom");
    }
  });

  if (btnPanes) {
    btnPanes.addEventListener("click", () => {
      panesManager.open();
    });
  }

  // 7. Uploads Manager
  const uploadsManager = new UploadsManager({
    sessionName,
    token,
    onToast: (msg, type, duration) => {
      statusManager.showToast(msg, type, duration);
    },
    onUploadSuccess: (file) => {
      composer.insertText(file.path + " ");
    }
  });

  // 8. Quick Action Dock
  let ctrlSticky = false;
  const btnCtrl = document.getElementById("dock-ctrl");

  function sendKey(seq) {
    if (ctrlSticky) {
      // Apply ctrl modifier to ASCII letter
      if (seq.length === 1) {
        const code = seq.toUpperCase().charCodeAt(0);
        if (code >= 65 && code <= 90) {
          seq = String.fromCharCode(code - 64);
        }
      }
      ctrlSticky = false;
      if (btnCtrl) btnCtrl.classList.remove("active");
    }
    transport.sendRaw(seq);
  }

  function bindClick(id, handler) {
    const el = document.getElementById(id);
    if (el) el.addEventListener("click", handler);
  }

  bindClick("dock-esc", () => sendKey("\x1b"));
  bindClick("dock-tab", () => sendKey("\t"));
  bindClick("dock-enter", () => sendKey("\r"));
  bindClick("dock-up", () => sendKey("\x1b[A"));
  bindClick("dock-down", () => sendKey("\x1b[B"));
  bindClick("dock-slash", () => sendKey("/"));
  bindClick("dock-break", () => sendKey("\x03")); // Ctrl-C
  bindClick("dock-zoom", () => transport.sendAction("zoom"));
  bindClick("dock-composer", () => composer.toggle());
  bindClick("dock-photo", () => uploadsManager.triggerPhoto());
  bindClick("dock-file", () => uploadsManager.triggerFile());

  if (btnCtrl) {
    btnCtrl.addEventListener("click", () => {
      ctrlSticky = !ctrlSticky;
      btnCtrl.classList.toggle("active", ctrlSticky);
    });
  }

  // Drag and drop overlay
  const dropOverlay = document.getElementById("drop-overlay");
  let dragCounter = 0;

  terminalContainer.addEventListener("dragenter", (e) => {
    e.preventDefault();
    dragCounter++;
    if (dropOverlay) dropOverlay.style.display = "flex";
  });
  terminalContainer.addEventListener("dragleave", (e) => {
    e.preventDefault();
    dragCounter--;
    if (dragCounter <= 0 && dropOverlay) {
      dragCounter = 0;
      dropOverlay.style.display = "none";
    }
  });
  terminalContainer.addEventListener("dragover", (e) => {
    e.preventDefault();
  });
  terminalContainer.addEventListener("drop", (e) => {
    e.preventDefault();
    dragCounter = 0;
    if (dropOverlay) dropOverlay.style.display = "none";
    if (e.dataTransfer && e.dataTransfer.files.length > 0) {
      for (const file of e.dataTransfer.files) {
        uploadsManager.uploadFile(file);
      }
    }
  });

  // Start
  transport.connect();
}

window.addEventListener("DOMContentLoaded", initApp);
