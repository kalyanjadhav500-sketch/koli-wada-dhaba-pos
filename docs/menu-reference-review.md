# Restaurant menu reference review

## Source checked

- Canonical menu source: `apps/shared/menu.json`.
- Supplied visual references: two legacy POS screenshots and four reference videos under `reference-videos/`.

The canonical menu contains 13 categories and 120 items. The sampled legacy video frames show table, payment, KOT, report, and category-button screens. Visible legacy category labels include `Beverage`, `Egg Curries`, `Extra`, `Non Veg Curries`, `Non Veg Rice`, `Non Veg Soups`, `Starter`, `Tandoor`, `Veg`, `Veg Curries`, `Veg Noodles`, `Veg Soups`, `Veg Starter`, and `Sea Food Starter`.

Those labels do not exactly match the canonical categories (`Veg Soups`, `Non - Veg Soups`, `Veg Starters`, `Egg Majedaar`, `Veg Rice`, `Non - Veg Starters`, `Veg Noodles`, `Tandoori Lajawab`, `Seafood Starters`, `Non - Veg Rice`, `Indian - Curries`, `Indian - Noodles`, and `Roti`). The supplied frames are legacy application screens rather than a clearly legible menu card and price sheet. No menu names, categories, or prices were changed based on an uncertain visual match.

## Release treatment

`apps/shared/menu.json` remains the implementation source and retains the existing 13/120 restaurant dataset. The legacy screen/category difference is recorded for Owner review during Windows acceptance. Confirm any requested category renames or price changes against an approved current menu card before changing the canonical data.
