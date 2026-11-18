import { randomUUID } from "node:crypto";
import express from "express";
import type { Request, Response } from "express";
import { Prisma, type Bill, type PrismaClient } from "@prisma/client";
import bcrypt from "bcryptjs";
import { z } from "zod";

type RouteContext = { prisma: PrismaClient; requireOwner: express.RequestHandler };

class HttpError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

const moneySchema = z
  .string()
  .regex(/^(?:0|[1-9]\d{0,7})(?:\.\d{1,2})?$/, "Enter an amount with at most two decimal places.")
  .refine((value) => Number(value) > 0, "Enter an amount greater than zero.");
const uuidSchema = z.string().uuid();
const addItemSchema = z
  .object({
    menuItemId: z.string().min(1).optional(),
    itemName: z.string().trim().min(1).max(120).optional(),
    size: z.enum(["FULL", "HALF"]).optional(),
    quantity: z.number().int().min(1).max(1000),
    manualPrice: moneySchema.optional(),
  })
  .superRefine((item, context) => {
    if (!item.menuItemId && !item.itemName) {
      context.addIssue({ code: "custom", path: ["menuItemId"], message: "Choose a menu item or enter a name." });
    }
    if (!item.menuItemId && !item.manualPrice) {
      context.addIssue({ code: "custom", path: ["manualPrice"], message: "A price is required for custom items." });
    }
  });
const customerSchema = z.object({
  customerName: z.string().trim().max(120).nullable(),
  customerPhone: z.string().trim().max(30).nullable(),
});
const paymentSchema = z
  .object({
    method: z.enum(["CASH", "UPI", "CARD"]),
    idempotencyKey: uuidSchema,
    upiConfirmed: z.boolean().optional(),
    cardConfirmed: z.boolean().optional(),
    cashReceived: moneySchema.optional(),
  })
  .superRefine((payment, context) => {
    if (payment.method === "UPI" && !payment.upiConfirmed) {
      context.addIssue({
        code: "custom",
        path: ["upiConfirmed"],
        message: "Confirm the UPI payment was received before completing the bill.",
      });
    }
    if (payment.method === "CARD" && !payment.cardConfirmed) {
      context.addIssue({
        code: "custom",
        path: ["cardConfirmed"],
        message: "Confirm the card payment was accepted by the terminal.",
      });
    }
  });
const categorySchema = z.object({
  name: z.string().trim().min(2).max(80),
  sortOrder: z.number().int().min(0).max(1000).default(0),
});
const menuItemSchema = z.object({
  categoryId: z.string().min(1),
  name: z.string().trim().min(1).max(120),
  pricingType: z.enum(["SINGLE", "FULL_HALF", "MANUAL"]),
  fullPrice: moneySchema.nullable(),
  halfPrice: moneySchema.nullable(),
  manualPriceNote: z.string().trim().max(120).nullable().optional(),
});
const settingsSchema = z
  .object({
    restaurantName: z.string().trim().min(2).max(80).optional(),
    subtitle: z.string().trim().max(100).optional(),
    upiId: z.string().trim().max(120).nullable().optional(),
    upiPayeeName: z.string().trim().max(80).nullable().optional(),
    receiptWidthMm: z.union([z.literal(58), z.literal(80)]).optional(),
  })
  .refine((value) => Object.keys(value).length > 0);
const newUserSchema = z.object({
  name: z.string().trim().min(2).max(80),
  username: z.string().trim().min(3).max(40).regex(/^[a-zA-Z0-9._-]+$/),
  password: z.string().min(12).max(128),
  role: z.enum(["OWNER", "CASHIER"]),
});

function parsePrice(value: string): Prisma.Decimal {
  return new Prisma.Decimal(value);
}

function toCents(value: Prisma.Decimal | string | number): number {
  return Math.round(Number(value) * 100);
}

function fromCents(value: number): Prisma.Decimal {
  return new Prisma.Decimal(value).div(100);
}

function formatBillNumber(date: Date): string {
  const dateText = date.toISOString().slice(0, 10).replaceAll("-", "");
  const suffix = randomUUID().replaceAll("-", "").slice(0, 8).toUpperCase();
  return `KWD-${dateText}-${suffix}`;
}

function startOfBusinessDay(date = new Date()): Date {
  const localClock = new Date(date.getTime() + 330 * 60_000);
  localClock.setUTCHours(0, 0, 0, 0);
  return new Date(localClock.getTime() - 330 * 60_000);
}

