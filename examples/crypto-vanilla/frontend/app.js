// Calls the Zig `cryptoDemo` command over the bridge. `window.Zigware` is
// injected by the Zigware runtime; run `zig build dts` to regenerate typed
// declarations. The strict Content-Security-Policy drops 'unsafe-inline', so all
// behavior lives in this external module wired with addEventListener.
//
// cryptoDemo({ password, message }) resolves with:
//   { sha256, nonce, ciphertext, tag, decrypted, roundTrip }
// every byte field hex-encoded, decrypted being the recovered plaintext.

const form = document.getElementById("form");
const password = document.getElementById("password");
const message = document.getElementById("message");
const out = document.getElementById("out");
const err = document.getElementById("err");

function render(r) {
  out.textContent = [
    `SHA-256(password): ${r.sha256}`,
    `nonce:             ${r.nonce}`,
    `ciphertext:        ${r.ciphertext}`,
    `tag:               ${r.tag}`,
    `decrypted:         ${r.decrypted}`,
    `round-trip:        ${r.roundTrip ? "ok ✓" : "FAILED ✗"}`,
  ].join("\n");
}

async function run() {
  err.textContent = "";
  out.textContent = "working…";
  try {
    const r = await window.Zigware.invoke("cryptoDemo", {
      password: password.value,
      message: message.value,
    });
    render(r);
  } catch (e) {
    out.textContent = "";
    err.textContent = `error: ${e && e.message ? e.message : e}`;
  }
}

form.addEventListener("submit", (e) => {
  e.preventDefault();
  run();
});
