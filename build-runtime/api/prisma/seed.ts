import { PrismaPg } from "@prisma/adapter-pg";
import { PrismaClient } from "@prisma/client";
import dotenv from "dotenv";
import { Pool } from "pg";
import menu from "../../shared/menu.json";

dotenv.config({ path: "../../.env" });

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const prisma = new PrismaClient({ adapter: new PrismaPg(pool) });

function getPricingType(value: string): "SINGLE" | "FULL_HALF" | "MANUAL" {
  if (value === "SINGLE" || value === "FULL_HALF" || value === "MANUAL") {
    return value;
  }
  throw new Error(`Unknown menu pricing type "${value}".`);
}

async function main(): Promise<void> {
  await prisma.$transaction(
    Array.from({ length: 70 }, (_, index) =>
      prisma.restaurantTable.upsert({
        where: { number: index + 1 },
        update: {},
        create: { number: index + 1 },
      }),
    ),
  );
  for (const categoryData of menu) {
    const category = await prisma.menuCategory.upsert({
      where: { name: categoryData.name },
      update: { sortOrder: categoryData.sortOrder },
      create: {
        name: categoryData.name,
        sortOrder: categoryData.sortOrder,
      },
    });

    await prisma.$transaction(
      categoryData.items.map((item) => {
        const pricingType = getPricingType(item.pricingType);
        const manualPriceNote =
          "manualPriceNote" in item ? item.manualPriceNote : undefined;
        return prisma.menuItem.upsert({
          where: {
            categoryId_name: { categoryId: category.id, name: item.name },
          },
          update: manualPriceNote ? { manualPriceNote } : {},
          create: {
            categoryId: category.id,
            name: item.name,
            pricingType,
            fullPrice: item.fullPrice,
            halfPrice: item.halfPrice,
            manualPriceNote: manualPriceNote ?? null,
          },
        });
      }),
    );
  }
  console.log(`Ensured 70 restaurant tables and ${menu.length} menu categories exist.`);
}

main()
  .catch((error: unknown) => {
    console.error("Database seed failed:", error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
    await pool.end();
  });
