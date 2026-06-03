<script>
  let name = $state("world");
  let message = $state("");
  let pending = $state(false);

  async function greet() {
    pending = true;
    try {
      const result = await window.Zigware.invoke("greet", { name });
      message = result.message;
    } catch (err) {
      message = `error: ${err}`;
    } finally {
      pending = false;
    }
  }
</script>

<main>
  <h1>{{name}}</h1>
  <p>A Zigware desktop app with a Svelte frontend.</p>

  <form onsubmit={(e) => { e.preventDefault(); greet(); }}>
    <input aria-label="name" bind:value={name} />
    <button type="submit" disabled={pending}>Greet</button>
  </form>

  {#if message}
    <p class="result">The Zig command answered: {message}</p>
  {/if}
</main>

<style>
  main {
    max-width: 32rem;
    margin: 4rem auto;
    padding: 0 1rem;
    font-family: system-ui, sans-serif;
  }

  form {
    display: flex;
    gap: 0.5rem;
    margin: 1rem 0;
  }

  input {
    flex: 1;
    padding: 0.5rem;
  }

  .result {
    font-weight: 600;
  }
</style>
