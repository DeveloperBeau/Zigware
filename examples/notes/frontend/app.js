// Notes example UI (CSP-safe: no inline script; the shim lives in zigware.js).
//
// invoke("hashFile", {path}, {onStream}) streams integer-percent progress and
// resolves with the hex digest. The Cancel button issues compute.cancel for the
// in-flight invocation; the backend flips that invocation's own cancel flag and
// the worker bails between 64 KiB chunks, settling the original promise with a
// `cancelled` rejection the frontend branches on by code.

document.addEventListener("DOMContentLoaded", () => {
  const pathInput = document.getElementById("path");
  const go = document.getElementById("go");
  const cancel = document.getElementById("cancel");
  const bar = document.getElementById("bar");
  const pct = document.getElementById("pct");
  const out = document.getElementById("out");

  let running = false;
  let currentId = null;

  function setRunning(on) {
    running = on;
    go.disabled = on;
    cancel.disabled = !on;
    pathInput.disabled = on;
  }

  async function run() {
    if (running) return;
    const path = pathInput.value.trim();
    if (!path) {
      out.textContent = "enter a file path";
      return;
    }
    setRunning(true);
    out.textContent = "hashing…";
    bar.value = 0;
    pct.textContent = "0%";
    try {
      const promise = window.Zigware.invoke(
        "hashFile",
        { path },
        {
          onStream: (frame) => {
            bar.value = frame.pct;
            pct.textContent = frame.pct + "%";
          },
        }
      );
      // invoke just incremented _seq to this call's id; capture it so Cancel can
      // target this exact invocation.
      currentId = window.Zigware._seq;
      const r = await promise;
      out.textContent = "SHA-256: " + r.hash;
    } catch (err) {
      // The secure-default denial surfaces here as code "scope.path.no_match";
      // a user cancel arrives as "cancelled". Both are ZigError with a .code.
      if (err.code === "scope.path.no_match") {
        out.textContent = "denied: that path is outside $APPDATA/notes/**";
      } else if (err.code === "cancelled") {
        out.textContent = "cancelled";
      } else {
        out.textContent = "error: " + err.message;
      }
    } finally {
      currentId = null;
      setRunning(false);
    }
  }

  function requestCancel() {
    if (currentId == null) return;
    // Fire-and-forget: the original invoke's promise settles with the cancel.
    window.Zigware.invoke("compute.cancel", { id: currentId }).catch(() => {});
  }

  go.addEventListener("click", run);
  cancel.addEventListener("click", requestCancel);
  pathInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") run();
  });
});
