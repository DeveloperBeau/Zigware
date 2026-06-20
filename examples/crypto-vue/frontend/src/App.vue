<script setup>
import { ref } from "vue";

const password = ref("correct horse battery staple");
const message = ref("attack at dawn");
const result = ref(null);
const error = ref("");
const busy = ref(false);

// window.Zigware.invoke is injected by the Zigware runtime. The "cryptoDemo"
// command is defined in src/commands/crypto.zig.
async function run() {
  error.value = "";
  result.value = null;
  busy.value = true;
  try {
    result.value = await window.Zigware.invoke("cryptoDemo", {
      password: password.value,
      message: message.value,
    });
  } catch (err) {
    error.value = err.message ?? String(err);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <main class="app">
    <h1>Crypto round-trip</h1>
    <p class="hint">
      Zig hashes the password with SHA-256, then encrypts the message with
      ChaCha20-Poly1305 and decrypts it back to prove the round-trip.
    </p>
    <form class="form" @submit.prevent="run">
      <label class="label" for="password">Password</label>
      <input id="password" class="field" type="password" autocomplete="off" v-model="password" />
      <label class="label" for="message">Message to encrypt</label>
      <input id="message" class="field" type="text" v-model="message" />
      <button class="btn" type="submit" :disabled="busy">
        {{ busy ? "Working…" : "Hash & encrypt" }}
      </button>
    </form>
    <pre v-if="result" class="out">SHA-256(password): {{ result.sha256 }}
nonce:             {{ result.nonce }}
ciphertext:        {{ result.ciphertext }}
tag:               {{ result.tag }}
decrypted:         {{ result.decrypted }}
round-trip:        {{ result.roundTrip ? "ok ✓" : "FAILED ✗" }}</pre>
    <p v-if="error" class="err">error: {{ error }}</p>
  </main>
</template>
