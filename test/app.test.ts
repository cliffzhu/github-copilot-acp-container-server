import request from "supertest";
import { describe, expect, test } from "vitest";

import { createApp } from "../src/app";
import { createConfig } from "../src/config";

function buildTestApp() {
  const config = createConfig({
    NODE_ENV: "test",
    HOST: "127.0.0.1",
    PORT: "8080",
    DEFAULT_WORKING_FOLDER: "/tmp",
    DEFAULT_SYSTEM_PROMPT: "test",
    ENABLE_DEVICE_SIGN: "true",
    GITHUB_CLIENT_ID: "test_client_id",
    AUTH_REQUIRED: "true",
    AUTO_UPDATE: "false",
    UPDATE_CHECK_INTERVAL_SECONDS: "3600",
    APP_VERSION: "test-version",
  });

  return createApp(config);
}

describe("app", () => {
  test("health endpoint returns ok", async () => {
    const app = buildTestApp();

    const response = await request(app).get("/health");

    expect(response.status).toBe(200);
    expect(response.body.ok).toBe(true);
  });

  test("version endpoint returns configured version", async () => {
    const app = buildTestApp();

    const response = await request(app).get("/version");

    expect(response.status).toBe(200);
    expect(response.body.version).toBe("test-version");
  });

  test("stream endpoint rejects unauthenticated requests", async () => {
    const app = buildTestApp();

    const response = await request(app).post("/v1/stream").send({ message: "hello world" });

    expect(response.status).toBe(401);
  });
});
