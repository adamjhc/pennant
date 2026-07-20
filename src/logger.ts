import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type LogLevel = "debug" | "info" | "warn" | "error";

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

export interface Logger {
  debug(message: string, fields?: Record<string, unknown>): void;
  info(message: string, fields?: Record<string, unknown>): void;
  warn(message: string, fields?: Record<string, unknown>): void;
  error(message: string, fields?: Record<string, unknown>): void;
}

export interface LoggerOptions {
  level?: LogLevel;
  logFile?: string;
  json?: boolean;
}

function redact(value: unknown): unknown {
  if (typeof value === "string") {
    if (
      value.startsWith("xoxp-") ||
      value.startsWith("xoxb-") ||
      value.startsWith("xoxe-") ||
      /^[A-Za-z0-9._-]{20,}$/.test(value)
    ) {
      return "[redacted]";
    }
  }
  if (Array.isArray(value)) {
    return value.map(redact);
  }
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, nested] of Object.entries(value)) {
      const lower = key.toLowerCase();
      if (
        lower.includes("token") ||
        lower.includes("secret") ||
        lower.includes("password") ||
        lower === "authorization"
      ) {
        out[key] = "[redacted]";
      } else if (
        lower === "subject" ||
        lower === "title" ||
        lower === "body" ||
        lower === "bodypreview"
      ) {
        out[key] = "[omitted]";
      } else {
        out[key] = redact(nested);
      }
    }
    return out;
  }
  return value;
}

export function createLogger(options: LoggerOptions = {}): Logger {
  const minLevel = LEVEL_ORDER[options.level ?? "info"];
  const json = options.json ?? true;

  const write = (level: LogLevel, message: string, fields?: Record<string, unknown>) => {
    if (LEVEL_ORDER[level] < minLevel) {
      return;
    }

    const entry = {
      ts: new Date().toISOString(),
      level,
      message,
      ...(fields ? (redact(fields) as Record<string, unknown>) : {}),
    };

    const line = json
      ? JSON.stringify(entry)
      : `${entry.ts} ${level.toUpperCase()} ${message}${
          fields ? ` ${JSON.stringify(redact(fields))}` : ""
        }`;

    const stream = level === "error" || level === "warn" ? process.stderr : process.stdout;
    stream.write(`${line}\n`);

    if (options.logFile) {
      mkdirSync(dirname(options.logFile), { recursive: true });
      appendFileSync(options.logFile, `${line}\n`, "utf8");
    }
  };

  return {
    debug: (message, fields) => write("debug", message, fields),
    info: (message, fields) => write("info", message, fields),
    warn: (message, fields) => write("warn", message, fields),
    error: (message, fields) => write("error", message, fields),
  };
}
