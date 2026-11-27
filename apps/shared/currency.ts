const inrFormatter = new Intl.NumberFormat("en-IN", {
  style: "currency",
  currency: "INR",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/** Format a numeric POS amount as Indian Rupees for display and exports. */
export function formatCurrency(value: number | string): string {
  const amount = Number(value);
  if (!Number.isFinite(amount)) {
    throw new TypeError("Currency amounts must be finite numbers.");
  }
  return inrFormatter.format(amount);
}
