const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const workspace = path.resolve(__dirname, "..");
const runtimeRoot = path.join(workspace, "build-runtime");
const apiSource = path.join(workspace, "apps", "api");
const apiRuntime = path.join(runtimeRoot, "api");
const postgresRuntime = path.join(runtimeRoot, "postgresql17");
const toolsSource = path.join(workspace, "apps", "desktop", "installer-tools");
const toolsRuntime = path.join(runtimeRoot, "installer-tools");
const installerSource = path.join(workspace, "scripts", "windows");
const installerRuntime = path.join(runtimeRoot, "installer");
const sharedSource = path.join(workspace, "apps", "shared", "menu.json");
const sharedRuntime = path.join(runtimeRoot, "shared", "menu.json");
const desktopPackagePath = path.join(workspace, "apps", "desktop", "package.json");
const nsisIncludePath = path.join(workspace, "apps", "desktop", "installer.nsh");

const REQUIRED_WINDOWS_SCRIPTS = [
  "Install-LocalPos.ps1",
  "Backup-LocalPos.ps1",
  "Uninstall-LocalPos.ps1",
];

function fail(message) {
  throw new Error(message);
}

function requireFile(filePath, description = filePath) {
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    fail(`Required ${description} is missing: ${filePath}`);
  }
}

function requireDirectory(directoryPath, description = directoryPath) {
  if (!fs.existsSync(directoryPath) || !fs.statSync(directoryPath).isDirectory()) {
    fail(`Required ${description} is missing: ${directoryPath}`);
  }
}

function ensureWithinRuntimeRoot(destination) {
  const normalizedRoot = path.resolve(runtimeRoot) + path.sep;
  const normalizedDestination = path.resolve(destination);
  if (!normalizedDestination.startsWith(normalizedRoot)) {
    fail(`Refusing to replace a staging destination outside build-runtime: ${destination}`);
  }
}

