// --- bridge shim ---
window.zig = {
  _seq: 0,
  _pending: new Map(),
  invoke(cmd, args) {
    const id = ++this._seq;
    return new Promise((res, rej) => {
      this._pending.set(id, { res, rej });
      window.webkit.messageHandlers.zig.postMessage(JSON.stringify({ id, cmd, args: args || {} }));
    });
  },
  _resolve(id, val) {
    const p = this._pending.get(id);
    if (p) { p.res(val); this._pending.delete(id); }
  },
  _reject(id, err) {
    const p = this._pending.get(id);
    if (p) { p.rej(new Error(err)); this._pending.delete(id); }
  },
  _emit(ch, payload) {
    window.dispatchEvent(new CustomEvent("zig:" + ch, { detail: payload }));
  },
};

// --- demo UI wiring (CSP-safe: no inline script) ---
document.addEventListener("DOMContentLoaded", () => {
  const bar = document.getElementById("bar");
  const pct = document.getElementById("pct");
  const out = document.getElementById("out");
  window.addEventListener("zig:progress", (e) => {
    bar.value = e.detail.pct;
    pct.textContent = e.detail.pct + "%";
  });
  document.getElementById("go").addEventListener("click", async () => {
    out.textContent = "working...";
    bar.value = 0;
    pct.textContent = "0%";
    try {
      const r = await window.zig.invoke("sha256", { megabytes: 300 });
      out.textContent = "SHA-256: " + r.hash;
    } catch (err) {
      out.textContent = "error: " + err.message;
    }
  });
});
