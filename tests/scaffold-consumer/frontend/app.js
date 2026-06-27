// Scaffold consumer frontend. Invokes the greet command over the bridge.
window.addEventListener("DOMContentLoaded", async () => {
  const r = await window.Zigware.invoke("greet", { name: "world" });
  document.body.append(r.message);
});
