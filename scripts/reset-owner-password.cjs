const bcrypt = require("bcryptjs");
const dotenv = require("dotenv");
const path = require("node:path");
const { Client } = require("pg");

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function readHidden(prompt) {
  return new Promise((resolve, reject) => {
    if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== "function") {
      reject(new Error("Run this command directly in a terminal to enter the password privately."));
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
          finish(new Error("Password reset cancelled."));
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

async function main() {
  if (!process.env.DATABASE_URL) {
    throw new Error("DATABASE_URL is not configured in the project .env file.");
  }

  const password = await readHidden("New owner password (12-128 characters): ");
  if (password.length < 12 || password.length > 128) {
    throw new Error("Password must be between 12 and 128 characters.");
  }
  const confirmation = await readHidden("Re-enter new owner password: ");
  if (password !== confirmation) {
    throw new Error("Passwords do not match. No changes were made.");
  }

  const client = new Client({ connectionString: process.env.DATABASE_URL });
  try {
    await client.connect();
    await client.query("BEGIN");
    const owners = await client.query(
      'SELECT id FROM "User" WHERE role = $1 AND active = true FOR UPDATE',
      ["OWNER"],
    );
    if (owners.rowCount !== 1) {
      throw new Error(`Expected exactly one active Owner account; found ${owners.rowCount ?? 0}. No changes were made.`);
    }

    const passwordHash = await bcrypt.hash(password, 12);
    await client.query(
      'UPDATE "User" SET "passwordHash" = $1, "updatedAt" = NOW() WHERE id = $2',
      [passwordHash, owners.rows[0].id],
    );
    await client.query("COMMIT");
    console.log("Owner password reset successfully. Sign in with the existing Owner username and your new password.");
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    await client.end();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : "Owner password reset failed.");
  process.exitCode = 1;
});
