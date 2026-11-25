const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const workspace = path.resolve(__dirname, "..");
const runtimeRoot = path.join(workspace, "build-runtime");
const apiSource = path.join(workspace, "apps", "api");
const apiRuntime = path.join(runtimeRoot, "api");
const postgresRuntime = path.join(runtimeRoot, "postgresql17");
const toolsRuntime = path.join(runtimeRoot, "installer-tools");
const installerRuntime = path.join(runtimeRoot, "installer");

function copyDirectory(source, destination) {
  if (!fs.existsSync(source)) {
    throw new Error(`Required runtime source is missing: ${source}`);
  }
  fs.rmSync(destination, { recursive: true, force: true });
  fs.cpSync(source, destination, { recursive: true });
}

function copyFile(source, destination) {
  if (!fs.existsSync(source)) {
    throw new Error(`Required runtime file is missing: ${source}`);
  }
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function runNpm(prefix, args) {
  const npmExecPath = process.env.npm_execpath;
  if (!npmExecPath) {
    throw new Error("Run this staging script through npm so the configured npm runtime is used.");
  }
  execFileSync(process.execPath, [npmExecPath, ...args, "--prefix", prefix], {
    cwd: workspace,
    stdio: "inherit",
    windowsHide: true,
  });
}

function generatePrismaClient() {
  const prismaCli = path.join(toolsRuntime, "node_modules", "prisma", "build", "index.js");
  execFileSync(process.execPath, [prismaCli, "generate"], {
    cwd: apiRuntime,
    env: {
      ...process.env,
      DATABASE_URL: "postgresql://kwd_app:unused@127.0.0.1:5433/koli_wada_dhaba",
      DIRECT_URL: "postgresql://kwd_app:unused@127.0.0.1:5433/koli_wada_dhaba",
      NODE_PATH: [
        path.join(toolsRuntime, "node_modules"),
        path.join(apiRuntime, "node_modules"),
      ].join(path.delimiter),
    },
    stdio: "inherit",
    windowsHide: true,
  });
}

function verifyPostgresRuntime() {
  const bin = path.join(postgresRuntime, "bin");
  for (const executable of ["postgres.exe", "initdb.exe", "pg_ctl.exe", "psql.exe", "pg_dump.exe", "pg_restore.exe"]) {
    if (!fs.existsSync(path.join(bin, executable))) {
      throw new Error(`The staged PostgreSQL runtime is missing ${executable}.`);
    }
  }
  const version = execFileSync(path.join(bin, "postgres.exe"), ["--version"], {
    encoding: "utf8",
    windowsHide: true,
  });
  if (!/\b17\./.test(version)) {
    throw new Error(`Expected PostgreSQL 17 in the staging directory; found: ${version.trim()}`);
  }
  for (const license of ["server_license.txt", "commandlinetools_3rd_party_licenses.txt"]) {
    if (!fs.existsSync(path.join(postgresRuntime, license))) {
      throw new Error(`Required PostgreSQL license notice is missing: ${license}`);
    }
  }
  if (fs.existsSync(path.join(postgresRuntime, "data"))) {
    throw new Error("The PostgreSQL staging directory must not contain a database data directory.");
  }
}

try {
  verifyPostgresRuntime();

  copyDirectory(path.join(apiSource, "dist"), path.join(apiRuntime, "dist"));
  copyDirectory(path.join(apiSource, "prisma"), path.join(apiRuntime, "prisma"));
  copyFile(path.join(apiSource, "package.json"), path.join(apiRuntime, "package.json"));
  copyFile(path.join(apiSource, "prisma.config.ts"), path.join(apiRuntime, "prisma.config.ts"));
  copyFile(
    path.join(workspace, "apps", "shared", "menu.json"),
    path.join(runtimeRoot, "shared", "menu.json"),
  );
  copyDirectory(
    path.join(workspace, "apps", "desktop", "installer-tools"),
    toolsRuntime,
  );
  copyDirectory(path.join(workspace, "scripts", "windows"), installerRuntime);

  runNpm(apiRuntime, ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--fund=false"]);
  runNpm(toolsRuntime, ["install", "--no-audit", "--fund=false"]);
  generatePrismaClient();

  const toolsModules = path.join(toolsRuntime, "node_modules");
  const apiModules = path.join(apiRuntime, "node_modules");
  const prismaCli = path.join(toolsModules, "prisma", "build", "index.js");
  const tsxCli = path.join(toolsModules, "tsx", "dist", "cli.mjs");
  for (const required of [prismaCli, tsxCli, path.join(apiModules, "@prisma", "client")]) {
    if (!fs.existsSync(required)) {
      throw new Error(`Installer runtime is incomplete: ${required}`);
    }
  }

  console.log("Staged API production dependencies, Prisma installer tools, seed/migrations, PostgreSQL 17, and license notices.");
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
