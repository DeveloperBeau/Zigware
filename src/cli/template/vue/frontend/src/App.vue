<script setup>
import { ref } from "vue";

const name = ref("world");
const message = ref("");
const error = ref("");

async function greet() {
  error.value = "";
  message.value = "";
  try {
    // window.Zigware.invoke is injected by the Zigware runtime. The "greet"
    // command is defined in src/commands/greet.zig; its argument and return
    // types are mirrored into frontend/bindings.d.ts by `zig build dts`.
    const result = await window.Zigware.invoke("greet", { name: name.value });
    message.value = result.message;
  } catch (err) {
    error.value = err.message ?? String(err);
  }
}
</script>

<template>
  <main class="app">
    <h1>{{ "Welcome to Zigware" }}</h1>
    <p>Edit <code>src/commands/greet.zig</code> to add native commands.</p>
    <form class="row" @submit.prevent="greet">
      <input v-model="name" aria-label="Name" placeholder="Enter a name" />
      <button type="submit">Greet</button>
    </form>
    <p v-if="message" class="message">{{ message }}</p>
    <p v-if="error" class="error">{{ error }}</p>
  </main>
</template>

<style>
.app {
  font-family: system-ui, -apple-system, sans-serif;
  max-width: 32rem;
  margin: 4rem auto;
  padding: 0 1rem;
  text-align: center;
}

.row {
  display: flex;
  gap: 0.5rem;
  justify-content: center;
}

input {
  padding: 0.5rem;
  flex: 1;
}

button {
  padding: 0.5rem 1rem;
  cursor: pointer;
}

.message {
  color: #2f855a;
}

.error {
  color: #c53030;
}
</style>
