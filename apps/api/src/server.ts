import { PrismaPg } from "@prisma/adapter-pg";
import cors from "cors";
import dotenv from "dotenv";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import helmet from "helmet";
import express from "express";
import { json } from "express";
import { Pool } from "pg";
import { PrismaClient } from "@prisma/client";
import { createAuthentication, createAuthRouter } from "./auth";
import { createBusinessRouter } from "./business";

const isLocalPosApp = process.env.LOCAL_POS_APP === "1";

function getProgramDataRoot(): string {
  const programData = process.env.ProgramData;
  if (!programData) {
    throw new Error("Windows ProgramData is not available; the local POS configuration cannot be located.");
  }
  return path.win32.resolve(programData, "Koli Wada Dhaba POS");
}

function getExpectedLocalConfigPath(): string {
  return path.win32.resolve(getProgramDataRoot(), "config", "database-secrets.dpapi");
}

function normalizeWindowsPath(value: string): string {
  return path.win32.normalize(value).replace(/[\\/]+$/, "").toLowerCase();
}

function decodeLocalProtectedConfig(): Record<string, unknown> {
  if (process.platform !== "win32") {
    throw new Error("The packaged local POS configuration can only be opened on Windows.");
  }

  const configuredPath = process.env.KWD_DPAPI_CONFIG;
  if (!configuredPath) {
    throw new Error("The protected local database configuration path is missing.");
  }

  const expectedPath = getExpectedLocalConfigPath();
  const actualPath = path.win32.resolve(configuredPath);
  if (actualPath.toLowerCase() !== expectedPath.toLowerCase()) {
    throw new Error("The protected local database configuration path is not the approved ProgramData location.");
  }
  if (!existsSync(expectedPath)) {
    throw new Error("The protected local database configuration is missing.");
  }

  // Pass the path through the process environment instead of interpolating it
  // into PowerShell source. This avoids command injection through a path value.
  const powershellSource = [
    "$ErrorActionPreference = 'Stop'",
    "$configPath = $env:KWD_DPAPI_CONFIG",
    "if (-not $configPath -or -not [IO.File]::Exists($configPath)) { throw 'Configuration file not found.' }",
    "Add-Type -AssemblyName System.Security",
    "$protectedBytes = [IO.File]::ReadAllBytes($configPath)",
    "try {",
    "  $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect($protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)",
    "  try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::Out.Write([Text.Encoding]::UTF8.GetString($plainBytes)) }",
    "  finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }",
    "}",
    "finally { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }",
  ].join("\n");
  const encodedCommand = Buffer.from(powershellSource, "utf16le").toString("base64");

  let decryptedText: string;
  try {
    decryptedText = execFileSync(
      "powershell.exe",
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        encodedCommand,
      ],
      {
        encoding: "utf8",
        windowsHide: true,
        timeout: 15_000,
        maxBuffer: 64 * 1024,
        env: {
          ...process.env,
          KWD_DPAPI_CONFIG: expectedPath,
        },
      },
    );
  } catch {
    throw new Error("Windows could not decrypt the protected local POS configuration. Check its machine identity and file permissions.");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(decryptedText);
  } catch {
    throw new Error("The protected local POS configuration is not valid JSON.");
  } finally {
    decryptedText = "";
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("The protected local POS configuration has an invalid structure.");
  }

  return parsed as Record<string, unknown>;
}

