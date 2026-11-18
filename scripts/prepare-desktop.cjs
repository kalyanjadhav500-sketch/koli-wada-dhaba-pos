const fs = require("node:fs");
const path = require("node:path");

const workspace = path.resolve(__dirname, "..");
const source = path.join(workspace, "apps", "web", "dist");
const destination = path.join(workspace, "apps", "desktop", "renderer");

if (!fs.existsSync(path.join(source, "index.html"))) {
  console.error("Web build not found. Run the web production build first.");
  process.exit(1);
}

fs.rmSync(destination, { recursive: true, force: true });
fs.cpSync(source, destination, { recursive: true });
console.log("Prepared the web application for the Windows desktop package.");
