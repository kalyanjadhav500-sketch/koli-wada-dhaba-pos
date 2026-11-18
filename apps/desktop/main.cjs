const { app, BrowserWindow, protocol } = require("electron");
const { readFile } = require("node:fs/promises");
const path = require("node:path");

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
    },
  });
  await window.loadURL("koliwada://desktop/index.html");
}

app.whenReady().then(() => createWindow()).catch((error) => {
  console.error("Could not start Koli Wada Dhaba POS:", error);
  app.quit();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