function copyDirectory(source, destination) {
  requireDirectory(source, "runtime source directory");
  ensureWithinRuntimeRoot(destination);
  fs.rmSync(destination, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.cpSync(source, destination, { recursive: true, errorOnExist: true });
}

function copyFile(source, destination) {
  requireFile(source, "runtime source file");
  ensureWithinRuntimeRoot(destination);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function runNpm(prefix, args) {
  const npmExecPath = process.env.npm_execpath;
  if (!npmExecPath) {
    fail("Run this staging script through npm so the configured npm runtime is used.");
  }
  requireFile(npmExecPath, "npm CLI");
  execFileSync(process.execPath, [npmExecPath, ...args, "--prefix", prefix], {
    cwd: workspace,
    stdio: "inherit",
    windowsHide: true,
  });
}

function runVersionCheck(executablePath, expectedMajor = 17) {
  const output = execFileSync(executablePath, ["--version"], {
    encoding: "utf8",
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
  const majorPattern = new RegExp(`\\b${expectedMajor}\\.`);
  if (!majorPattern.test(output)) {
    fail(`Expected PostgreSQL ${expectedMajor}; found ${output} from ${executablePath}`);
  }
  return output;
}

function verifyPostgresRuntime() {
  const bin = path.join(postgresRuntime, "bin");
  const executables = [
    "postgres.exe",
    "initdb.exe",
    "pg_ctl.exe",
    "psql.exe",
    "pg_dump.exe",
    "pg_restore.exe",
  ];

  requireDirectory(postgresRuntime, "bundled PostgreSQL 17 runtime");
  for (const executable of executables) {
    const executablePath = path.join(bin, executable);
    requireFile(executablePath, `PostgreSQL executable ${executable}`);
    runVersionCheck(executablePath, 17);
  }

  requireDirectory(path.join(postgresRuntime, "lib"), "PostgreSQL runtime libraries");
  requireDirectory(path.join(postgresRuntime, "share"), "PostgreSQL shared files");

  for (const license of ["server_license.txt", "commandlinetools_3rd_party_licenses.txt"]) {
    requireFile(path.join(postgresRuntime, license), `PostgreSQL license notice ${license}`);
  }

  if (fs.existsSync(path.join(postgresRuntime, "data"))) {
    fail("The PostgreSQL staging directory must not contain a database data directory.");
  }
}

function readText(filePath, description) {
  requireFile(filePath, description);
  return fs.readFileSync(filePath, "utf8");
}

function verifyInstallerSourceContract() {
  const installScript = readText(
    path.join(installerSource, "Install-LocalPos.ps1"),
    "production Install-LocalPos.ps1",
  );
  const backupScript = readText(
    path.join(installerSource, "Backup-LocalPos.ps1"),
    "production Backup-LocalPos.ps1",
  );
  const uninstallScript = readText(
    path.join(installerSource, "Uninstall-LocalPos.ps1"),
    "production Uninstall-LocalPos.ps1",
  );

  const installRequirements = [
    ["packaged backup script path", /resources\\installer\\Backup-LocalPos\.ps1/i],
    ["machine-readable pre-migration purpose", /-Purpose['\s,]+['"]PreMigration['"]/i],
    ["machine-readable pre-migration result file", /-ResultFile['\s,]+\$backupResultFile/i],
    ["archive verification through pg_restore", /pg_restore\.exe/i],
    ["dedicated POS service identity", /KoliWadaDhabaPostgreSQL/],
    ["01:30 local backup time", /01:30|FromMinutes\(90\)/],
  ];
  for (const [description, pattern] of installRequirements) {
    if (!pattern.test(installScript)) {
      fail(`Install-LocalPos.ps1 is missing its ${description} contract.`);
    }
  }

  const backupRequirements = [
    ["Purpose parameter", /\$Purpose/],
    ["ResultFile parameter", /\$ResultFile/],
    ["PreMigration purpose", /PreMigration/],
    ["machine-readable success status", /Status\s*=\s*'Success'/],
    ["backup archive path result", /BackupPath\s*=/],
    ["backup archive byte length result", /Length\s*=/],
    ["SHA256 result", /SHA256\s*=/],
    ["installation InstanceId result", /InstanceId\s*=/],
    ["01:30 schedule metadata", /ScheduleLocalTime\s*=\s*'01:30'/],
  ];
  for (const [description, pattern] of backupRequirements) {
    if (!pattern.test(backupScript)) {
      fail(`Backup-LocalPos.ps1 is missing its ${description} contract.`);
    }
  }

  if (/StartWhenAvailable\s*=\s*\$true/i.test(backupScript)) {
    fail("Backup-LocalPos.ps1 must not configure missed-start execution.");
  }

  const uninstallRequirements = [
    ["dedicated POS service identity", /KoliWadaDhabaPostgreSQL/],
    ["daily backup task identity", /Koli Wada Dhaba POS Daily Backup/],
    ["01:30 task schedule validation", /01:30|FromMinutes\(90\)/],
  ];
  for (const [description, pattern] of uninstallRequirements) {
    if (!pattern.test(uninstallScript)) {
      fail(`Uninstall-LocalPos.ps1 is missing its ${description} contract.`);
    }
  }
}

function verifyPackagingContract() {
  const desktopPackage = JSON.parse(readText(desktopPackagePath, "desktop package.json"));
  const nsisInclude = readText(nsisIncludePath, "Electron NSIS installer hooks");
  const extraResources = Array.isArray(desktopPackage.build?.extraResources)
    ? desktopPackage.build.extraResources
    : [];

  const requiredMappings = [
    ["../../build-runtime/api", "api"],
    ["../../build-runtime/postgresql17", "postgresql17"],
    ["../../build-runtime/installer-tools/node_modules", "installer-tools/node_modules"],
    ["../../build-runtime/installer", "installer"],
    ["../../build-runtime/shared", "shared"],
  ];

  for (const [from, to] of requiredMappings) {
    const found = extraResources.some((entry) => entry.from === from && entry.to === to);
    if (!found) {
      fail(`Electron extraResources is missing the required mapping ${from} -> ${to}.`);
    }
  }

  if (!nsisInclude.includes("Install-LocalPos.ps1") ||
      !nsisInclude.includes("Uninstall-LocalPos.ps1")) {
    fail("The NSIS installer hooks do not invoke the packaged POS install and uninstall scripts.");
  }

  if (desktopPackage.build?.nsis?.perMachine !== true ||
      desktopPackage.build?.nsis?.deleteAppDataOnUninstall !== false) {
    fail("The Windows installer must remain per-machine and preserve ProgramData on uninstall.");
  }
}

function generatePrismaClient() {
  const prismaCli = path.join(toolsRuntime, "node_modules", "prisma", "build", "index.js");
  requireFile(prismaCli, "Prisma installer CLI");

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

function verifyStagedRuntime() {
  const stagedScripts = REQUIRED_WINDOWS_SCRIPTS.map((file) => path.join(installerRuntime, file));
  for (const stagedFile of stagedScripts) {
    requireFile(stagedFile, "staged Windows production script");
  }

  const toolsModules = path.join(toolsRuntime, "node_modules");
  const apiModules = path.join(apiRuntime, "node_modules");
  const requiredRuntimePaths = [
    path.join(apiRuntime, "dist", "server.js"),
    path.join(apiRuntime, "prisma", "schema.prisma"),
    path.join(apiRuntime, "prisma", "seed.ts"),
    path.join(apiRuntime, "prisma.config.ts"),
    path.join(toolsModules, "prisma", "build", "index.js"),
    path.join(toolsModules, "tsx", "dist", "cli.mjs"),
    path.join(apiModules, "@prisma", "client"),
    sharedRuntime,
  ];

  for (const requiredPath of requiredRuntimePaths) {
    if (!fs.existsSync(requiredPath)) {
      fail(`The final installer staging layout is missing ${requiredPath}`);
    }
  }

  const migrationsDirectory = path.join(apiRuntime, "prisma", "migrations");
  requireDirectory(migrationsDirectory, "Prisma migration directory");
  if (fs.readdirSync(migrationsDirectory, { withFileTypes: true }).filter((entry) => entry.isDirectory()).length === 0) {
    fail("No committed Prisma migration directories were staged.");
  }

  const expectedBackupPath = path.join(installerRuntime, "Backup-LocalPos.ps1");
  if (!fs.existsSync(expectedBackupPath)) {
    fail("The backup utility will not be available at resources\\installer\\Backup-LocalPos.ps1 after packaging.");
  }
}

try {
  if (process.platform !== "win32") {
    fail("The POS Windows runtime staging step must run on Windows with the bundled Windows PostgreSQL tools.");
  }

  verifyPostgresRuntime();
  verifyInstallerSourceContract();
  verifyPackagingContract();

  copyDirectory(path.join(apiSource, "dist"), path.join(apiRuntime, "dist"));
  copyDirectory(path.join(apiSource, "prisma"), path.join(apiRuntime, "prisma"));
  copyFile(path.join(apiSource, "package.json"), path.join(apiRuntime, "package.json"));
  copyFile(path.join(apiSource, "prisma.config.ts"), path.join(apiRuntime, "prisma.config.ts"));
  copyFile(sharedSource, sharedRuntime);

  copyDirectory(toolsSource, toolsRuntime);

  // Stage only the three scripts required by the production installer. This
  // deliberately excludes deprecated development/bootstrap scripts.
  ensureWithinRuntimeRoot(installerRuntime);
  fs.rmSync(installerRuntime, { recursive: true, force: true });
  fs.mkdirSync(installerRuntime, { recursive: true });
  for (const file of REQUIRED_WINDOWS_SCRIPTS) {
    copyFile(path.join(installerSource, file), path.join(installerRuntime, file));
  }

  runNpm(apiRuntime, ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--fund=false"]);
  runNpm(toolsRuntime, ["install", "--no-audit", "--fund=false"]);
  generatePrismaClient();
  verifyStagedRuntime();

  console.log("Staged and verified the local-only POS runtime.");
  console.log("Included: API, Prisma migrations/seed, installer tools, PostgreSQL 17 and license notices.");
  console.log("Included production scripts: Install-LocalPos.ps1, Backup-LocalPos.ps1, Uninstall-LocalPos.ps1.");
  console.log("Excluded deprecated development PostgreSQL provisioning and generic restore scripts.");
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
