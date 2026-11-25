const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("kwdDesktop", {
  listPrinters: () => ipcRenderer.invoke("printers:list"),
  testPrinter: (printerName) => ipcRenderer.invoke("printers:test", printerName),
});
