import { z } from "zod";

export type Config = {
  NODE_ENV: "development" | "test" | "production";
  HOST: string;
  PORT: number;
  DEFAULT_WORKING_FOLDER: string;
  DEFAULT_SYSTEM_PROMPT: string;
  ENABLE_DEVICE_SIGN: boolean;
  GITHUB_CLIENT_ID?: string;
  AUTH_REQUIRED: boolean;
  AUTO_UPDATE: boolean;
  UPDATE_CHECK_INTERVAL_SECONDS: number;
  APP_VERSION: string;
};

const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  HOST: z.string().default("0.0.0.0"),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  DEFAULT_WORKING_FOLDER: z.string().min(1).default("/workspace"),
  DEFAULT_SYSTEM_PROMPT: z.string().default(""),
  ENABLE_DEVICE_SIGN: z.string().default("true"),
  GITHUB_CLIENT_ID: z.string().optional(),
  AUTH_REQUIRED: z.string().default("true"),
  AUTO_UPDATE: z.string().default("false"),
  UPDATE_CHECK_INTERVAL_SECONDS: z.coerce.number().int().min(60).default(3600),
  APP_VERSION: z.string().default("0.1.0"),
});

function parseBoolean(value: string, defaultValue: boolean): boolean {
  if (value === undefined || value === null || value === "") {
    return defaultValue;
  }

  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

export function createConfig(env: Record<string, string | undefined> = process.env): Config {
  const parsed = envSchema.parse(env);
  const config: Config = {
    NODE_ENV: parsed.NODE_ENV,
    HOST: parsed.HOST,
    PORT: parsed.PORT,
    DEFAULT_WORKING_FOLDER: parsed.DEFAULT_WORKING_FOLDER,
    DEFAULT_SYSTEM_PROMPT: parsed.DEFAULT_SYSTEM_PROMPT,
    ENABLE_DEVICE_SIGN: parseBoolean(parsed.ENABLE_DEVICE_SIGN, true),
    GITHUB_CLIENT_ID: parsed.GITHUB_CLIENT_ID,
    AUTH_REQUIRED: parseBoolean(parsed.AUTH_REQUIRED, true),
    AUTO_UPDATE: parseBoolean(parsed.AUTO_UPDATE, false),
    UPDATE_CHECK_INTERVAL_SECONDS: parsed.UPDATE_CHECK_INTERVAL_SECONDS,
    APP_VERSION: parsed.APP_VERSION,
  };

  if (config.ENABLE_DEVICE_SIGN && !config.GITHUB_CLIENT_ID) {
    throw new Error("GITHUB_CLIENT_ID is required when ENABLE_DEVICE_SIGN=true");
  }

  return config;
}
