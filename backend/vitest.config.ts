import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: { bindings: { APP_ACCESS_TOKEN: "test-access-token", OPENAI_API_KEY: "test-openai-key" } },
  })],
  test: { testTimeout: 15_000 },
});
