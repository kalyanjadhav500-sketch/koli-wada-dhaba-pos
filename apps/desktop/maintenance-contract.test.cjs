'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  validateOwnerToken,
  validateBackupId,
  createOwnerRequest,
  createRestorePrepareRequest,
  createRestoreExecuteRequest,
} = require('./maintenance-contract.cjs');

const token = 'header.payload.signature';
const backupId = 'koli-wada-dhaba-20261126-013000-0123456789abcdef0123456789abcdef.dump';

test('Owner token validation accepts only bounded JWT-shaped strings', () => {
  assert.equal(validateOwnerToken(token), token);
  assert.throws(() => validateOwnerToken('owner\r\nAuthorization: forged'), /Owner account/);
  assert.throws(() => validateOwnerToken(`x.${'a'.repeat(5000)}.z`), /Owner account/);
});

test('backup identifiers cannot carry paths or arbitrary filenames', () => {
  assert.equal(validateBackupId(backupId), backupId);
  assert.throws(() => validateBackupId('..\\secret.dump'), /protected POS backup/);
  assert.throws(() => validateBackupId('C:\\ProgramData\\backup.dump'), /protected POS backup/);
  assert.throws(() => validateBackupId('backup.dump'), /protected POS backup/);
});

test('Owner requests contain only fixed operation names and bearer token', () => {
  assert.deepEqual(createOwnerRequest('manualBackup', token), { operation: 'manualBackup', token });
  assert.throws(() => createOwnerRequest('runPowerShell', token), /Unsupported/);
});

test('restore preparation requires a typed confirmation and a validated backup ID', () => {
  assert.deepEqual(createRestorePrepareRequest(token, backupId, 'RESTORE'), {
    operation: 'prepareRestore', token, backupId, confirmRestore: 'RESTORE',
  });
  assert.throws(() => createRestorePrepareRequest(token, backupId, 'restore'), /confirmation/);
});

test('restore execution accepts only an opaque one-use broker ticket', () => {
  const ticket = '0123456789abcdef0123456789abcdef';
  assert.deepEqual(createRestoreExecuteRequest(ticket), { operation: 'executeRestore', ticket });
  assert.throws(() => createRestoreExecuteRequest('C:\\backup.dump'), /expired/);
});
