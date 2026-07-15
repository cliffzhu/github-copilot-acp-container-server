import pino from "pino";

export function createLogger(level = process.env.LOG_LEVEL ?? "info") {
  return pino({ level });
}
