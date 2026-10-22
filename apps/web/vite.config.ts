import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The design tokens live at the repo root (design/tokens.css), one level above
// this app, so the dev server must be allowed to read it. The production build
// bundles it regardless of location.
export default defineConfig({
  plugins: [react()],
  server: {
    fs: { allow: [".", "../.."] },
  },
});
