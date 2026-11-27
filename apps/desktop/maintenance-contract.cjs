'use strict';

const OWNER_OPERATIONS = new Set(['status', 'history', 'manualBackup']);
const BACKUP_ID_PATTERN = /^koli-wada-dhaba-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.dump$/;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

function validateOwnerToken(token) {
  if (typeof token !== 'string' || token.length > 4096 || !TOKEN_PATTERN.test(token)) {
    throw new TypeError('Sign in with the Owner account to manage backups.');
  }
  return token;
}

function validateBackupId(backupId) {
  if (typeof backupId !== 'string' || !BACKUP_ID_PATTERN.test(backupId)) {
    throw new TypeError('Select a valid protected POS backup.');
  }
  return backupId;
}

function createOwnerRequest(operation, token) {
  if (!OWNER_OPERATIONS.has(operation)) {
    throw new TypeError('Unsupported protected POS backup operation.');
  }
  return Object.freeze({ operation, token: validateOwnerToken(token) });
}

function createRestorePrepareRequest(token, backupId, confirmation) {
  if (confirmation !== 'RESTORE') {
    throw new TypeError('Explicit restore confirmation is required.');
  }
  return Object.freeze({
    operation: 'prepareRestore',
    token: validateOwnerToken(token),
    backupId: validateBackupId(backupId),
    confirmRestore: confirmation,
  });
}

function createRestoreExecuteRequest(ticket) {
  if (typeof ticket !== 'string' || !/^[0-9a-f]{32}$/.test(ticket)) {
    throw new TypeError('The restore confirmation expired. Select the backup again.');
  }
  return Object.freeze({ operation: 'executeRestore', ticket });
}

module.exports = {
  validateOwnerToken,
  validateBackupId,
  createOwnerRequest,
  createRestorePrepareRequest,
  createRestoreExecuteRequest,
};
