import bcrypt from "bcryptjs";
import { createHmac, randomInt, timingSafeEqual } from "node:crypto";
import type { Request, Response, NextFunction } from "express";
import express from "express";
import rateLimit from "express-rate-limit";
import jwt, { type JwtPayload } from "jsonwebtoken";
import nodemailer from "nodemailer";
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
  email: z.string().trim().email().max(254),
});
const resetRequestSchema = z.object({
  username: usernameSchema,
  email: z.string().trim().email().max(254),
});
const resetConfirmSchema = resetRequestSchema.extend({
  code: z.string().regex(/^\d{8}$/),
  password: passwordSchema,
});
const resetCodeLifetimeMs = 15 * 60 * 1000;

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

function resetCodeHash(code: string): string {
  return createHmac("sha256", getJwtSecret()).update(code).digest("hex");
}

function resetEmailTransport() {
  const host = process.env.SMTP_HOST;
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASS;
  const from = process.env.SMTP_FROM ?? user;
  const port = Number(process.env.SMTP_PORT ?? 465);
  if (!host || !user || !pass || !from || !Number.isInteger(port) || port < 1 || port > 65535) {
    return null;
  }
  return {
    from,
    transport: nodemailer.createTransport({
      host,
      port,
      secure: process.env.SMTP_SECURE !== "false",
      auth: { user, pass },
    }),
  };
}

export function createAuthRouter(prisma: PrismaClient): express.Router {
  const router = express.Router();
  const authRateLimit = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 12,
    standardHeaders: "draft-8",
    legacyHeaders: false,
  });
  const passwordResetRateLimit = rateLimit({
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
        error: "Enter a valid owner name, username, recovery email, and password with at least 12 characters.",
      });
      return;
    }

    try {
      getJwtSecret();
      const owner = await prisma.$transaction(async (transaction) => {
        await transaction.$executeRaw`SELECT pg_advisory_xact_lock(744155180921)`;
        if ((await transaction.user.count()) !== 0) return null;

        const created = await transaction.user.create({
          data: {
            name: parsed.data.name,
            username: parsed.data.username.toLowerCase(),
            email: parsed.data.email.toLowerCase(),
            passwordHash: await bcrypt.hash(parsed.data.password, 12),
            role: "OWNER",
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
        return created;
      });

      if (!owner) {
        response.status(409).json({ error: "Owner setup has already been completed." });
        return;
      }

      const user = currentUser(owner);
      response.status(201).json({ user, token: issueToken(user) });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("JWT_SECRET")) {
        response.status(503).json({ error: "Authentication is not configured. Set JWT_SECRET before setup." });
        return;
      }
      console.error("Owner setup failed:", error);
      response.status(503).json({ error: "Owner setup could not be completed." });
    }
  });

  router.post("/password-reset/request", passwordResetRateLimit, async (request, response) => {
    const parsed = resetRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).json({ error: "Enter a valid username and email address." });
      return;
    }

    const emailConfig = resetEmailTransport();
    if (!emailConfig) {
      response.status(503).json({ error: "Email password recovery is not configured. Contact the app administrator." });
      return;
    }

    const genericMessage = "If the Owner account matches those details, an 8-digit recovery code has been emailed.";
    try {
      const owner = await prisma.user.findFirst({
        where: {
          username: parsed.data.username.toLowerCase(),
          email: parsed.data.email.toLowerCase(),
          role: "OWNER",
          active: true,
        },
        select: { id: true, email: true },
      });
      if (!owner?.email) {
        response.json({ message: genericMessage });
        return;
      }

      const code = randomInt(0, 100_000_000).toString().padStart(8, "0");
      const codeHash = resetCodeHash(code);
      const expiresAt = new Date(Date.now() + resetCodeLifetimeMs);
      await prisma.user.update({
        where: { id: owner.id },
        data: { passwordResetCodeHash: codeHash, passwordResetExpiresAt: expiresAt },
      });
      try {
        await emailConfig.transport.sendMail({
          from: emailConfig.from,
          to: owner.email,
          subject: "Koli Wada Dhaba POS password reset",
          text: `Your password reset code is ${code}. It expires in 15 minutes. If you did not request this, ignore this email.`,
        });
      } catch (error) {
        await prisma.user.updateMany({
          where: { id: owner.id, passwordResetCodeHash: codeHash },
          data: { passwordResetCodeHash: null, passwordResetExpiresAt: null },
        });
        console.error("Could not send Owner password reset email:", error);
        response.status(503).json({ error: "Could not send the recovery email. Check the email configuration and try again." });
        return;
      }
      response.json({ message: genericMessage });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("JWT_SECRET")) {
        response.status(503).json({ error: "Password recovery is not configured correctly." });
        return;
      }
      console.error("Owner password reset request failed:", error);
      response.status(503).json({ error: "Password recovery is temporarily unavailable." });
    }
  });

  router.post("/password-reset/confirm", passwordResetRateLimit, async (request, response) => {
    const parsed = resetConfirmSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).json({ error: "Enter a valid username, email, 8-digit code, and password with at least 12 characters." });
      return;
    }

    try {
      const owner = await prisma.user.findFirst({
        where: {
          username: parsed.data.username.toLowerCase(),
          email: parsed.data.email.toLowerCase(),
          role: "OWNER",
          active: true,
        },
        select: { id: true, passwordResetCodeHash: true, passwordResetExpiresAt: true },
      });
      const suppliedHash = Buffer.from(resetCodeHash(parsed.data.code), "hex");
      const storedHash =
        owner?.passwordResetCodeHash && /^[a-f0-9]{64}$/i.test(owner.passwordResetCodeHash)
          ? Buffer.from(owner.passwordResetCodeHash, "hex")
          : Buffer.alloc(32);
      const codeMatches = timingSafeEqual(suppliedHash, storedHash);
      if (!owner || !codeMatches || !owner.passwordResetExpiresAt || owner.passwordResetExpiresAt <= new Date()) {
        response.status(400).json({ error: "The recovery code is invalid or expired. Request a new code." });
        return;
      }

      await prisma.$transaction(async (transaction) => {
        const updated = await transaction.user.updateMany({
          where: {
            id: owner.id,
            passwordResetCodeHash: owner.passwordResetCodeHash,
            passwordResetExpiresAt: { gt: new Date() },
          },
          data: {
            passwordHash: await bcrypt.hash(parsed.data.password, 12),
            passwordResetCodeHash: null,
            passwordResetExpiresAt: null,
          },
        });
        if (updated.count !== 1) {
          throw new Error("The recovery code is invalid or expired. Request a new code.");
        }
        await transaction.auditLog.create({
          data: { userId: owner.id, action: "OWNER_PASSWORD_RESET", entityType: "User", entityId: owner.id },
        });
      });
      response.json({ message: "Password changed. Sign in with your new password." });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("JWT_SECRET")) {
        response.status(503).json({ error: "Password recovery is not configured correctly." });
        return;
      }
      if (error instanceof Error && error.message.startsWith("The recovery code")) {
        response.status(400).json({ error: error.message });
        return;
      }
      console.error("Owner password reset failed:", error);
      response.status(503).json({ error: "Password reset is temporarily unavailable." });
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
