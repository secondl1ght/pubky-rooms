// Runs the hook tests in a DOM (jsdom). The app bundle is built by
// `mix esbuild`, not by anything here.
import {defineConfig} from "vitest/config"

export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["test/**/*.test.js"],
    setupFiles: ["test/support/setup.js"],
    restoreMocks: true
  }
})
