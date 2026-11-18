import { PrismaPg } from "@prisma/adapter-pg";
import cors from "cors";
import dotenv from "dotenv";
import { existsSync } from "node:fs";
import path from "node:path";
import helmet from "helmet";
import express from "express";
import { json } from "express";
import { Pool } from "pg";
import { PrismaClient } from "@prisma/client";
import { createAuthentication, createAuthRouter } from "./auth";
import { createBusinessRouter } from "./business";

dotenv.config({ path: "../../.env" });

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  if (process.env.NODE_ENV === "production") {
    throw new Error("DATABASE_URL must be configured before starting the production API.");
  }
  console.warn("DATABASE_URL is not set. API database routes will remain unavailable.");
} else if (process.env.NODE_ENV === "production") {
  let parsedDatabaseUrl: URL;
  try {
    parsedDatabaseUrl = new URL(databaseUrl);
  } catch {
    throw new Error("DATABASE_URL must be a valid PostgreSQL connection URL.");
  }
  if (!["postgres:", "postgresql:"].includes(parsedDatabaseUrl.protocol)) {
    throw new Error("DATABASE_URL must use PostgreSQL.");
  }
  if (["localhost", "127.0.0.1", "::1"].includes(parsedDatabaseUrl.hostname)) {
    throw new Error("Production DATABASE_URL must point to a remote database.");
  }
  if (!["require", "verify-ca", "verify-full"].includes(parsedDatabaseUrl.searchParams.get("sslmode") ?? "")) {
    throw new Error("Production DATABASE_URL must require TLS using sslmode=require or stronger.");
  }
}
if (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < 32) {
  if (process.env.NODE_ENV === "production") {
    throw new Error("JWT_SECRET must be configured with at least 32 characters before starting the production API.");
  }
  console.warn("JWT_SECRET is not configured. Sign-in is disabled until a random 32-character secret is set.");
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.DB_POOL_MAX ?? 10),
  connectionTimeoutMillis: 5_000,
});
const prisma = new PrismaClient({ adapter: new PrismaPg(pool) });
const app = express();
const port = Number(process.env.PORT ?? process.env.API_PORT ?? 4000);
const host = process.env.API_HOST ?? (process.env.NODE_ENV === "production" ? "0.0.0.0" : "127.0.0.1");
const trustProxyHops = Number(process.env.TRUST_PROXY_HOPS ?? "0");
if (!Number.isInteger(trustProxyHops) || trustProxyHops < 0 || trustProxyHops > 1) {
  throw new Error("TRUST_PROXY_HOPS must be 0 or 1.");
}
const allowedOrigins = new Set(
  (process.env.CORS_ORIGINS ??
    "http://localhost:5173,http://127.0.0.1:5173,https://localhost,capacitor://localhost,koliwada://desktop")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean),
);
const authentication = createAuthentication(prisma);

app.disable("x-powered-by");
app.set("trust proxy", trustProxyHops);
app.use(helmet());
app.use(
  cors({
    origin(origin, callback) {
      if (!origin || allowedOrigins.has(origin)) {
        callback(null, true);
        return;
      }
      callback(null, false);
    },
    methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization"],
  }),
);
app.use(json({ limit: "32kb", strict: true }));

app.get("/api/health", async (_request, response) => {
  try {
    await prisma.$queryRaw`SELECT 1`;
    response.json({
      status: "ok",
      database: "connected",
      authenticationConfigured: Boolean(process.env.JWT_SECRET && process.env.JWT_SECRET.length >= 32),
    });
  } catch (error) {
    console.error("Database health check failed:", error);
    response.status(503).json({ status: "error", database: "unavailable" });
  }
});

app.use("/api/auth", createAuthRouter(prisma));
app.use("/api", authentication.authenticate, createBusinessRouter({
  prisma,
  requireOwner: authentication.requireOwner,
}));

app.use("/api", (_request, response) => {
  response.status(404).json({ error: "API endpoint not found." });
});

const webDistPath = path.resolve(__dirname, "../../web/dist");
if (process.env.NODE_ENV === "production" && existsSync(path.join(webDistPath, "index.html"))) {
  app.use(express.static(webDistPath));
  app.use((request, response, next) => {
    if (request.method !== "GET") {
      next();
      return;
    }
    response.sendFile(path.join(webDistPath, "index.html"), (error) => {
      if (error) next(error);
    });
  });
}

app.use((error: unknown, _request: express.Request, response: express.Response, next: express.NextFunction) => {
  if (response.headersSent) {
    next(error);
    return;
  }
  const status =
    typeof error === "object" && error !== null && "status" in error &&
    typeof error.status === "number" && error.status >= 400 && error.status < 600
      ? error.status
      : 500;
  if (status >= 500) console.error("API middleware failed:", error);
  response.status(status).json({
    error: status === 413 ? "Request body is too large." : status === 400 ? "Invalid request body." : "The request could not be completed.",
  });
});

app.listen(port, host, () => {
  console.log(`Koli Wada Dhaba API listening on ${host}:${port}`);
});

async function closeServer(): Promise<void> {
  await prisma.$disconnect();
  await pool.end();
}

process.on("SIGINT", () => {
  void closeServer().finally(() => process.exit(0));
});

process.on("SIGTERM", () => {
  void closeServer().finally(() => process.exit(0));
});