function loadLocalProtectedConfig(): void {
  const config = decodeLocalProtectedConfig();
  const instanceId = config.InstanceId;
  const databaseUrlValue = config.DATABASE_URL;
  const appPassword = config.AppPassword;
  const jwtSecret = config.JWT_SECRET;

  if (typeof instanceId !== "string" || !/^[a-f0-9]{32}$/i.test(instanceId)) {
    throw new Error("The protected local POS installation identity is missing or invalid.");
  }
  if (typeof databaseUrlValue !== "string" || typeof appPassword !== "string" || !/^[a-f0-9]{64}$/i.test(appPassword)) {
    throw new Error("The protected local POS database credentials are missing or invalid.");
  }
  if (typeof jwtSecret !== "string" || jwtSecret.length < 32) {
    throw new Error("The protected local POS authentication secret is missing or invalid.");
  }

  let databaseUrl: URL;
  try {
    databaseUrl = new URL(databaseUrlValue);
  } catch {
    throw new Error("The protected local POS database URL is invalid.");
  }

  const databaseName = databaseUrl.pathname.replace(/^\//, "");
  let decodedPassword: string;
  let decodedUsername: string;
  try {
    decodedPassword = decodeURIComponent(databaseUrl.password);
    decodedUsername = decodeURIComponent(databaseUrl.username);
  } catch {
    throw new Error("The protected local POS database credentials are not correctly URL-encoded.");
  }
  if (
    !["postgres:", "postgresql:"].includes(databaseUrl.protocol) ||
    databaseUrl.hostname !== "127.0.0.1" ||
    databaseUrl.port !== "5433" ||
    databaseName !== "koli_wada_dhaba" ||
    decodedUsername !== "kwd_app" ||
    decodedPassword !== appPassword
  ) {
    throw new Error("The protected database URL does not identify the dedicated local Koli Wada Dhaba database.");
  }

  const markerPath = path.win32.resolve(getProgramDataRoot(), "config", "installation.json");
  if (!existsSync(markerPath)) {
    throw new Error("The local POS installation marker is missing.");
  }
  let marker: Record<string, unknown>;
  try {
    marker = JSON.parse(readFileSync(markerPath, "utf8").replace(/^\uFEFF/, "")) as Record<string, unknown>;
  } catch {
    throw new Error("The local POS installation marker is invalid.");
  }
  const expectedDataDirectory = path.win32.resolve(getProgramDataRoot(), "Data");
  if (
    marker.ServiceName !== "KoliWadaDhabaPostgreSQL" ||
    marker.PostgreSQLMajor !== "17" ||
    marker.Port !== 5433 ||
    typeof marker.DataDirectory !== "string" ||
    normalizeWindowsPath(marker.DataDirectory) !== normalizeWindowsPath(expectedDataDirectory) ||
    marker.InstanceId !== instanceId
  ) {
    throw new Error("The protected local POS configuration does not match the machine-wide installation marker.");
  }

  // A packaged POS must never inherit a developer .env, cloud URL, SMTP
  // credentials, proxy setting, or caller-supplied database connection.
  process.env.DATABASE_URL = databaseUrlValue;
  process.env.DIRECT_URL = databaseUrlValue;
  process.env.JWT_SECRET = jwtSecret;
  process.env.NODE_ENV = "production";
  process.env.API_HOST = "127.0.0.1";
  process.env.PORT = "4000";
  process.env.DB_POOL_MAX = "5";
  process.env.TRUST_PROXY_HOPS = "0";
  process.env.CORS_ORIGINS = "koliwada://desktop";

  for (const name of [
    "SMTP_HOST",
    "SMTP_PORT",
    "SMTP_USER",
    "SMTP_PASS",
    "SMTP_FROM",
    "SMTP_SECURE",
    "SMTP_CONNECTION_URL",
  ]) {
    delete process.env[name];
  }
}

if (isLocalPosApp) {
  loadLocalProtectedConfig();
} else {
  // The supported customer installation is local-only. Keep dotenv available
  // for development, but do not start a remote/cloud production server.
  dotenv.config({ path: "../../.env" });
  if (process.env.NODE_ENV === "production") {
    throw new Error("This POS build supports local Windows production only; remote database hosting is disabled.");
  }
}

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  if (process.env.NODE_ENV === "production") {
    throw new Error("DATABASE_URL must be configured before starting the production API.");
  }
  console.warn("DATABASE_URL is not set. API database routes will remain unavailable.");
} else {
  let parsedDatabaseUrl: URL;
  try {
    parsedDatabaseUrl = new URL(databaseUrl);
  } catch {
    throw new Error("DATABASE_URL must be a valid PostgreSQL connection URL.");
  }
  if (!["postgres:", "postgresql:"].includes(parsedDatabaseUrl.protocol)) {
    throw new Error("DATABASE_URL must use PostgreSQL.");
  }
  if (!isLocalPosApp && !["localhost", "127.0.0.1", "::1"].includes(parsedDatabaseUrl.hostname)) {
    throw new Error("This project is configured for local-only operation; DATABASE_URL must use a loopback PostgreSQL host.");
  }
  if (isLocalPosApp && (
    parsedDatabaseUrl.hostname !== "127.0.0.1" ||
    parsedDatabaseUrl.port !== "5433" ||
    parsedDatabaseUrl.pathname !== "/koli_wada_dhaba"
  )) {
    throw new Error("The packaged POS API may connect only to its dedicated local PostgreSQL database.");
  }
}

