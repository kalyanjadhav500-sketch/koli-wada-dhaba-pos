ALTER TABLE "User"
ADD COLUMN "email" TEXT,
ADD COLUMN "passwordResetCodeHash" TEXT,
ADD COLUMN "passwordResetExpiresAt" TIMESTAMP(3);

CREATE UNIQUE INDEX "User_email_key" ON "User"("email");
