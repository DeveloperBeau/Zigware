import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// The dev server is pinned to 5173 so it matches devUrl in zigware.zon.
// strictPort fails fast instead of drifting to another port the app would never
// load. The production build emits to dist/, which zigware build embeds.
export default defineConfig({
  plugins: [svelte()],
  server: {
    port: 5173,
    strictPort: true,
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
