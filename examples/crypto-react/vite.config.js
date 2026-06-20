import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Pin the dev server to 5173 (matches devUrl in zigware.zon). The production
// build emits a SINGLE, fixed-name bundle `app.js` (no content hash, no code
// splitting) plus index.html, so the framework's static asset table — which
// serves /index.html and /app.js — can embed the build as-is, with the script
// staying external ('self', strict CSP) rather than inlined. CSS is injected by
// the bundle at runtime as a <style>, covered by style-src 'unsafe-inline'.
export default defineConfig({
  plugins: [react()],
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
