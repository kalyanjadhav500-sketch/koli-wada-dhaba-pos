const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const examplePath = path.join(root, ".env.example");
const envPath = path.join(root, ".env");
const adminPasswordPath = path.join(root, ".pgadmin-password");

if (fs.existsSync(envPath)) {
  console.error(".env already exists. It was left unchanged.");
  process.exit(1);
}
if (!fs.existsSync(examplePath)) {
  console.error(".env.example is missing.");
  process.exit(1);
}

const databasePassword = crypto.randomBytes(32).toString("hex");
const jwtSecret = crypto.randomBytes(48).toString("base64url");
const databaseUrl =
  `postgresql://kwd_app:${encodeURIComponent(databasePassword)}` +
  "@127.0.0.1:55432/koli_wada_dhaba?schema=public";
const template = fs.readFileSync(examplePath, "utf8");
const env = template
  .replace(/^DATABASE_URL=.*$/m, `DATABASE_URL="${databaseUrl}"`)
  .replace(/^POSTGRES_PASSWORD=.*$/m, `POSTGRES_PASSWORD="${databasePassword}"`)
  .replace(/^JWT_SECRET=.*$/m, `JWT_SECRET="${jwtSecret}"`);

if (env === template) {
  console.error(".env.example is missing one or more required environment keys.");
  process.exit(1);
}

if (!fs.existsSync(adminPasswordPath)) {
  fs.writeFileSync(adminPasswordPath, crypto.randomBytes(32).toString("hex"), {
    flag: "wx",
    mode: 0o600,
  });
}
fs.writeFileSync(envPath, env, { flag: "wx", mode: 0o600 });
console.log("Created .env with fresh local database and authentication secrets.");
