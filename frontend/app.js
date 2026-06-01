// --- demo UI wiring (CSP-safe: no inline script; shim lives in zigware.js) ---
document.addEventListener("DOMContentLoaded", () => {
  const go = document.getElementById("go");
  const again = document.getElementById("again");
  const bar = document.getElementById("bar");
  const pct = document.getElementById("pct");
  const out = document.getElementById("out");

  let running = false;

  async function run() {
    if (running) return;
    running = true;
    go.disabled = true;
    again.disabled = true;
    out.textContent = "working...";
    bar.value = 0;
    pct.textContent = "0%";
    try {
      const r = await window.Zigware.invoke(
        "sha256",
        { megabytes: 300 },
        {
          onStream: (frame) => {
            bar.value = frame.pct;
            pct.textContent = frame.pct + "%";
          },
        }
      );
      out.textContent = "SHA-256: " + r.hash;
    } catch (err) {
      out.textContent = "error: " + err.message;
    } finally {
      running = false;
      go.disabled = false;
      again.disabled = false;
      again.hidden = false;
    }
  }

  go.addEventListener("click", run);
  again.addEventListener("click", run);
});
