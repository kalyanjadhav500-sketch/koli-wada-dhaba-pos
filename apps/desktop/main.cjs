'use strict';

const {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  protocol,
  session,
} = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const { spawn, execFile, execFileSync } = require('node:child_process');

const SERVICE_NAME = 'KoliWadaDhabaPostgreSQL';
const SERVICE_ACCOUNT = 'NT AUTHORITY\\NetworkService';
const DATABASE_NAME = 'koli_wada_dhaba';
const DATABASE_ROLE = 'kwd_app';
const DATABASE_PORT = 5433;
const API_HOST = '127.0.0.1';
const API_PORT = 4000;
const API_BASE_URL = `http://${API_HOST}:${API_PORT}`;
const CUSTOM_SCHEME = 'koliwada';
const CUSTOM_HOST = 'desktop';
const HEALTH_PATH = '/api/health';
const MAX_LOG_BYTES = 5 * 1024 * 1024;

protocol.registerSchemesAsPrivileged([
  {
    scheme: CUSTOM_SCHEME,
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      corsEnabled: true,
      allowServiceWorkers: false,
      bypassCSP: false,
    },
  },
]);

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) {
  app.quit();
} else {
  app.setAppUserModelId('in.koliwadadhaba.pos');
}

const rendererDirectory = path.resolve(__dirname, 'renderer');
let mainWindow = null;
let apiProcess = null;
let apiStdoutFd = null;
let apiStderrFd = null;
let apiExit = null;
let shutdownStarted = false;
let protocolHandlerRegistered = false;

function getProgramDataRoot() {
  const programData = process.env.ProgramData || 'C:\\ProgramData';
  return path.win32.resolve(programData, 'Koli Wada Dhaba POS');
}

function getInstallationPaths() {
  const root = getProgramDataRoot();
  const configDirectory = path.win32.resolve(root, 'config');
  const dataDirectory = path.win32.resolve(root, 'Data');
  return {
    root,
    dataDirectory,
    markerPath: path.win32.resolve(configDirectory, 'installation.json'),
    appSecretPath: path.win32.resolve(configDirectory, 'database-secrets.dpapi'),
    adminSecretPath: path.win32.resolve(configDirectory, 'postgres-admin.dpapi'),
  };
}

function normalizeWindowsPath(value) {
  return path.win32.normalize(value).replace(/[\\/]+$/, '').toLowerCase();
}

