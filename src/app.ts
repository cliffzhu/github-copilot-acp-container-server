import express, { type Request, type Response } from "express";
import { randomUUID } from "node:crypto";
import pinoHttp from "pino-http";
import { z } from "zod";

import { DeviceAuthService } from "./auth/deviceAuthService";
import type { Config } from "./config";
import { createLogger } from "./logger";
import { UpdateManager } from "./updateManager";

const streamBodySchema = z.object({
  message: z.string().min(1),
  sessionId: z.string().optional(),
});

function readBearerToken(value: string | undefined): string | undefined {
  if (!value) {
    return undefined;
  }

  const [scheme, token] = value.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) {
    return undefined;
  }

  return token;
}

function writeSseEvent(res: Response, event: string, data: Record<string, unknown>): void {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(data)}\n\n`);
}

export function createApp(config: Config) {
  const app = express();
  const logger = createLogger();
  const deviceAuthService = new DeviceAuthService({
    clientId: config.GITHUB_CLIENT_ID ?? "",
  });
  const updateManager = new UpdateManager({
    enabled: config.AUTO_UPDATE,
    intervalSeconds: config.UPDATE_CHECK_INTERVAL_SECONDS,
  });

  app.locals.deviceAuthService = deviceAuthService;

  app.use(express.json());
  app.use(
    pinoHttp({
      logger,
      genReqId: () => randomUUID(),
    }),
  );

  app.get("/health", (_req, res) => {
    res.status(200).json({ ok: true, now: new Date().toISOString() });
  });

  app.get("/version", (_req, res) => {
    res.status(200).json({
      version: config.APP_VERSION,
      node: process.version,
      runtime: config.NODE_ENV,
    });
  });

  app.get("/v1/update/status", (_req, res) => {
    res.status(200).json(updateManager.snapshot());
  });

  app.post("/v1/update/check", async (_req, res) => {
    const status = await updateManager.checkForUpdates(config.APP_VERSION);
    res.status(200).json(status);
  });

  app.post("/v1/auth/device/start", async (_req, res) => {
    if (!config.ENABLE_DEVICE_SIGN) {
      res.status(400).json({ error: "Device sign is disabled" });
      return;
    }

    try {
      const started = await deviceAuthService.startDeviceFlow();
      res.status(200).json(started);
    } catch (error) {
      reqLog(res).error({ err: error }, "Failed to start device sign flow");
      res.status(502).json({ error: "Failed to start device sign flow" });
    }
  });

  app.post("/v1/auth/device/poll", async (req, res) => {
    if (!config.ENABLE_DEVICE_SIGN) {
      res.status(400).json({ error: "Device sign is disabled" });
      return;
    }

    const deviceCode = req.body?.deviceCode;
    if (typeof deviceCode !== "string" || deviceCode.length < 8) {
      res.status(400).json({ error: "deviceCode is required" });
      return;
    }

    const result = await deviceAuthService.pollForToken(deviceCode);
    res.status(200).json(result);
  });

  app.post("/v1/stream", (req: Request, res: Response) => {
    const parsedBody = streamBodySchema.safeParse(req.body);
    if (!parsedBody.success) {
      res.status(400).json({ error: parsedBody.error.flatten() });
      return;
    }

    if (config.AUTH_REQUIRED) {
      const token = readBearerToken(req.header("authorization"));
      if (!token || !deviceAuthService.hasAccessToken(token)) {
        res.status(401).json({ error: "Missing or invalid bearer token" });
        return;
      }
    }

    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache, no-transform");
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    const { message, sessionId } = parsedBody.data;
    const words = message.split(/\s+/).filter(Boolean);
    const startedAt = Date.now();

    writeSseEvent(res, "ready", {
      sessionId: sessionId ?? randomUUID(),
      workingFolder: config.DEFAULT_WORKING_FOLDER,
      systemPrompt: config.DEFAULT_SYSTEM_PROMPT,
    });

    const heartbeat = setInterval(() => {
      res.write(": heartbeat\n\n");
    }, 15000);

    let index = 0;
    const streamWords = setInterval(() => {
      if (index >= words.length) {
        clearInterval(streamWords);
        clearInterval(heartbeat);

        writeSseEvent(res, "complete", {
          finishedAt: new Date().toISOString(),
          durationMs: Date.now() - startedAt,
          tokenCount: words.length,
          response: `Echo: ${message}`,
        });

        res.end();
        return;
      }

      writeSseEvent(res, "token", {
        index,
        value: words[index],
      });
      index += 1;
    }, 120);

    const cleanup = () => {
      clearInterval(streamWords);
      clearInterval(heartbeat);
    };

    req.on("close", cleanup);
    res.on("close", cleanup);
  });

  app.use((err: unknown, _req: Request, res: Response, _next: express.NextFunction) => {
    void _next;
    reqLog(res).error({ err }, "Unhandled request error");
    res.status(500).json({ error: "Internal server error" });
  });

  return app;
}

function reqLog(res: Response) {
  return (res as Response & { log: ReturnType<typeof createLogger> }).log;
}
