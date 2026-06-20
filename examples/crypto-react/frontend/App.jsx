import { useState } from "react";

// Calls the Zig `cryptoDemo` command over the bridge. `window.Zigware` is
// injected by the Zigware runtime; run `zig build dts` to type `invoke` from
// src/commands. cryptoDemo({ password, message }) resolves with
// { sha256, nonce, ciphertext, tag, decrypted, roundTrip } (byte fields hex).
export default function App() {
  const [password, setPassword] = useState("correct horse battery staple");
  const [message, setMessage] = useState("attack at dawn");
  const [result, setResult] = useState(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e) {
    e.preventDefault();
    setError("");
    setResult(null);
    setBusy(true);
    try {
      const r = await window.Zigware.invoke("cryptoDemo", { password, message });
      setResult(r);
    } catch (err) {
      setError(String(err && err.message ? err.message : err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="app">
      <h1>Crypto round-trip</h1>
      <p className="hint">
        Zig hashes the password with SHA-256, then encrypts the message with
        ChaCha20-Poly1305 and decrypts it back to prove the round-trip.
      </p>
      <form className="form" onSubmit={onSubmit}>
        <label className="label" htmlFor="password">
          Password
        </label>
        <input
          id="password"
          className="field"
          type="password"
          autoComplete="off"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <label className="label" htmlFor="message">
          Message to encrypt
        </label>
        <input
          id="message"
          className="field"
          type="text"
          value={message}
          onChange={(e) => setMessage(e.target.value)}
        />
        <button className="btn" type="submit" disabled={busy}>
          {busy ? "Working…" : "Hash & encrypt"}
        </button>
      </form>
      {result ? (
        <pre className="out">
          {`SHA-256(password): ${result.sha256}
nonce:             ${result.nonce}
ciphertext:        ${result.ciphertext}
tag:               ${result.tag}
decrypted:         ${result.decrypted}
round-trip:        ${result.roundTrip ? "ok ✓" : "FAILED ✗"}`}
        </pre>
      ) : null}
      {error ? <p className="err">error: {error}</p> : null}
    </main>
  );
}