function assertRegularFile(filePath, description) {
  let stat;
  try {
    stat = fs.lstatSync(filePath);
  } catch {
    throw new Error(`${description} is missing. Run the Koli Wada Dhaba POS installer again or contact support.`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${description} is not a regular local file. The POS startup was stopped for safety.`);
  }
}

function assertDirectory(directoryPath, description) {
  let stat;
  try {
    stat = fs.lstatSync(directoryPath);
  } catch {
    throw new Error(`${description} is missing. Run the Koli Wada Dhaba POS installer again or contact support.`);
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`${description} is not a regular local directory. The POS startup was stopped for safety.`);
  }
}

function readInstallationIdentity() {
  if (process.platform !== 'win32') {
    throw new Error('The installed Koli Wada Dhaba POS application requires Windows.');
  }
  if (!app.isPackaged) {
    throw new Error('The local production POS must be started from its installed Windows application.');
  }

  const paths = getInstallationPaths();
  assertDirectory(paths.root, 'The machine-wide POS data folder');
  assertDirectory(paths.dataDirectory, 'The local PostgreSQL Data folder');
  assertRegularFile(paths.markerPath, 'The POS installation marker');
  assertRegularFile(paths.appSecretPath, 'The protected POS database configuration');
  assertRegularFile(paths.adminSecretPath, 'The protected POS administrator configuration');
  assertRegularFile(path.join(paths.dataDirectory, 'PG_VERSION'), 'The PostgreSQL version marker');

  let marker;
  try {
    const rawMarker = fs.readFileSync(paths.markerPath, 'utf8').replace(/^\uFEFF/, '');
    marker = JSON.parse(rawMarker);
  } catch {
    throw new Error('The POS installation marker is unreadable or invalid. The database was not started.');
  }

  const pgVersion = fs.readFileSync(path.join(paths.dataDirectory, 'PG_VERSION'), 'utf8').trim();
  if (
    marker.ServiceName !== SERVICE_NAME ||
    marker.PostgreSQLMajor !== '17' ||
    marker.Port !== DATABASE_PORT ||
    typeof marker.InstanceId !== 'string' ||
    !/^[a-f0-9]{32}$/i.test(marker.InstanceId) ||
    typeof marker.DataDirectory !== 'string' ||
    normalizeWindowsPath(marker.DataDirectory) !== normalizeWindowsPath(paths.dataDirectory) ||
    pgVersion !== '17'
  ) {
    throw new Error('The POS installation marker does not match the local PostgreSQL 17 database. Startup was stopped without changing any database files.');
  }

  return { ...paths, marker };
}

function splitWindowsCommandLine(commandLine) {
  const args = [];
  let index = 0;

  while (index < commandLine.length) {
    while (index < commandLine.length && /[\t ]/.test(commandLine[index])) index += 1;
    if (index >= commandLine.length) break;

    let argument = '';
    let quoted = false;

    while (index < commandLine.length) {
      if (/[\t ]/.test(commandLine[index]) && !quoted) break;

      let slashCount = 0;
      while (index < commandLine.length && commandLine[index] === '\\') {
        slashCount += 1;
        index += 1;
      }

      if (index < commandLine.length && commandLine[index] === '"') {
        argument += '\\'.repeat(Math.floor(slashCount / 2));
        if (slashCount % 2 === 1) {
          argument += '"';
          index += 1;
        } else if (quoted && commandLine[index + 1] === '"') {
          argument += '"';
          index += 2;
        } else {
          quoted = !quoted;
          index += 1;
        }
        continue;
      }

      argument += '\\'.repeat(slashCount);
      if (index >= commandLine.length || (/[\t ]/.test(commandLine[index]) && !quoted)) break;
      argument += commandLine[index];
      index += 1;
    }

    args.push(argument);
    while (index < commandLine.length && /[\t ]/.test(commandLine[index])) index += 1;
  }

  return args;
}

function getPosServiceDetails() {
  const script = [
    "$ErrorActionPreference = 'Stop'",
    `$service = Get-CimInstance -ClassName Win32_Service -Filter \"Name='${SERVICE_NAME}'\"` ,
    'if (-not $service) { throw "The dedicated POS PostgreSQL service is not installed." }',
    '$service | Select-Object Name, PathName, StartName, StartMode, State | ConvertTo-Json -Compress',
  ].join('; ');

  let output;
  try {
    output = execFileSync(
      path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
      {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 15_000,
        maxBuffer: 64 * 1024,
      },
    );
  } catch {
    throw new Error('Windows could not verify the dedicated Koli Wada Dhaba PostgreSQL service. The POS did not attempt to change any other PostgreSQL service.');
  }

  try {
    return JSON.parse(output);
  } catch {
    throw new Error('Windows returned an invalid identity for the dedicated POS PostgreSQL service.');
  }
}

function assertOwnedPosService(service, installation) {
  if (!service || service.Name !== SERVICE_NAME) {
    throw new Error('The dedicated Koli Wada Dhaba PostgreSQL service identity is invalid.');
  }

  const args = splitWindowsCommandLine(String(service.PathName || ''));
  const expectedExecutable = path.win32.resolve(
    process.resourcesPath,
    'postgresql17',
    'bin',
    'pg_ctl.exe',
  );

  if (args.length !== 9) {
    throw new Error('The dedicated POS PostgreSQL service command line is unexpected. It was left unchanged.');
  }

  const validCommand =
    normalizeWindowsPath(args[0]) === normalizeWindowsPath(expectedExecutable) &&
    args[1].toLowerCase() === 'runservice' &&
    args[2].toLowerCase() === '-n' &&
    args[3] === SERVICE_NAME &&
    args[4].toLowerCase() === '-d' &&
    normalizeWindowsPath(args[5]) === normalizeWindowsPath(installation.dataDirectory) &&
    args[6].toLowerCase() === '-w' &&
    args[7].toLowerCase() === '-o' &&
    args[8] === `-p ${DATABASE_PORT}`;

  if (!validCommand) {
    throw new Error('The PostgreSQL service does not match the packaged POS executable, Data directory, service name and port. It was left unchanged.');
  }

  if (
    String(service.StartName).toLowerCase() !== SERVICE_ACCOUNT.toLowerCase() ||
    String(service.StartMode).toLowerCase() !== 'auto'
  ) {
    throw new Error('The dedicated POS PostgreSQL service is not configured with the approved NetworkService account and Automatic startup.');
  }
}

function runServiceControl(args) {
  return new Promise((resolve, reject) => {
    execFile('sc.exe', args, { windowsHide: true, timeout: 20_000 }, (error, stdout, stderr) => {
      const text = `${stdout || ''}\n${stderr || ''}`;
      if (error && !/1056|already running/i.test(`${error.message} ${text}`)) {
        reject(new Error(text.trim() || error.message));
        return;
      }
      resolve(text);
    });
  });
}

async function waitForPosService(installation) {
  let service = getPosServiceDetails();
  assertOwnedPosService(service, installation);

  if (service.State !== 'Running') {
    if (service.State === 'Start Pending') {
      // Windows is already starting this verified service; wait below.
    } else if (service.State === 'Stopped') {
      try {
        await runServiceControl(['start', SERVICE_NAME]);
      } catch {
        throw new Error('The verified local POS database service is stopped and Windows did not allow it to start. Restart Windows or ask an administrator to check the Koli Wada Dhaba POS PostgreSQL service.');
      }
    } else {
      throw new Error(`The local POS PostgreSQL service is in an unexpected state (${service.State}).`);
    }
  }

  for (let attempt = 0; attempt < 90; attempt += 1) {
    service = getPosServiceDetails();
    assertOwnedPosService(service, installation);
    if (service.State === 'Running') return;
    if (service.State === 'Stopped') {
      throw new Error('The local POS PostgreSQL service stopped while starting. Check Windows Services or contact support.');
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }

  throw new Error('The local POS PostgreSQL service did not become ready within 90 seconds.');
}

function prepareApiLogs() {
  const logDirectory = path.join(app.getPath('userData'), 'logs');
  fs.mkdirSync(logDirectory, { recursive: true });

  const stdoutPath = path.join(logDirectory, 'api.log');
  const stderrPath = path.join(logDirectory, 'api-error.log');

  for (const filePath of [stdoutPath, stderrPath]) {
    try {
      const stat = fs.statSync(filePath);
      if (stat.size > MAX_LOG_BYTES) {
        const previousPath = `${filePath}.1`;
        try { fs.rmSync(previousPath, { force: true }); } catch { /* best-effort rotation */ }
        fs.renameSync(filePath, previousPath);
      }
    } catch (error) {
      if (!error || error.code !== 'ENOENT') throw error;
    }
  }

  apiStdoutFd = fs.openSync(stdoutPath, 'a');
  apiStderrFd = fs.openSync(stderrPath, 'a');
}

function closeApiLogHandles() {
  for (const fd of [apiStdoutFd, apiStderrFd]) {
    if (typeof fd === 'number') {
      try { fs.closeSync(fd); } catch { /* already closed */ }
    }
  }
  apiStdoutFd = null;
  apiStderrFd = null;
}

function assertApiPortAvailable() {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: API_HOST, port: API_PORT });
    let finished = false;
    socket.setTimeout(1000);
    socket.once('connect', () => {
      finished = true;
      socket.destroy();
      reject(new Error('Another process is already listening on the local POS API port 4000. Close the other application before starting Koli Wada Dhaba POS.'));
    });
    socket.once('error', (error) => {
      if (finished) return;
      finished = true;
      socket.destroy();
      if (error.code === 'ECONNREFUSED' || error.code === 'EHOSTUNREACH') resolve();
      else reject(new Error(`The local POS API port could not be checked (${error.code || 'unknown error'}).`));
    });
    socket.once('timeout', () => {
      if (finished) return;
      finished = true;
      socket.destroy();
      reject(new Error('The local POS API port check timed out.'));
    });
  });
}

