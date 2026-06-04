// Calls the Zig `greet` command over the bridge. `window.Zigware` is injected by
// the Zigware runtime; run `zig build dts` to regenerate typed declarations for
// your commands. The strict Content-Security-Policy drops 'unsafe-inline', so all
// behavior lives here in an external module and is wired with addEventListener
// (never inline on* handlers).

const nameInput = document.getElementById("name");
const out = document.getElementById("out");
const err = document.getElementById("err");

async function greet(name) {
  err.textContent = "";
  out.textContent = "";
  try {
    const result = await window.Zigware.invoke("greet", { name });
    out.textContent = result.message;
  } catch (e) {
    err.textContent = `error: ${e && e.message ? e.message : e}`;
  }
}

document.getElementById("greet").addEventListener("click", () => {
  greet(nameInput.value);
});

// Greet once on load so a fresh scaffold shows a round-trip to Zig immediately.
greet("world");
