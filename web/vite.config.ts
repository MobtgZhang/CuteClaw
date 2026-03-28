import path from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const apiPort = process.env.VITE_API_PORT ?? "8788";
const agentPort = process.env.VITE_AGENT_PORT ?? "8790";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "src") },
  },
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: `http://127.0.0.1:${apiPort}`,
        changeOrigin: true,
      },
      "/agent": {
        target: `http://127.0.0.1:${agentPort}`,
        changeOrigin: true,
      },
    },
  },
});
