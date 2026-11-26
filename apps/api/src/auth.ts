import bcrypt from "bcryptjs";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { Request, Response, NextFunction } from "express";
import express from "express";
import rateLimit from "express-rate-limit";
import jwt, { type JwtPayload } from "jsonwebtoken";
import { z } from "zod";
import type { PrismaClient, UserRole } from "@prisma/client";

export type AuthenticatedUser = {
  id: string;
  name: string;
  username: string;
  role: UserRole;
};

declare global {
  namespace Express {
    interface Request {
      authUser?: AuthenticatedUser;
    }
  }
}

const usernameSchema = z
  .string()
  .trim()
  .min(3)
  .max(40)
  .regex(/^[a-zA-Z0-9._-]+$/);
const passwordSchema = z.string().min(12).max(128);
const credentialsSchema = z.object({
  username: usernameSchema,
  password: passwordSchema,
});
const setupSchema = credentialsSchema.extend({
  name: z.string().trim().min(2).max(80),
});
const offlineRecoveryConfirmSchema = z.object({
  username: usernameSchema,
  recoveryKey: z.string().trim().min(32).max(128),
  password: passwordSchema,
});

function getJwtSecret(): string {
  const secret = process.env.JWT_SECRET;
  if (!secret || secret.length < 32) {
    throw new Error("JWT_SECRET must be set to a random secret of at least 32 characters.");
  }
  return secret;
}

function issueToken(user: AuthenticatedUser): string {
  return jwt.sign({ role: user.role }, getJwtSecret(), {
    subject: user.id,
    issuer: "koli-wada-dhaba",
    audience: "koli-wada-pos",
    expiresIn: "8h",
  });
}

function currentUser(user: AuthenticatedUser): AuthenticatedUser {
  return {
    id: user.id,
    name: user.name,
    username: user.username,
    role: user.role,
  };
}

function recoveryKeyHash(recoveryKey: string): string {
  return createHash("sha256").update(recoveryKey.trim().toUpperCase()).digest("hex");
}

