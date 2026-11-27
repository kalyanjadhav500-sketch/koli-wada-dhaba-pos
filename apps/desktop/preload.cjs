'use strict';

const { contextBridge, ipcRenderer } = require('electron');
const { validatePrinterNameInput, validateReceiptWidthMm } = require('./print-contract.cjs');

const desktopApi = Object.freeze({
  /** Return only printer names; do not expose Electron printer objects. */
  listPrinters() {
    return ipcRenderer.invoke('printers:list');
  },

  /** Print a test page to the selected installed Windows printer. */
  testPrinter(printerName = '', receiptWidthMm = 80) {
    return ipcRenderer.invoke(
      'printers:test',
      validatePrinterNameInput(printerName),
      validateReceiptWidthMm(receiptWidthMm),
    );
  },

  /** Print the current trusted POS view using the selected Windows printer. */
  printCurrentView(printerName = '') {
    return ipcRenderer.invoke('printing:current-view', validatePrinterNameInput(printerName));
  },

  /** Owner authorization is checked again by the protected SYSTEM broker. */
  getBackupStatus(ownerToken) {
    if (typeof ownerToken !== 'string') throw new TypeError('Sign in with the Owner account to view backups.');
    return ipcRenderer.invoke('backups:status', ownerToken);
  },

  /** Request a fixed manual backup operation; no command or path is accepted. */
  createManualBackup(ownerToken) {
    if (typeof ownerToken !== 'string') throw new TypeError('Sign in with the Owner account to create a backup.');
    return ipcRenderer.invoke('backups:manual', ownerToken);
  },

  /** Restore only a validated history ID after the renderer's explicit confirmation. */
  restoreBackup(ownerToken, backupId, confirmation) {
    if (typeof ownerToken !== 'string' || typeof backupId !== 'string' || confirmation !== 'RESTORE') {
      throw new TypeError('Choose a protected backup to restore.');
    }
    return ipcRenderer.invoke('backups:restore', ownerToken, backupId, confirmation);
  },
});

// Expose only the small, explicit POS API. Never expose ipcRenderer itself,
// arbitrary channel names, Node.js, filesystem access, or shell execution.
contextBridge.exposeInMainWorld('kwdDesktop', desktopApi);