function requireUser(request: Request) {
  if (!request.authUser) {
    throw new HttpError(401, "Sign in to continue.");
  }
  return request.authUser;
}

function routeParameter(request: Request, name: string): string {
  const value = request.params[name];
  if (typeof value !== "string" || !value) {
    throw new HttpError(400, "Invalid request URL.");
  }
  return value;
}

function validate<T extends z.ZodType>(
  schema: T,
  value: unknown,
  response: Response,
): z.infer<T> | null {
  const result = schema.safeParse(value);
  if (!result.success) {
    response.status(400).json({
      error: "Please check the supplied details.",
      details: result.error.issues.map((issue) => ({
        field: issue.path.join("."),
        message: issue.message,
      })),
    });
    return null;
  }
  return result.data;
}

async function writeAudit(
  transaction: Prisma.TransactionClient,
  request: Request,
  action: string,
  entityType: string,
  entityId: string | null,
  details?: Prisma.InputJsonValue,
): Promise<void> {
  await transaction.auditLog.create({
    data: {
      userId: request.authUser?.id,
      action,
      entityType,
      entityId,
      details,
    },
  });
}

async function lockBill(
  transaction: Prisma.TransactionClient,
  billId: string,
): Promise<Bill> {
  const locked = await transaction.$queryRaw<{ id: string }[]>`
    SELECT "id" FROM "Bill" WHERE "id" = ${billId} FOR UPDATE
  `;
  if (!locked.length) {
    throw new HttpError(404, "Bill not found.");
  }
  const bill = await transaction.bill.findUnique({ where: { id: billId } });
  if (!bill) {
    throw new HttpError(404, "Bill not found.");
  }
  if (bill.status !== "OPEN") {
    throw new HttpError(409, "This bill is closed and cannot be changed.");
  }
  return bill;
}

async function recalculateBill(
  transaction: Prisma.TransactionClient,
  billId: string,
) {
  const lines = await transaction.billItem.findMany({
    where: { billId },
    select: { lineTotal: true },
  });
  const totalCents = lines.reduce(
    (total, line) => total + toCents(line.lineTotal),
    0,
  );
  return transaction.bill.update({
    where: { id: billId },
    data: { subtotal: fromCents(totalCents) },
    include: { items: { orderBy: { createdAt: "asc" } } },
  });
}

async function addItemToBill(
  transaction: Prisma.TransactionClient,
  bill: Bill,
  item: z.infer<typeof addItemSchema>,
  request: Request,
) {
  let menuItemId: string | undefined;
  let itemName: string;
  let unitPrice: Prisma.Decimal;
  let size: string | null;

  if (item.menuItemId) {
    const menuItem = await transaction.menuItem.findUnique({
      where: { id: item.menuItemId },
    });
    if (!menuItem?.active) {
      throw new HttpError(404, "Menu item not found or inactive.");
    }
    menuItemId = menuItem.id;
    itemName = menuItem.name;

    if (menuItem.pricingType === "MANUAL") {
      if (!item.manualPrice) {
        throw new HttpError(400, "Enter the manual price for this menu item.");
      }
      unitPrice = parsePrice(item.manualPrice);
      size = null;
    } else if (menuItem.pricingType === "FULL_HALF") {
      if (!item.size) {
        throw new HttpError(400, "Choose Full or Half for this menu item.");
      }
      const selectedPrice = item.size === "FULL" ? menuItem.fullPrice : menuItem.halfPrice;
      if (selectedPrice === null) {
        if (!item.manualPrice) {
          throw new HttpError(400, `The ${item.size.toLowerCase()} price is not listed. Enter a manual price.`);
        }
        unitPrice = parsePrice(item.manualPrice);
      } else {
        unitPrice = selectedPrice;
      }
      size = item.size;
    } else {
      if (item.size) {
        throw new HttpError(400, "This item is single-priced and does not have a size.");
      }
      if (menuItem.fullPrice === null) {
        throw new HttpError(400, "Enter the menu item price before billing.");
      }
      unitPrice = menuItem.fullPrice;
      size = null;
    }
  } else {
    if (!item.itemName || !item.manualPrice) {
      throw new HttpError(400, "A custom item needs a name and a manually entered price.");
    }
    itemName = item.itemName;
    unitPrice = parsePrice(item.manualPrice);
    size = null;
  }

  const amountCents = toCents(unitPrice) * item.quantity;
  await transaction.billItem.create({
    data: {
      billId: bill.id,
      menuItemId,
      itemName,
      size,
      quantity: item.quantity,
      unitPrice,
      lineTotal: fromCents(amountCents),
    },
  });
  const updatedBill = await recalculateBill(transaction, bill.id);
  await writeAudit(transaction, request, "BILL_ITEM_ADDED", "Bill", bill.id, {
    itemName,
    quantity: item.quantity,
    size,
    amount: fromCents(amountCents).toString(),
  });
  return updatedBill;
}