export function createAuthRouter(prisma: PrismaClient): express.Router {
  const router = express.Router();
  const authRateLimit = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 12,
    standardHeaders: "draft-8",
    legacyHeaders: false,
  });
  const offlineRecoveryRateLimit = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 5,
    standardHeaders: "draft-8",
    legacyHeaders: false,
  });

  router.get("/setup-status", async (_request, response) => {
    try {
      response.json({ setupRequired: (await prisma.user.count()) === 0 });
    } catch (error) {
      console.error("Owner setup status request failed:", error);
      response.status(503).json({ error: "Database unavailable." });
    }
  });

  router.post("/setup", authRateLimit, async (request, response) => {
    const parsed = setupSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).json({
        error: "Enter a valid owner name, username, and password with at least 12 characters.",
      });
      return;
    }

    try {
      getJwtSecret();
      const setupResult = await prisma.$transaction(async (transaction) => {
        await transaction.$executeRaw`SELECT pg_advisory_xact_lock(744155180921)`;
        if ((await transaction.user.count()) !== 0) return null;

        // The recovery key is shown once to the Owner. Only its SHA-256 hash is stored.
        const recoveryKey = `KWD-${randomBytes(18).toString("hex").toUpperCase()}`;
        const created = await transaction.user.create({
          data: {
            name: parsed.data.name,
            username: parsed.data.username.toLowerCase(),
            passwordHash: await bcrypt.hash(parsed.data.password, 12),
            role: "OWNER",
            recoveryKeyHash: recoveryKeyHash(recoveryKey),
          },
        });
        await transaction.auditLog.create({
          data: {
            userId: created.id,
            action: "OWNER_SETUP",
            entityType: "User",
            entityId: created.id,
          },
        });
        return { owner: created, recoveryKey };
      });

      if (!setupResult) {
        response.status(409).json({ error: "Owner setup has already been completed." });
        return;
      }

      const { owner, recoveryKey } = setupResult;
      const user = currentUser(owner);
      response.status(201).json({
        user,
        token: issueToken(user),
        recoveryKey,
      });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("JWT_SECRET")) {
        response.status(503).json({ error: "Authentication is not configured. Set JWT_SECRET before setup." });
        return;
      }
      console.error("Owner setup failed:", error);
      response.status(503).json({ error: "Owner setup could not be completed." });
    }
  });

  // Offline recovery deliberately has no SMTP, email, internet, or external-service dependency.
  // The one-time key is generated during first-Owner setup and consumed atomically here.
  router.post("/offline-recovery/confirm", offlineRecoveryRateLimit, async (request, response) => {
    const parsed = offlineRecoveryConfirmSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).json({
        error: "Enter the Owner username, recovery key, and a new 12-character password.",
      });
      return;
    }

    try {
      const owner = await prisma.user.findFirst({
        where: {
          username: parsed.data.username.toLowerCase(),
          role: "OWNER",
          active: true,
        },
        select: { id: true, recoveryKeyHash: true },
      });

      const suppliedHash = recoveryKeyHash(parsed.data.recoveryKey);
      const storedRecoveryKeyHash = owner?.recoveryKeyHash;
      const storedHash =
        storedRecoveryKeyHash && /^[a-f0-9]{64}$/i.test(storedRecoveryKeyHash)
          ? storedRecoveryKeyHash
          : createHash("sha256").update(randomBytes(32)).digest("hex");
      const suppliedBuffer = Buffer.from(suppliedHash, "hex");
      const storedBuffer = Buffer.from(storedHash, "hex");
      const keyMatches = timingSafeEqual(suppliedBuffer, storedBuffer);

      if (!owner || !storedRecoveryKeyHash || !keyMatches) {
        response.status(400).json({ error: "The recovery key or username is invalid, or the key has already been used." });
        return;
      }

      await prisma.$transaction(async (transaction) => {
        // Conditional update makes the one-time recovery key single-use even if
        // two recovery requests arrive at nearly the same time.
        const updated = await transaction.user.updateMany({
          where: {
            id: owner.id,
            role: "OWNER",
            active: true,
            recoveryKeyHash: storedRecoveryKeyHash,
          },
          data: {
            passwordHash: await bcrypt.hash(parsed.data.password, 12),
            recoveryKeyHash: null,
          },
        });

        if (updated.count !== 1) {
          throw new Error("The recovery key is invalid, or it has already been used.");
        }

        await transaction.auditLog.create({
          data: {
            userId: owner.id,
            action: "OWNER_OFFLINE_RECOVERY",
            entityType: "User",
            entityId: owner.id,
          },
        });
      });

      response.json({
        message: "Password changed. Sign in with the new password. The one-time recovery key has been used and cannot be used again.",
      });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("The recovery key")) {
        response.status(400).json({ error: error.message });
        return;
      }
      console.error("Offline Owner recovery failed:", error);
      response.status(503).json({ error: "Offline recovery is temporarily unavailable." });
    }
  });

  router.post("/login", authRateLimit, async (request, response) => {
    const parsed = credentialsSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).json({ error: "Enter a valid username and password." });
      return;
    }

    try {
      const username = parsed.data.username.toLowerCase();
      const user = await prisma.user.findUnique({ where: { username } });
      const passwordHash =
        user?.passwordHash ??
        "$2b$12$4r2KaEA2lCkNlBDOVskQU.3ylgKI.z7u51P0Sz8wYuK6y/wXlTo5K";
      const passwordMatches = await bcrypt.compare(parsed.data.password, passwordHash);
      if (!user || !user.active || !passwordMatches) {
        response.status(401).json({ error: "Incorrect username or password." });
        return;
      }

      const authenticated = currentUser(user);
      await prisma.auditLog.create({
        data: {
          userId: user.id,
          action: "LOGIN",
          entityType: "User",
          entityId: user.id,
        },
      });
      response.json({ user: authenticated, token: issueToken(authenticated) });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("JWT_SECRET")) {
        response.status(503).json({ error: "Authentication is not configured. Set JWT_SECRET first." });
        return;
      }
      console.error("Login failed:", error);
      response.status(503).json({ error: "Login is temporarily unavailable." });
    }
  });

  return router;
}

export function createAuthentication(prisma: PrismaClient) {
  async function authenticate(
    request: Request,
    response: Response,
    next: NextFunction,
  ): Promise<void> {
    const authorization = request.header("authorization");
    const token = authorization?.startsWith("Bearer ")
      ? authorization.slice(7)
      : undefined;
    if (!token) {
      response.status(401).json({ error: "Sign in to continue." });
      return;
    }

    try {
      const payload = jwt.verify(token, getJwtSecret(), {
        issuer: "koli-wada-dhaba",
        audience: "koli-wada-pos",
      }) as JwtPayload;
      if (typeof payload.sub !== "string") {
        response.status(401).json({ error: "Your session is invalid. Sign in again." });
        return;
      }
      const user = await prisma.user.findUnique({
        where: { id: payload.sub },
        select: { id: true, name: true, username: true, role: true, active: true },
      });
      if (!user?.active) {
        response.status(401).json({ error: "Your account is inactive. Contact the owner." });
        return;
      }

      request.authUser = currentUser(user);
      next();
    } catch (error) {
      if (error instanceof jwt.JsonWebTokenError || error instanceof jwt.TokenExpiredError) {
        response.status(401).json({ error: "Your session has expired. Sign in again." });
        return;
      }
      if (error instanceof Error && error.message.startsWith("JWT_SECRET")) {
        response.status(503).json({ error: "Authentication is not configured." });
        return;
      }
      console.error("Request authentication failed:", error);
      response.status(503).json({ error: "Authentication is temporarily unavailable." });
    }
  }

  function requireOwner(
    request: Request,
    response: Response,
    next: NextFunction,
  ): void {
    if (request.authUser?.role !== "OWNER") {
      response.status(403).json({ error: "Owner permissions are required." });
      return;
    }
    next();
  }

  return { authenticate, requireOwner };
}
