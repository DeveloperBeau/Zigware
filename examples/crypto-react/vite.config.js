import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Pin the dev server to 5173 (matches serveUrl in zigware.zon). The production
// build emits a SINGLE, fixed-name bundle `app.js` (no content hash, no code
// splitting) plus `style.css` and index.html. The framework's static asset
// table serves /index.html, /app.js, and /style.css, keeping every resource
// external ('self', strict CSP) rather than inlined.
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
