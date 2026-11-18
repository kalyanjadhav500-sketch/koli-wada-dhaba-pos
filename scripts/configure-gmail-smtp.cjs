const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");
const dotenv = require("dotenv");
const nodemailer = require("nodemailer");

const root = path.resolve(__dirname, "..");
const envPath = path.join(root, ".env");
dotenv.config({ path: envPath });

function question(prompt) {
  const interfaceInstance = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => interfaceInstance.question(prompt, (answer) => {
    interfaceInstance.close();
    resolve(answer.trim());
  }));
}

function hiddenQuestion(prompt) {
  return new Promise((resolve, reject) => {
    if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== "function") {
      reject(new Error("Run this command directly in a terminal to enter the app password privately."));
      return;
    }

    const characters = [];
    process.stdout.write(prompt);
    process.stdin.setRawMode(true);
    process.stdin.resume();

    function finish(error) {
      process.stdin.removeListener("data", onData);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdout.write("\n");
      if (error) reject(error);
      else resolve(characters.join(""));
    }

    function onData(input) {
      for (const character of input.toString("utf8")) {
        if (character === "\u0003") {
          finish(new Error("Gmail setup cancelled."));
          return;
        }
        if (character === "\r" || character === "\n") {
          finish();
          return;
        }
        if (character === "\u007f" || character === "\b") {
          characters.pop();
          continue;
        }
        if (character >= " " && character !== "\u007f") {
          characters.push(character);
        }
      }
    }

    process.stdin.on("data", onData);
  });
}

function setEnvValue(contents, key, value) {
  const line = `${key}="${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
  const pattern = new RegExp(`^${key}=.*$`, "m");
  return pattern.test(contents) ? contents.replace(pattern, line) : `${contents.trimEnd()}\n${line}\n`;
}

async function main() {
  if (!process.stdin.isTTY) {
    throw new Error("Run this command directly in a terminal.");
  }
  const email = await question(`Gmail address [${process.env.SMTP_USER ?? ""}]: `) || process.env.SMTP_USER;
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("Enter a valid Gmail address.");
  }
  const first = (await hiddenQuestion("Gmail App Password (input is hidden): ")).replace(/\s/g, "");
  const second = (await hiddenQuestion("Re-enter Gmail App Password: ")).replace(/\s/g, "");
  if (first.length !== 16 || first !== second) {
    throw new Error("App Password entries must match and contain 16 characters.");
  }

  const transport = nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: { user: email, pass: first },
  });
  await transport.verify();

  let contents = fs.existsSync(envPath) ? fs.readFileSync(envPath, "utf8") : "";
  contents = setEnvValue(contents, "SMTP_HOST", "smtp.gmail.com");
  contents = setEnvValue(contents, "SMTP_PORT", "465");
  contents = setEnvValue(contents, "SMTP_SECURE", "true");
  contents = setEnvValue(contents, "SMTP_USER", email);
  contents = setEnvValue(contents, "SMTP_PASS", first);
  contents = setEnvValue(contents, "SMTP_FROM", email);
  fs.writeFileSync(envPath, contents, { encoding: "utf8", mode: 0o600 });
  console.log("Gmail SMTP verified and saved to the ignored local .env file. The app password was not displayed.");
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : "Could not configure Gmail SMTP.");
  process.exitCode = 1;
});
