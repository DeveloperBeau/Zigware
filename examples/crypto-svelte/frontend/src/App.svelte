<script>
  // window.Zigware.invoke is injected by the Zigware runtime. The "cryptoDemo"
  // command is defined in src/commands/crypto.zig.
  let password = $state("correct horse battery staple");
  let message = $state("attack at dawn");
  let result = $state(null);
  let error = $state("");
  let busy = $state(false);

  async function run() {
    error = "";
    result = null;
    busy = true;
    try {
      result = await window.Zigware.invoke("cryptoDemo", { password, message });
    } catch (err) {
      error = err?.message ?? String(err);
    } finally {
      busy = false;
    }
  }
</script>

<main class="app">
  <h1>Crypto round-trip</h1>
  <p class="hint">
    Zig hashes the password with SHA-256, then encrypts the message with
    ChaCha20-Poly1305 and decrypts it back to prove the round-trip.
  </p>

  <form class="form" onsubmit={(e) => { e.preventDefault(); run(); }}>
    <label class="label" for="password">Password</label>
    <input id="password" class="field" type="password" autocomplete="off" bind:value={password} />
    <label class="label" for="message">Message to encrypt</label>
    <input id="message" class="field" type="text" bind:value={message} />
    <button class="btn" type="submit" disabled={busy}>
      {busy ? "Working…" : "Hash & encrypt"}
    </button>
  </form>

  {#if result}
    <pre class="out">SHA-256(password): {result.sha256}
nonce:             {result.nonce}
ciphertext:        {result.ciphertext}
tag:               {result.tag}
decrypted:         {result.decrypted}
round-trip:        {result.roundTrip ? "ok ✓" : "FAILED ✗"}</pre>
  {/if}
  {#if error}
    <p class="err">error: {error}</p>
  {/if}
</main>
