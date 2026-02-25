import { defineConfig } from "vite";
import path from "path";

export default defineConfig({
  server: {
    fs: {
      allow: [
        __dirname,
        path.resolve(__dirname, "../kyzu-core")
      ]
    }
  }
});
