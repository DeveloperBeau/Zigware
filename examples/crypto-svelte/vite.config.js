import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// Single fixed-name bundle (app.js) + index.html so the framework's static asset
// table can embed the build with the script external ('self', strict CSP).
// Styles are inline in index.html, so no separate stylesheet is emitted.
export default defineConfig({
  plugins: [svelte()],
  base: "./",
  server: {
    port: 5173,
    strictPort: true,
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    cssCodeSplit: false,
    modulePreload: false,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
        entryFileNames: "app.js",
        assetFileNames: "[name][extname]",
      },
    },
  },
});