function publicSettings(settings: {
  restaurantName: string;
  subtitle: string;
  upiId: string | null;
  upiPayeeName: string | null;
  receiptWidthMm: number;
}) {
  return settings;
}

export function createBusinessRouter({ prisma, requireOwner }: RouteContext) {
  const router = express.Router();

  router.get("/me", (request, response) => {
    response.json(requireUser(request));
  });

  router.get("/tables", async (_request, response) => {
    const tables = await prisma.restaurantTable.findMany({
      select: {
        number: true,
        status: true,
        bills: {
          where: { status: "OPEN" },
          select: {
            id: true,
            billNumber: true,
            subtotal: true,
            openedAt: true,
            items: { select: { id: true } },
          },
          orderBy: { openedAt: "desc" },
          take: 1,
        },
      },
      orderBy: { number: "asc" },
    });
    response.json(
      tables.map((table) => ({
        number: table.number,
        status: table.status,
        currentBill: table.bills[0]
          ? {
              id: table.bills[0].id,
              billNumber: table.bills[0].billNumber,
              amount: table.bills[0].subtotal.toString(),
              openedAt: table.bills[0].openedAt,
              itemCount: table.bills[0].items.length,
            }
          : null,
      })),
    );
  });

  router.get("/menu", async (_request, response) => {
    const categories = await prisma.menuCategory.findMany({
      where: { active: true },
      include: { items: { where: { active: true }, orderBy: { name: "asc" } } },
      orderBy: { sortOrder: "asc" },
    });
    response.json(categories);
  });

  router.post("/menu/categories", requireOwner, async (request, response) => {
    const data = validate(categorySchema, request.body, response);
    if (!data) return;
    const category = await prisma.menuCategory.create({ data });
    await prisma.auditLog.create({
      data: {
        userId: request.authUser?.id,
        action: "MENU_CATEGORY_CREATED",
        entityType: "MenuCategory",
        entityId: category.id,
      },
    });
    response.status(201).json(category);
  });

  router.patch("/menu/categories/:categoryId", requireOwner, async (request, response) => {
    const schema = categorySchema.partial().extend({ active: z.boolean().optional() });
    const data = validate(schema, request.body, response);
    if (!data) return;
    const category = await prisma.menuCategory.update({
      where: { id: routeParameter(request, "categoryId") },
      data,
    });
    await prisma.auditLog.create({
      data: {
        userId: request.authUser?.id,
        action: "MENU_CATEGORY_UPDATED",
        entityType: "MenuCategory",
        entityId: category.id,
      },
    });
    response.json(category);
  });

  router.post("/menu/items", requireOwner, async (request, response) => {
    const data = validate(menuItemSchema, request.body, response);
    if (!data) return;
    if (data.pricingType === "SINGLE" && (!data.fullPrice || data.halfPrice !== null)) {
      response.status(400).json({ error: "Single-price items require one price and no half price." });
      return;
    }
    if (data.pricingType === "FULL_HALF" && data.fullPrice === null) {
      response.status(400).json({ error: "Full-price items require a Full price; Half can remain unlisted." });
      return;
    }
    if (data.pricingType === "MANUAL" && (data.fullPrice !== null || data.halfPrice !== null)) {
      response.status(400).json({ error: "Manual-price items cannot have a stored price." });
      return;
    }
    const category = await prisma.menuCategory.findUnique({
      where: { id: data.categoryId },
      select: { id: true, active: true },
    });
    if (!category?.active) {
      response.status(400).json({ error: "Choose an active menu category." });
      return;
    }
    const created = await prisma.menuItem.create({
      data: {
        ...data,
        fullPrice: data.fullPrice === null ? null : parsePrice(data.fullPrice),
        halfPrice: data.halfPrice === null ? null : parsePrice(data.halfPrice),
        manualPriceNote: data.manualPriceNote ?? null,
      },
    });
    await prisma.auditLog.create({
      data: {
        userId: request.authUser?.id,
        action: "MENU_ITEM_CREATED",
        entityType: "MenuItem",
        entityId: created.id,
      },
    });
    response.status(201).json(created);
  });

  router.patch("/menu/items/:itemId", requireOwner, async (request, response) => {
    const data = validate(
      menuItemSchema
        .partial()
        .extend({ active: z.boolean().optional() })
        .refine((value) => Object.keys(value).length > 0),
      request.body,
      response,
    );
    if (!data) return;
    const current = await prisma.menuItem.findUnique({ where: { id: routeParameter(request, "itemId") } });
    if (!current) {
      response.status(404).json({ error: "Menu item not found." });
      return;
    }
    const pricingType = data.pricingType ?? current.pricingType;
    const fullPriceInput = data.fullPrice === undefined ? current.fullPrice?.toString() ?? null : data.fullPrice;
    const halfPriceInput = data.halfPrice === undefined ? current.halfPrice?.toString() ?? null : data.halfPrice;
    if (pricingType === "SINGLE" && (!fullPriceInput || halfPriceInput !== null)) {
      response.status(400).json({ error: "Single-price items require one price and no half price." });
      return;
    }
    if (pricingType === "FULL_HALF" && fullPriceInput === null) {
      response.status(400).json({ error: "Full-price items require a Full price; Half can remain unlisted." });
      return;
    }
    if (pricingType === "MANUAL" && (fullPriceInput !== null || halfPriceInput !== null)) {
      response.status(400).json({ error: "Manual-price items cannot have a stored price." });
      return;
    }
    const updated = await prisma.menuItem.update({
      where: { id: current.id },
      data: {
        categoryId: data.categoryId,
        name: data.name,
        pricingType: data.pricingType,
        fullPrice: data.fullPrice === undefined ? undefined : data.fullPrice === null ? null : parsePrice(data.fullPrice),
        halfPrice: data.halfPrice === undefined ? undefined : data.halfPrice === null ? null : parsePrice(data.halfPrice),
        manualPriceNote: data.manualPriceNote,
        active: data.active,
      },
    });
    await prisma.auditLog.create({
      data: {
        userId: request.authUser?.id,
        action: "MENU_ITEM_UPDATED",
        entityType: "MenuItem",
        entityId: updated.id,
      },
    });
    response.json(updated);
  });

  router.get("/settings", async (_request, response) => {
    const settings = await prisma.restaurantSettings.upsert({
      where: { id: "default" },
      create: { id: "default" },
      update: {},
      select: {
        restaurantName: true,
        subtitle: true,
        upiId: true,
        upiPayeeName: true,
        receiptWidthMm: true,
      },
    });
    response.json(publicSettings(settings));
  });

  router.patch("/settings", requireOwner, async (request, response) => {
    const data = validate(settingsSchema, request.body, response);
    if (!data) return;
    const settings = await prisma.restaurantSettings.upsert({
      where: { id: "default" },
      create: { id: "default", ...data },
      update: data,
      select: {
        restaurantName: true,
        subtitle: true,
        upiId: true,
        upiPayeeName: true,
        receiptWidthMm: true,
      },
    });
    await prisma.auditLog.create({
      data: {
        userId: request.authUser?.id,
        action: "RESTAURANT_SETTINGS_UPDATED",
        entityType: "RestaurantSettings",
      },
    });
    response.json(publicSettings(settings));
  });

  router.get("/dashboard", async (_request, response) => {
    const start = startOfBusinessDay();
    const [availableTables, occupiedTables, paymentGroups, paidBills, recentBills] =
      await Promise.all([
        prisma.restaurantTable.count({ where: { status: "AVAILABLE" } }),
        prisma.restaurantTable.count({ where: { status: "OCCUPIED" } }),
        prisma.payment.groupBy({
          by: ["method"],
          where: { confirmedAt: { gte: start } },
          _sum: { amount: true },
          _count: { _all: true },
        }),
        prisma.bill.count({ where: { status: "PAID", closedAt: { gte: start } } }),
        prisma.bill.findMany({
          where: { openedAt: { gte: start } },
          orderBy: { openedAt: "desc" },
          take: 8,
          select: {
            billNumber: true,
            status: true,
            subtotal: true,
            openedAt: true,
            table: { select: { number: true } },
            payments: { select: { method: true } },
          },
        }),
      ]);
    const collections = { CASH: 0, UPI: 0, CARD: 0 };
    for (const payment of paymentGroups) {
      collections[payment.method] = Number(payment._sum.amount ?? 0);
    }
    response.json({
      businessDate: start.toISOString(),
      totalSales: collections.CASH + collections.UPI + collections.CARD,
      totalOrders: paidBills,
      availableTables,
      occupiedTables,
      collections,
      recentBills: recentBills.map((bill) => ({
        ...bill,
        subtotal: bill.subtotal.toString(),
      })),
    });
  });

  router.get("/reports/daily", async (request, response) => {
    const parsedDate = request.query.date
      ? z.string().regex(/^\d{4}-\d{2}-\d{2}$/).safeParse(request.query.date)
      : { success: true as const, data: new Date().toISOString().slice(0, 10) };
    if (!parsedDate.success) {
      response.status(400).json({ error: "Date must use the YYYY-MM-DD format." });
      return;
    }
    const [year, month, day] = parsedDate.data.split("-").map(Number);
    const start = new Date(Date.UTC(year, month - 1, day) - 330 * 60_000);
    const end = new Date(start.getTime() + 24 * 60 * 60_000);
    const [payments, paidBills, cancelledBills, tableSales] = await Promise.all([
      prisma.payment.groupBy({
        by: ["method"],
        where: { confirmedAt: { gte: start, lt: end } },
        _sum: { amount: true },
        _count: { _all: true },
      }),
      prisma.bill.findMany({
        where: { status: "PAID", closedAt: { gte: start, lt: end } },
        select: { billNumber: true, subtotal: true, closedAt: true },
        orderBy: { closedAt: "desc" },
      }),
      prisma.bill.findMany({
        where: { status: "CANCELLED", closedAt: { gte: start, lt: end } },
        select: { billNumber: true, subtotal: true, closedAt: true },
        orderBy: { closedAt: "desc" },
      }),
      prisma.bill.groupBy({
        by: ["tableId"],
        where: { status: "PAID", closedAt: { gte: start, lt: end } },
        _sum: { subtotal: true },
        _count: { _all: true },
      }),
    ]);
    const tableIds = tableSales.map((sale) => sale.tableId);
    const tables = await prisma.restaurantTable.findMany({
      where: { id: { in: tableIds } },
      select: { id: true, number: true },
    });
    const tableNumbers = new Map(tables.map((table) => [table.id, table.number]));
    response.json({
      businessDate: parsedDate.data,
      payments: payments.map((payment) => ({
        method: payment.method,
        amount: Number(payment._sum.amount ?? 0),
        count: payment._count._all,
      })),
      paidBills: paidBills.map((bill) => ({ ...bill, subtotal: bill.subtotal.toString() })),
      cancelledBills: cancelledBills.map((bill) => ({ ...bill, subtotal: bill.subtotal.toString() })),
      tableSales: tableSales.map((sale) => ({
        tableNumber: tableNumbers.get(sale.tableId) ?? null,
        amount: (sale._sum.subtotal ?? new Prisma.Decimal(0)).toString(),
        orders: sale._count._all,
      })),
    });
  });

  router.get("/bills", async (request, response) => {
    const status = request.query.status
      ? z.enum(["OPEN", "PAID", "CANCELLED"]).safeParse(request.query.status)
      : null;
    if (status && !status.success) {
      response.status(400).json({ error: "Choose a valid bill status." });
      return;
    }
    const bills = await prisma.bill.findMany({
      ...(status?.success ? { where: { status: status.data } } : {}),
      orderBy: { openedAt: "desc" },
      take: 100,
      select: {
        id: true,
        billNumber: true,
        status: true,
        subtotal: true,
        openedAt: true,
        closedAt: true,
        table: { select: { number: true } },
        payments: { select: { method: true, amount: true, confirmedAt: true } },
        items: {
          select: {
            itemName: true,
            size: true,
            quantity: true,
            unitPrice: true,
            lineTotal: true,
          },
          orderBy: { createdAt: "asc" },
        },
      },
    });
    response.json(
      bills.map((bill) => ({
        ...bill,
        subtotal: bill.subtotal.toString(),
        payments: bill.payments.map((payment) => ({
          ...payment,
          amount: payment.amount.toString(),
        })),
        items: bill.items.map((item) => ({
          ...item,
          unitPrice: item.unitPrice.toString(),
          lineTotal: item.lineTotal.toString(),
        })),
      })),
    );
  });

  router.post("/bills", async (request, response) => {
    const data = validate(z.object({ tableNumber: z.number().int().min(1).max(70) }), request.body, response);
    if (!data) return;
    const user = requireUser(request);
    const createdAt = new Date();
    const result = await prisma.$transaction(async (transaction) => {
      const tableLocks = await transaction.$queryRaw<{ id: string }[]>`
        SELECT "id" FROM "RestaurantTable" WHERE "number" = ${data.tableNumber} FOR UPDATE
      `;
      if (!tableLocks.length) {
        throw new HttpError(404, "Table not found. Initialize restaurant tables first.");
      }
      const table = await transaction.restaurantTable.findUnique({
        where: { number: data.tableNumber },
        select: { id: true },
      });
      if (!table) throw new HttpError(404, "Table not found.");
      const existing = await transaction.bill.findFirst({
        where: { tableId: table.id, status: "OPEN" },
        include: { items: true, table: { select: { number: true } } },
      });
      if (existing) return { bill: existing, created: false };

      const bill = await transaction.bill.create({
        data: {
          billNumber: formatBillNumber(createdAt),
          tableId: table.id,
          cashierId: user.id,
        },
        include: { items: true, table: { select: { number: true } } },
      });
      await transaction.restaurantTable.update({
        where: { id: table.id },
        data: { status: "OCCUPIED" },
      });
      await writeAudit(transaction, request, "BILL_OPENED", "Bill", bill.id, {
        billNumber: bill.billNumber,
        tableNumber: data.tableNumber,
      });
      return { bill, created: true };
    });
    response.status(result.created ? 201 : 200).json(result);
  });

  router.get("/bills/:billId", async (request, response) => {
    const bill = await prisma.bill.findUnique({
      where: { id: routeParameter(request, "billId") },
      include: {
        table: { select: { number: true } },
        items: { orderBy: { createdAt: "asc" } },
        payments: { select: { method: true, amount: true, confirmedAt: true } },
      },
    });
    if (!bill) {
      response.status(404).json({ error: "Bill not found." });
      return;
    }
    response.json({
      ...bill,
      subtotal: bill.subtotal.toString(),
      items: bill.items.map((item) => ({
        ...item,
        unitPrice: item.unitPrice.toString(),
        lineTotal: item.lineTotal.toString(),
      })),
      payments: bill.payments.map((payment) => ({
        ...payment,
        amount: payment.amount.toString(),
      })),
    });
  });

  router.post("/bills/:billId/items", async (request, response) => {
    const data = validate(addItemSchema, request.body, response);
    if (!data) return;
    const bill = await prisma.$transaction(async (transaction) => {
      const currentBill = await lockBill(transaction, routeParameter(request, "billId"));
      return addItemToBill(transaction, currentBill, data, request);
    });
    response.status(201).json({
      ...bill,
      subtotal: bill.subtotal.toString(),
      items: bill.items.map((item) => ({
        ...item,
        unitPrice: item.unitPrice.toString(),
        lineTotal: item.lineTotal.toString(),
      })),
    });
  });

  router.patch("/bills/:billId/items/:itemId", async (request, response) => {
    const data = validate(z.object({ quantity: z.number().int().min(1).max(1000) }), request.body, response);
    if (!data) return;
    const bill = await prisma.$transaction(async (transaction) => {
      const billId = routeParameter(request, "billId");
      await lockBill(transaction, billId);
      const item = await transaction.billItem.findFirst({
        where: { id: routeParameter(request, "itemId"), billId },
      });
      if (!item) throw new HttpError(404, "Bill item not found.");
      await transaction.billItem.update({
        where: { id: item.id },
        data: {
          quantity: data.quantity,
          lineTotal: fromCents(toCents(item.unitPrice) * data.quantity),
        },
      });
      const updatedBill = await recalculateBill(transaction, billId);
      await writeAudit(transaction, request, "BILL_ITEM_QUANTITY_CHANGED", "Bill", item.billId, {
        itemId: item.id,
        quantity: data.quantity,
      });
      return updatedBill;
    });
    response.json({ ...bill, subtotal: bill.subtotal.toString() });
  });

  router.delete("/bills/:billId/items/:itemId", async (request, response) => {
    const bill = await prisma.$transaction(async (transaction) => {
      const billId = routeParameter(request, "billId");
      await lockBill(transaction, billId);
      const item = await transaction.billItem.findFirst({
        where: { id: routeParameter(request, "itemId"), billId },
      });
      if (!item) throw new HttpError(404, "Bill item not found.");
      await transaction.billItem.delete({ where: { id: item.id } });
      const updatedBill = await recalculateBill(transaction, billId);
      await writeAudit(transaction, request, "BILL_ITEM_REMOVED", "Bill", item.billId, {
        itemId: item.id,
        itemName: item.itemName,
      });
      return updatedBill;
    });
    response.json({ ...bill, subtotal: bill.subtotal.toString() });
  });

  router.patch("/bills/:billId/customer", async (request, response) => {
    const data = validate(customerSchema, request.body, response);
    if (!data) return;
    const bill = await prisma.$transaction(async (transaction) => {
      const billId = routeParameter(request, "billId");
      await lockBill(transaction, billId);
      const updated = await transaction.bill.update({
        where: { id: billId },
        data: {
          customerName: data.customerName || null,
          customerPhone: data.customerPhone || null,
        },
      });
      await writeAudit(transaction, request, "BILL_CUSTOMER_UPDATED", "Bill", updated.id);
      return updated;
    });
    response.json({ id: bill.id, customerName: bill.customerName, customerPhone: bill.customerPhone });
  });

  router.post("/bills/:billId/payment", async (request, response) => {
    const data = validate(paymentSchema, request.body, response);
    if (!data) return;
    const billId = routeParameter(request, "billId");
    const result = await prisma.$transaction(async (transaction) => {
      const previousPayment = await transaction.payment.findUnique({
        where: { idempotencyKey: data.idempotencyKey },
        include: { bill: true },
      });
      if (previousPayment) {
        if (previousPayment.billId !== billId) {
          throw new HttpError(409, "This payment request ID was already used for another bill.");
        }
        return { bill: previousPayment.bill, payment: previousPayment, replayed: true };
      }

      const billLocks = await transaction.$queryRaw<{ id: string }[]>`
        SELECT "id" FROM "Bill" WHERE "id" = ${billId} FOR UPDATE
      `;
      if (!billLocks.length) throw new HttpError(404, "Bill not found.");
      const bill = await transaction.bill.findUnique({
        where: { id: billId },
        include: { items: { select: { lineTotal: true } } },
      });
      if (!bill) throw new HttpError(404, "Bill not found.");
      if (bill.status !== "OPEN") {
        const replay = await transaction.payment.findUnique({
          where: { idempotencyKey: data.idempotencyKey },
        });
        if (replay?.billId === bill.id) {
          return { bill, payment: replay, replayed: true };
        }
        throw new HttpError(409, "This bill is already closed.");
      }

      const amountCents = bill.items.reduce((sum, item) => sum + toCents(item.lineTotal), 0);
      if (!amountCents) throw new HttpError(400, "Add at least one priced item before payment.");
      if (toCents(bill.subtotal) !== amountCents) {
        throw new HttpError(409, "Bill total changed. Refresh the bill and try again.");
      }
      if (data.method === "CASH") {
        if (!data.cashReceived) throw new HttpError(400, "Enter the cash received before confirming payment.");
        if (toCents(parsePrice(data.cashReceived)) < amountCents) {
          throw new HttpError(400, "Cash received must cover the total bill.");
        }
      }

      const payment = await transaction.payment.create({
        data: {
          idempotencyKey: data.idempotencyKey,
          billId: bill.id,
          method: data.method,
          amount: fromCents(amountCents),
        },
      });
      const paidBill = await transaction.bill.update({
        where: { id: bill.id },
        data: { status: "PAID", closedAt: new Date(), subtotal: fromCents(amountCents) },
      });
      await transaction.restaurantTable.update({
        where: { id: bill.tableId },
        data: { status: "AVAILABLE" },
      });
      await writeAudit(transaction, request, "PAYMENT_CONFIRMED", "Bill", bill.id, {
        method: payment.method,
        amount: payment.amount.toString(),
        cashierConfirmed: true,
      });
      return { bill: paidBill, payment, replayed: false };
    });

    response.status(result.replayed ? 200 : 201).json({
      bill: {
        id: result.bill.id,
        billNumber: result.bill.billNumber,
        status: result.bill.status,
        subtotal: result.bill.subtotal.toString(),
        closedAt: result.bill.closedAt,
      },
      payment: {
        method: result.payment.method,
        amount: result.payment.amount.toString(),
        confirmedAt: result.payment.confirmedAt,
      },
      replayed: result.replayed,
      change:
        data.method === "CASH" && data.cashReceived
          ? fromCents(toCents(parsePrice(data.cashReceived)) - toCents(result.payment.amount)).toString()
          : "0.00",
    });
  });

  router.post("/bills/:billId/cancel", requireOwner, async (request, response) => {
    const data = validate(z.object({ reason: z.string().trim().min(3).max(250) }), request.body, response);
    if (!data) return;
    const bill = await prisma.$transaction(async (transaction) => {
      const billId = routeParameter(request, "billId");
      await lockBill(transaction, billId);
      const cancelled = await transaction.bill.update({
        where: { id: billId },
        data: { status: "CANCELLED", closedAt: new Date() },
      });
      await transaction.restaurantTable.update({
        where: { id: cancelled.tableId },
        data: { status: "AVAILABLE" },
      });
      await writeAudit(transaction, request, "BILL_CANCELLED", "Bill", cancelled.id, {
        reason: data.reason,
      });
      return cancelled;
    });
    response.json({ id: bill.id, status: bill.status, billNumber: bill.billNumber });
  });

  router.post("/users", requireOwner, async (request, response) => {
    const data = validate(newUserSchema, request.body, response);
    if (!data) return;
    const user = await prisma.$transaction(async (transaction) => {
      const created = await transaction.user.create({
        data: {
          name: data.name,
          username: data.username.toLowerCase(),
          passwordHash: await bcrypt.hash(data.password, 12),
          role: data.role,
        },
        select: { id: true, name: true, username: true, role: true, active: true, createdAt: true },
      });
      await writeAudit(transaction, request, "USER_CREATED", "User", created.id, {
        role: created.role,
      });
      return created;
    });
    response.status(201).json(user);
  });

  router.get("/users", requireOwner, async (_request, response) => {
    const users = await prisma.user.findMany({
      select: {
        id: true,
        name: true,
        username: true,
        role: true,
        active: true,
        createdAt: true,
      },
      orderBy: [{ role: "asc" }, { name: "asc" }],
    });
    response.json(users);
  });

  router.patch("/users/:userId", requireOwner, async (request, response) => {
    const data = validate(
      z
        .object({
          name: z.string().trim().min(2).max(80).optional(),
          role: z.enum(["OWNER", "CASHIER"]).optional(),
          active: z.boolean().optional(),
          password: z.string().min(12).max(128).optional(),
        })
        .refine((value) => Object.keys(value).length > 0),
      request.body,
      response,
    );
    if (!data) return;
    const userId = routeParameter(request, "userId");
    if (userId === request.authUser?.id && data.active === false) {
      response.status(400).json({ error: "You cannot deactivate your signed-in owner account." });
      return;
    }
    const user = await prisma.$transaction(async (transaction) => {
      const updated = await transaction.user.update({
        where: { id: userId },
        data: {
          name: data.name,
          role: data.role,
          active: data.active,
          passwordHash: data.password ? await bcrypt.hash(data.password, 12) : undefined,
        },
        select: { id: true, name: true, username: true, role: true, active: true },
      });
      await writeAudit(transaction, request, "USER_UPDATED", "User", updated.id, {
        role: updated.role,
        active: updated.active,
      });
      return updated;
    });
    response.json(user);
  });

  router.use((error: unknown, _request: Request, response: Response, next: express.NextFunction) => {
    if (response.headersSent) {
      next(error);
      return;
    }
    if (error instanceof HttpError) {
      response.status(error.status).json({ error: error.message });
      return;
    }
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "P2002"
    ) {
      response.status(409).json({ error: "That record already exists." });
      return;
    }
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "P2025"
    ) {
      response.status(404).json({ error: "The requested record was not found." });
      return;
    }
    console.error("API request failed:", error);
    response.status(500).json({ error: "The request could not be completed." });
  });

  return router;
}
