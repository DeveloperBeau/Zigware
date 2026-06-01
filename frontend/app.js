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
  const go = document.getElementById("go");
  const again = document.getElementById("again");
  const bar = document.getElementById("bar");
  const pct = document.getElementById("pct");
  const out = document.getElementById("out");

  let running = false;

  window.addEventListener("zig:progress", (e) => {
    bar.value = e.detail.pct;
    pct.textContent = e.detail.pct + "%";
  });

  async function run() {
    if (running) return; // guard: no overlapping 300 MB jobs
    running = true;
    go.disabled = true;
    again.disabled = true;
    out.textContent = "working...";
    bar.value = 0;
    pct.textContent = "0%";
    try {
      const r = await window.zig.invoke("sha256", { megabytes: 300 });
      out.textContent = "SHA-256: " + r.hash;
    } catch (err) {
      out.textContent = "error: " + err.message;
    } finally {
      running = false;
      go.disabled = false;
      again.disabled = false;
      again.hidden = false; // reveal "Run again" once a run has completed
    }
  }

  go.addEventListener("click", run);
  again.addEventListener("click", run);
});
