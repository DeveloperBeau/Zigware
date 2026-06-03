import { useState } from "react";

// Calls the Zig `greet` command over the bridge. `window.Zigware` is injected by
// the Zigware runtime; the generated frontend/bindings.d.ts (run `zig build dts`)
// types `invoke` for you.
export default function App() {
  const [name, setName] = useState("world");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function onGreet() {
    setError("");
    setMessage("");
    try {
      const result = await window.Zigware.invoke("greet", { name });
      setMessage(result.message);
    } catch (err) {
      setError(String(err && err.message ? err.message : err));
    }
  }

  return (
    <main className="app">
      <h1>{name ? `Hello from ${name}` : "Zigware + React"}</h1>
      <p className="hint">Type a name and call the Zig command.</p>
      <div className="row">
        <input
          className="field"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="name"
        />
        <button className="btn" onClick={onGreet}>
          Greet
        </button>
      </div>
      {message ? <p className="out">{message}</p> : null}
      {error ? <p className="err">error: {error}</p> : null}
    </main>
  );
}
