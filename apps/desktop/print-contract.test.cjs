'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  validatePrinterNameInput,
  validateInstalledPrinterName,
  resolvePreferredPrinter,
  validateReceiptWidthMm,
} = require('./print-contract.cjs');

test('preferred printer routes silently to the exact installed printer', () => {
  const route = resolvePreferredPrinter('Thermal Receipt 58', [
    { name: 'Microsoft Print to PDF' },
    { name: 'Thermal Receipt 58' },
  ]);
  assert.deepEqual(route, { printerName: 'Thermal Receipt 58', usedFallback: false });
  assert.equal(validateInstalledPrinterName('Thermal Receipt 58', [{ name: 'Thermal Receipt 58' }]), 'Thermal Receipt 58');
});

test('missing preferred printer safely uses Windows print selection without resubmitting', () => {
  assert.deepEqual(resolvePreferredPrinter('Thermal Receipt 58', [{ name: 'Office Laser' }]), {
    printerName: '',
    usedFallback: true,
  });
  assert.deepEqual(resolvePreferredPrinter('', [{ name: 'Office Laser' }]), {
    printerName: '',
    usedFallback: false,
  });
});

test('printer input rejects control characters, overlong values, and uninstalled names', () => {
  assert.throws(() => validatePrinterNameInput('Receipt\nPrinter'), /valid installed Windows printer/);
  assert.throws(() => validatePrinterNameInput('p'.repeat(257)), /valid installed Windows printer/);
  assert.throws(() => validateInstalledPrinterName('Unknown', [{ name: 'Receipt' }]), /not currently installed/);
});

test('receipt test width is limited to supported 58 mm and 80 mm layouts', () => {
  assert.equal(validateReceiptWidthMm(58), 58);
  assert.equal(validateReceiptWidthMm(80), 80);
  assert.throws(() => validateReceiptWidthMm(57), /58 mm or 80 mm/);
  assert.throws(() => validateReceiptWidthMm('80'), /58 mm or 80 mm/);
});