if (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < 32) {
  if (process.env.NODE_ENV === "production") {
    throw new Error("JWT_SECRET must be configured with at least 32 characters before starting the production API.");
  }
  console.warn("JWT_SECRET is not configured. Sign-in is disabled until a random 32-character secret is set.");
}

const pool = new Pool({
  connectionString: databaseUrl,
  max: Number(process.env.DB_POOL_MAX ?? 10),
  connectionTimeoutMillis: 5_000,
});
const prisma = new PrismaClient({ adapter: new PrismaPg(pool) });
const app = express();
const port = isLocalPosApp ? 4000 : Number(process.env.PORT ?? process.env.API_PORT ?? 4000);
const host = isLocalPosApp ? "127.0.0.1" : (process.env.API_HOST ?? "127.0.0.1");
const trustProxyHops = isLocalPosApp ? 0 : Number(process.env.TRUST_PROXY_HOPS ?? "0");

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("The API port configuration is invalid.");
}
if (!Number.isInteger(trustProxyHops) || trustProxyHops < 0 || trustProxyHops > 1) {
  throw new Error("TRUST_PROXY_HOPS must be 0 or 1.");
}

const allowedOrigins = new Set(
  isLocalPosApp
    ? ["koliwada://desktop"]
    : (process.env.CORS_ORIGINS ??
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

async function verifyDedicatedLocalDatabase(): Promise<void> {
  const result = await pool.query<{
    database_name: string;
    database_role: string;
    data_directory: string;
    listen_addresses: string;
    server_port: string;
  }>(
    "SELECT current_database() AS database_name, current_user AS database_role, " +
      "current_setting('data_directory') AS data_directory, " +
      "current_setting('listen_addresses') AS listen_addresses, " +
      "current_setting('port') AS server_port",
  );
  const server = result.rows[0];
  const expectedDataDirectory = path.win32.resolve(getProgramDataRoot(), "Data");
  if (
    !server ||
    server.database_name !== "koli_wada_dhaba" ||
    server.database_role !== "kwd_app" ||
    server.server_port !== "5433" ||
    server.listen_addresses !== "127.0.0.1" ||
    normalizeWindowsPath(server.data_directory) !== normalizeWindowsPath(expectedDataDirectory)
  ) {
    throw new Error("The connected PostgreSQL instance is not the verified local Koli Wada Dhaba database.");
  }
}

app.get("/api/health", async (_request, response) => {
  try {
    if (isLocalPosApp) {
      await verifyDedicatedLocalDatabase();
    } else {
      await prisma.$queryRaw`SELECT 1`;
    }
    response.json({
      status: "ok",
      database: "connected",
      authenticationConfigured: Boolean(process.env.JWT_SECRET && process.env.JWT_SECRET.length >= 32),
      localOnly: isLocalPosApp,
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

// The desktop package serves its own renderer through the koliwada:// protocol.
// The Express web fallback is retained only for non-production development use.
if (!isLocalPosApp) {
  const webDistPath = path.resolve(__dirname, "../../web/dist");
  if (existsSync(path.join(webDistPath, "index.html"))) {
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

const httpServer = app.listen(port, host, () => {
  console.log(`Koli Wada Dhaba API listening on ${host}:${port}${isLocalPosApp ? " (local-only)" : ""}`);
});

async function closeServer(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    httpServer.close((error) => {
      if (error) reject(error);
      else resolve();
    });
  });
  await prisma.$disconnect();
  await pool.end();
}

let shutdownStarted = false;
async function shutdown(signal: string): Promise<void> {
  if (shutdownStarted) return;
  shutdownStarted = true;
  console.log(`Closing Koli Wada Dhaba API (${signal}).`);
  try {
    await closeServer();
    process.exit(0);
  } catch (error) {
    console.error("API shutdown failed.", error);
    process.exit(1);
  }
}

httpServer.on("error", (error: NodeJS.ErrnoException) => {
  console.error(`The Koli Wada Dhaba API could not listen on ${host}:${port}.`, error.code ?? "unknown error");
  void prisma.$disconnect().finally(() => pool.end()).finally(() => process.exit(1));
});

process.on("SIGINT", () => {
  void shutdown("SIGINT");
});

process.on("SIGTERM", () => {
  void shutdown("SIGTERM");
});