function createApiEnvironment(configPath) {
  const env = {};
  const allowedInheritedNames = [
    'SystemRoot', 'windir', 'ProgramData', 'TEMP', 'TMP', 'PATH',
    'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA',
    'USERNAME', 'USERDOMAIN', 'COMPUTERNAME', 'OS',
  ];
  for (const name of allowedInheritedNames) {
    if (typeof process.env[name] === 'string') env[name] = process.env[name];
  }

  Object.assign(env, {
    ELECTRON_RUN_AS_NODE: '1',
    LOCAL_POS_APP: '1',
    NODE_ENV: 'production',
    NODE_PATH: path.join(process.resourcesPath, 'api', 'node_modules'),
    KWD_DPAPI_CONFIG: configPath,
    API_HOST: API_HOST,
    PORT: String(API_PORT),
    DB_POOL_MAX: '5',
    TRUST_PROXY_HOPS: '0',
    CORS_ORIGINS: `${CUSTOM_SCHEME}://${CUSTOM_HOST}`,
  });
  return env;
}

function requestApiHealth() {
  return new Promise((resolve, reject) => {
    const request = http.get(
      `${API_BASE_URL}${HEALTH_PATH}`,
      { timeout: 2000, headers: { Accept: 'application/json', Connection: 'close' } },
      (response) => {
        let body = '';
        response.setEncoding('utf8');
        response.on('data', (chunk) => {
          body += chunk;
          if (body.length > 16 * 1024) {
            request.destroy(new Error('The local API health response was unexpectedly large.'));
          }
        });
        response.on('end', () => {
          try {
            const health = JSON.parse(body);
            if (
              response.statusCode === 200 &&
              health.status === 'ok' &&
              health.database === 'connected' &&
              health.authenticationConfigured === true &&
              health.localOnly === true
            ) {
              resolve(health);
            } else {
              reject(new Error('The local API did not confirm the expected POS database identity.'));
            }
          } catch (error) {
            reject(error);
          }
        });
      },
    );
    request.once('timeout', () => request.destroy(new Error('The local API health check timed out.')));
    request.once('error', reject);
  });
}

