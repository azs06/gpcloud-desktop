import { defineConfig } from "vite";
import preact from "@preact/preset-vite";

// Tauri expects a fixed dev port and serves the built files from dist/.
export default defineConfig({
  plugins: [preact()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { target: "es2021", outDir: "dist", emptyOutDir: true },
});
