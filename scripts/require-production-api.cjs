const fs = require("node:fs");
const path = require("node:path");

const envPath = path.resolve(__dirname, "..", ".env");
const envFile = fs.existsSync(envPath) ? fs.readFileSync(envPath, "utf8") : "";
const line = envFile.match(/^\s*VITE_API_URL\s*=\s*["']?([^"'#\r\n]+)["']?\s*$/m);
const apiUrl = process.env.VITE_API_URL ?? line?.[1]?.trim();

if (!apiUrl) {
  console.error("Set VITE_API_URL in .env to the deployed restaurant API's HTTPS URL before packaging.");
  process.exit(1);
}

let parsed;
try {
  parsed = new URL(apiUrl);
} catch {
  console.error("VITE_API_URL must be a valid HTTPS URL.");
  process.exit(1);
}

if (
  parsed.protocol !== "https:" ||
  ["localhost", "127.0.0.1", "::1"].includes(parsed.hostname) ||
  parsed.hostname.endsWith(".trycloudflare.com")
) {
  console.error("Installers require a stable HTTPS API URL; local and temporary tunnel addresses are not supported.");
  process.exit(1);
}

console.log(`Packaging against restaurant API ${parsed.origin}.`);