async function waitForApi(attempts = 60) {
  let lastError = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (!apiProcess || apiProcess.exitCode !== null || apiExit) {
      const code = apiExit ? apiExit.code : apiProcess && apiProcess.exitCode;
      throw new Error(`The local POS API stopped before becoming healthy (exit code ${code ?? 'unknown'}). Review the API log in ${path.join(app.getPath('userData'), 'logs')}.`);
    }
    try {
      await requestApiHealth();
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  const detail = lastError instanceof Error ? lastError.message : 'No healthy response was received.';
  throw new Error(`The local POS API did not become healthy. ${detail} Review the API log in ${path.join(app.getPath('userData'), 'logs')}.`);
}

async function startLocalApi(installation) {
  const apiDirectory = path.resolve(process.resourcesPath, 'api');
  const serverScript = path.join(apiDirectory, 'dist', 'server.js');
  const nodeModulesDirectory = path.join(apiDirectory, 'node_modules');
  const postgresBin = path.join(process.resourcesPath, 'postgresql17', 'bin');
  const apiConfigPath = installation.appSecretPath;

  assertDirectory(apiDirectory, 'The packaged local API directory');
  assertDirectory(nodeModulesDirectory, 'The packaged local API dependency directory');
  assertRegularFile(serverScript, 'The packaged local API server');
  assertRegularFile(path.join(postgresBin, 'pg_ctl.exe'), 'The packaged PostgreSQL runtime');

  await waitForPosService(installation);
  await assertApiPortAvailable();
  prepareApiLogs();

  apiExit = null;
  apiProcess = spawn(process.execPath, [serverScript], {
    cwd: apiDirectory,
    env: createApiEnvironment(apiConfigPath),
    stdio: ['ignore', apiStdoutFd, apiStderrFd],
    windowsHide: true,
  });

  apiProcess.once('error', (error) => {
    apiExit = { code: null, signal: null, error };
  });
  apiProcess.once('exit', (code, signal) => {
    apiExit = { code, signal, error: null };
  });

  // Give Node/Electron a moment to report an early startup failure before the
  // first health request, so a different process cannot impersonate our API.
  await new Promise((resolve) => setTimeout(resolve, 750));
  await waitForApi();
}

function stopLocalApi() {
  if (apiProcess && apiProcess.exitCode === null && !apiProcess.killed) {
    try { apiProcess.kill('SIGTERM'); } catch { /* process may already be exiting */ }
  }
}

function isTrustedRendererFrame(event) {
  try {
    if (!event.senderFrame || event.senderFrame !== event.sender.mainFrame) return false;
    const frameUrl = new URL(event.senderFrame.url);
    return frameUrl.protocol === `${CUSTOM_SCHEME}:` && frameUrl.hostname === CUSTOM_HOST;
  } catch {
    return false;
  }
}

function validatePrinterName(printerName, printers) {
  if (printerName === undefined || printerName === null || printerName === '') return '';
  if (typeof printerName !== 'string' || printerName.length > 256 || /[\r\n\0]/.test(printerName)) {
    throw new Error('The selected Windows printer name is invalid.');
  }
  const found = printers.some((printer) => printer.name === printerName);
  if (!found) throw new Error('The selected Windows printer is not currently installed or available.');
  return printerName;
}

function printWebContents(webContents, printerName) {
  return new Promise((resolve, reject) => {
    webContents.print(
      {
        silent: Boolean(printerName),
        printBackground: true,
        deviceName: printerName || undefined,
        margins: { marginType: 'default' },
        color: true,
        copies: 1,
        collate: false,
        landscape: false,
        scaleFactor: 100,
      },
      (success, failureReason) => {
        if (success) resolve();
        else reject(new Error(failureReason || 'Windows could not complete the print job.'));
      },
    );
  });
}

async function listPrintersForTrustedRenderer(event) {
  if (!isTrustedRendererFrame(event) || !mainWindow || mainWindow.isDestroyed()) {
    throw new Error('Printer access is available only from the POS application window.');
  }
  const printers = await mainWindow.webContents.getPrintersAsync();
  return printers.map((printer) => ({ name: printer.name }));
}

async function testPrinterForTrustedRenderer(event, printerName) {
  if (!isTrustedRendererFrame(event)) {
    throw new Error('Printer access is available only from the POS application window.');
  }
  const printers = mainWindow && !mainWindow.isDestroyed()
    ? await mainWindow.webContents.getPrintersAsync()
    : [];
  const selectedPrinter = validatePrinterName(printerName, printers);

  const testWindow = new BrowserWindow({
    show: false,
    width: 360,
    height: 480,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      javascript: false,
      webSecurity: true,
    },
  });

  const testHtml = '<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'"></head><body style="font-family:monospace;text-align:center;padding:12px"><h2>KOLI WADA DHABA</h2><p>Thermal printer test</p><p>58 mm / 80 mm printer connection</p><p>Thank you.</p></body></html>';

  try {
    await testWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(testHtml)}`);
    await printWebContents(testWindow.webContents, selectedPrinter);
  } finally {
    if (!testWindow.isDestroyed()) testWindow.destroy();
  }
}

async function printCurrentViewForTrustedRenderer(event, printerName) {
  if (!isTrustedRendererFrame(event) || !mainWindow || mainWindow.isDestroyed()) {
    throw new Error('Printing is available only from the POS application window.');
  }
  const printers = await mainWindow.webContents.getPrintersAsync();
  const selectedPrinter = validatePrinterName(printerName, printers);
  await printWebContents(mainWindow.webContents, selectedPrinter);
}

function registerIpcHandlers() {
  ipcMain.handle('printers:list', listPrintersForTrustedRenderer);
  ipcMain.handle('printers:test', testPrinterForTrustedRenderer);
  ipcMain.handle('printing:current-view', printCurrentViewForTrustedRenderer);
}

function isAllowedRendererUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === `${CUSTOM_SCHEME}:` && url.hostname === CUSTOM_HOST;
  } catch {
    return false;
  }
}

function registerRendererProtocol() {
  if (protocolHandlerRegistered) return;
  protocolHandlerRegistered = true;

  protocol.handle(CUSTOM_SCHEME, async (request) => {
    let requestUrl;
    let pathname;
    try {
      requestUrl = new URL(request.url);
      pathname = decodeURIComponent(requestUrl.pathname);
    } catch {
      return new Response('Bad request', { status: 400 });
    }

    if (
      requestUrl.hostname !== CUSTOM_HOST ||
      requestUrl.username ||
      requestUrl.password ||
      requestUrl.search ||
      requestUrl.hash ||
      pathname.includes('\0')
    ) {
      return new Response('Not found', { status: 404 });
    }

    const requestedPath = path.resolve(rendererDirectory, `.${pathname}`);
    const relativePath = path.relative(rendererDirectory, requestedPath);
    if (
      relativePath === '' ||
      relativePath === '..' ||
      relativePath.startsWith(`..${path.sep}`) ||
      path.isAbsolute(relativePath)
    ) {
      return new Response('Not found', { status: 404 });
    }

    try {
      const contents = await fs.promises.readFile(requestedPath);
      const contentType = MIME_TYPES[path.extname(requestedPath).toLowerCase()] || 'application/octet-stream';
      return new Response(contents, {
        headers: {
          'Content-Type': contentType,
          'Content-Security-Policy': [
            "default-src 'self'",
            "script-src 'self'",
            "connect-src 'self' http://127.0.0.1:4000",
            "img-src 'self' data:",
            "style-src 'self' 'unsafe-inline'",
            "font-src 'self' data:",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'self'",
            "frame-ancestors 'none'",
          ].join('; '),
          'X-Content-Type-Options': 'nosniff',
          'Referrer-Policy': 'no-referrer',
          'X-Frame-Options': 'DENY',
          'Cache-Control': 'no-store',
        },
      });
    } catch (error) {
      if (error && typeof error === 'object' && error.code === 'ENOENT') {
        return new Response('Not found', { status: 404 });
      }
      console.error('Could not load the POS application resource:', error);
      return new Response('The POS application could not be loaded.', { status: 500 });
    }
  });
}

const MIME_TYPES = Object.freeze({
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
});

function configureSessionSecurity() {
  session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => {
    callback(false);
  });
  session.defaultSession.setPermissionCheckHandler(() => false);
  return session.defaultSession.setProxy({ mode: 'direct' });
}

async function createMainWindow() {
  const installation = readInstallationIdentity();
  registerRendererProtocol();
  registerIpcHandlers();
  await startLocalApi(installation);

  mainWindow = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 960,
    minHeight: 680,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#f5f7f4',
    title: 'Koli Wada Dhaba POS',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      devTools: false,
      spellcheck: false,
      preload: path.join(__dirname, 'preload.cjs'),
    },
  });

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event, targetUrl) => {
    if (!isAllowedRendererUrl(targetUrl)) event.preventDefault();
  });
  mainWindow.webContents.on('will-redirect', (event, targetUrl) => {
    if (!isAllowedRendererUrl(targetUrl)) event.preventDefault();
  });
  mainWindow.webContents.on('will-attach-webview', (event) => event.preventDefault());
  mainWindow.webContents.on('render-process-gone', (_event, details) => {
    console.error('POS renderer process exited:', details.reason);
    if (mainWindow && !mainWindow.isDestroyed()) {
      dialog.showErrorBox('Koli Wada Dhaba POS', 'The POS screen stopped unexpectedly. Close and reopen the application. Your committed billing data remains in the local database.');
    }
  });

  mainWindow.once('ready-to-show', () => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.show();
  });
  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  await mainWindow.loadURL(`${CUSTOM_SCHEME}://${CUSTOM_HOST}/index.html`);
}

function stopAndCloseApi() {
  if (shutdownStarted) return;
  shutdownStarted = true;
  stopLocalApi();
  closeApiLogHandles();
}

app.on('second-instance', () => {
  if (mainWindow && !mainWindow.isDestroyed()) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  }
});

app.on('before-quit', stopAndCloseApi);
app.on('window-all-closed', () => {
  stopAndCloseApi();
  if (process.platform !== 'darwin') app.quit();
});

app.whenReady().then(async () => {
  if (!hasSingleInstanceLock) return;
  await configureSessionSecurity();
  await createMainWindow();
}).catch((error) => {
  console.error('Could not start Koli Wada Dhaba POS:', error);
  stopLocalApi();
  closeApiLogHandles();
  dialog.showErrorBox(
    'Koli Wada Dhaba POS could not start',
    error instanceof Error ? error.message : 'An unexpected startup error occurred. Contact support.',
  );
  app.quit();
});

app.on('will-quit', () => {
  stopLocalApi();
  closeApiLogHandles();
});
