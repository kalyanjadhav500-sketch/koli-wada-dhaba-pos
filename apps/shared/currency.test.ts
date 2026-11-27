import assert from "node:assert/strict";
import test from "node:test";
import { formatCurrency } from "./currency";

test("formats INR with two fractional digits and Indian digit grouping", () => {
  assert.equal(formatCurrency(150), "₹150.00");
  assert.equal(formatCurrency("1250"), "₹1,250.00");
  assert.equal(formatCurrency(100000), "₹1,00,000.00");
});

test("rejects non-numeric currency values instead of printing NaN", () => {
  assert.throws(() => formatCurrency("not an amount"), TypeError);
});
