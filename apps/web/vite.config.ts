import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

const apiPort = process.env.VITE_API_PORT ?? "8788";

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { "@": new URL("./src", import.meta.url).pathname },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: `http://127.0.0.1:${apiPort}`,
        changeOrigin: true,
      },
    },
  },
});
