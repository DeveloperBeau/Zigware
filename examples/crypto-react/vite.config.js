import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Pin the dev server to 5173 so it matches `devUrl` in zigware.zon. `strictPort`
// fails fast instead of silently hopping to a port the manifest would not trust.
// `build.outDir` matches `frontendDist` in zigware.zon.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
