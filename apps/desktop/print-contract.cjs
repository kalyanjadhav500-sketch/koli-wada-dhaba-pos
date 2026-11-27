'use strict';

const MAX_PRINTER_NAME_LENGTH = 256;

function validatePrinterNameInput(value) {
  if (value === undefined || value === null || value === '') return '';
  if (
    typeof value !== 'string' ||
    value.length > MAX_PRINTER_NAME_LENGTH ||
    /[\r\n\0]/.test(value)
  ) {
    throw new TypeError('Select a valid installed Windows printer.');
  }
  return value;
}

function validateInstalledPrinterName(value, printers) {
  const candidate = validatePrinterNameInput(value);
  if (!candidate) return '';
  if (!Array.isArray(printers) || !printers.some((printer) => printer?.name === candidate)) {
    throw new Error('The selected Windows printer is not currently installed or available.');
  }
  return candidate;
}

function resolvePreferredPrinter(value, printers) {
  const candidate = validatePrinterNameInput(value);
  if (!candidate) return { printerName: '', usedFallback: false };
  const installed = Array.isArray(printers) && printers.some((printer) => printer?.name === candidate);
  return {
    printerName: installed ? candidate : '',
    usedFallback: !installed,
  };
}

function validateReceiptWidthMm(value) {
  if (value !== 58 && value !== 80) {
    throw new TypeError('Choose a receipt width of 58 mm or 80 mm.');
  }
  return value;
}

module.exports = {
  validatePrinterNameInput,
  validateInstalledPrinterName,
  resolvePreferredPrinter,
  validateReceiptWidthMm,
};
