const { app, BrowserWindow, protocol, ipcMain } = require("electron");
const { readFile } = require("node:fs/promises");
const path = require("node:path");
const { spawn } = require("node:child_process");
const http = require("node:http");
const { execFile } = require("node:child_process");

protocol.registerSchemesAsPrivileged([
  {
    scheme: "koliwada",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      corsEnabled: true,
    },
  },
]);

const rendererDirectory = path.resolve(__dirname, "renderer");
let apiProcess = null;

function queryPostgresService() {
  return new Promise((resolve, reject) => {
    execFile("sc.exe", ["query", "KoliWadaDhabaPostgreSQL"], (error, stdout, stderr) => {
      if (error) {
        reject(new Error("The dedicated Koli Wada Dhaba PostgreSQL service is not installed."));
        return;
      }
      const state = stdout.match(/STATE\s*:\s*(\d+)/i);
      if (!state) {
        reject(new Error(`Could not read the PostgreSQL service state: ${stderr || stdout}`));
        return;
      }
      resolve(Number(state[1]));
    });
  });
}

async function waitForPostgres() {
  const initialState = await queryPostgresService();
  if (initialState !== 4) {
    await new Promise((resolve, reject) => {
      execFile("sc.exe", ["start", "KoliWadaDhabaPostgreSQL"], (error, stdout, stderr) => {
        if (error && !/1056|already running/i.test(`${error.message} ${stdout} ${stderr}`)) {
          reject(new Error(`The dedicated PostgreSQL service could not be started: ${stderr || error.message}`));
          return;
        }
        resolve();
      });
    });
  }

  for (let attempt = 0; attempt < 90; attempt++) {
    if (await queryPostgresService() === 4) return;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error("The dedicated Koli Wada Dhaba PostgreSQL service did not start in time.");
}

function waitForApi(attempts = 60) {
  return new Promise((resolve, reject) => {
    let remaining = attempts;
    const check = () => {
      if (apiProcess && apiProcess.exitCode !== null) {
        reject(new Error("The local POS API stopped before becoming healthy."));
        return;
      }
      const request = http.get("http://127.0.0.1:4000/api/health", (response) => {
        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => { body += chunk; });
        response.on("end", () => {
          try {
            const health = JSON.parse(body);
            if (response.statusCode === 200 && health.status === "ok" && health.database === "connected") {
              resolve();
              return;
            }
          } catch {
            // Retry until the API returns its expected health response.
          }
          retry();
        });
      });
      request.on("error", retry);
      request.setTimeout(1500, () => request.destroy());
    };
    const retry = () => {
      remaining -= 1;
      if (remaining <= 0) {
        reject(new Error("The local POS API did not become healthy."));
        return;
      }
      setTimeout(check, 500);
    };
    check();
  });
}

async function startLocalApi() {
  if (!app.isPackaged) return;
  await waitForPostgres();
  const apiDirectory = path.resolve(process.resourcesPath, "api");
  const serverScript = path.join(apiDirectory, "dist", "server.js");
  const nodeModulesDirectory = path.join(apiDirectory, "node_modules");
  const dpapiConfig = path.join(
    process.env.ProgramData || "C:\\ProgramData",
    "Koli Wada Dhaba POS",
    "config",
    "database-secrets.dpapi",
  );
  apiProcess = spawn(process.execPath, [serverScript], {
    cwd: apiDirectory,
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: "1",
      LOCAL_POS_APP: "1",
      NODE_PATH: nodeModulesDirectory,
      KWD_DPAPI_CONFIG: dpapiConfig,
      API_HOST: "127.0.0.1",
      PORT: "4000",
    },
    stdio: "ignore",
    windowsHide: true,
  });
  await waitForApi();
}

function stopLocalApi() {
  if (apiProcess && apiProcess.exitCode === null && !apiProcess.killed) {
    apiProcess.kill("SIGTERM");
  }
}
const mimeTypes = {
  ".css": "text/css",
  ".html": "text/html",
  ".ico": "image/x-icon",
  ".js": "text/javascript",
  ".json": "application/json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

async function createWindow() {
  await protocol.handle("koliwada", async (request) => {
    const requestUrl = new URL(request.url);
    const pathname = decodeURIComponent(requestUrl.pathname);
    const requestedPath = path.resolve(rendererDirectory, `.${pathname}`);
    if (
      requestUrl.host !== "desktop" ||
      (requestedPath !== rendererDirectory &&
        !requestedPath.startsWith(`${rendererDirectory}${path.sep}`))
    ) {
      return new Response("Not found", { status: 404 });
    }

    try {
      const contents = await readFile(requestedPath);
      const contentType = mimeTypes[path.extname(requestedPath)] ?? "application/octet-stream";
      return new Response(contents, {
        headers: {
          "Content-Type": contentType,
          "Content-Security-Policy":
            "default-src 'self'; connect-src 'self' https:; img-src 'self' data:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:",
          "X-Content-Type-Options": "nosniff",
        },
      });
    } catch (error) {
      if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
        return new Response("Not found", { status: 404 });
      }
      console.error("Could not load the POS application:", error);
      return new Response("The POS application could not be loaded.", { status: 500 });
    }
  });

  await startLocalApi();
  const window = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 900,
    minHeight: 640,
    backgroundColor: "#f5f7f4",
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      preload: path.join(__dirname, "preload.cjs"),
    },
  });
  ipcMain.handle("printers:list", async () => window.webContents.getPrintersAsync());
  ipcMain.handle("printers:test", async (_event, printerName) => {
    const testHtml = `<!doctype html><html><body style="font-family:monospace;text-align:center">
      <h3>KOLI WADA DHABA</h3><p>Thermal printer test</p><p>${new Date().toLocaleString("en-IN")}</p>
      <p>Thank you.</p></body></html>`;
    const testWindow = new BrowserWindow({
      show: false,
      webPreferences: { sandbox: true },
    });
    await testWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(testHtml)}`);
    const success = await testWindow.webContents.print({
      silent: Boolean(printerName),
      printBackground: false,
      deviceName: printerName || "",
    });
    testWindow.close();
    if (!success) throw new Error("The test print was cancelled or unavailable.");
  });
  await window.loadURL("koliwada://desktop/index.html");
}

app.whenReady().then(() => createWindow()).catch((error) => {
  console.error("Could not start Koli Wada Dhaba POS:", error);
  stopLocalApi();
  app.quit();
});

app.on("window-all-closed", () => {
  stopLocalApi();
  if (process.platform !== "darwin") app.quit();
});
