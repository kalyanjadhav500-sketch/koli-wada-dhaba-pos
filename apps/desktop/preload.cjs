'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const MAX_PRINTER_NAME_LENGTH = 256;

/**
 * Validate the selected Windows printer before forwarding it to the main
 * process. The main process independently validates the trusted frame and
 * verifies that the requested printer is installed.
 */
function validatePrinterName(value) {
  if (value === undefined || value === null || value === '') {
    return '';
  }

  if (
    typeof value !== 'string' ||
    value.length > MAX_PRINTER_NAME_LENGTH ||
    /[\r\n\0]/.test(value)
  ) {
    throw new TypeError('Select a valid installed Windows printer.');
  }

  return value;
}

const desktopApi = Object.freeze({
  /** Return only printer names; do not expose Electron printer objects. */
  listPrinters() {
    return ipcRenderer.invoke('printers:list');
  },

  /** Print a test page to the selected installed Windows printer. */
  testPrinter(printerName = '') {
    return ipcRenderer.invoke('printers:test', validatePrinterName(printerName));
  },

  /** Print the current trusted POS view using the selected Windows printer. */
  printCurrentView(printerName = '') {
    return ipcRenderer.invoke('printing:current-view', validatePrinterName(printerName));
  },
});

// Expose only the small, explicit POS API. Never expose ipcRenderer itself,
// arbitrary channel names, Node.js, filesystem access, or shell execution.
contextBridge.exposeInMainWorld('kwdDesktop', desktopApi);
