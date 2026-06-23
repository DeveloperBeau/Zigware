import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

// `base: "./"` keeps built asset URLs relative so they resolve under the
// app:// origin in a release build. The dev server is pinned to 5173 to match
// the manifest's serveUrl; `strictPort` fails fast instead of drifting to 5174.
export default defineConfig({
  plugins: [vue()],
  base: "./",
  build: {
    outDir: "dist",
  },
  server: {
    port: 5173,
    strictPort: true,
  },
});
