const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const migrationPath = path.join(__dirname, '../../sql/migrations/20260821_mobile_sync.sql')
const tablesPath = path.join(__dirname, '../../sql/tables.sql')

function readSchema(filePath) {
  return fs.readFileSync(filePath, 'utf8')
}

test('mobile migration contains every required durable field', () => {
  const sql = readSchema(migrationPath)

  for (const token of [
    'version',
    'deleted_at',
    'notify_day_before',
    'notify_same_day',
    'mobile_sync_changes',
    'mobile_sync_operations',
    'mobile_device_sessions'
  ]) {
    assert.match(sql, new RegExp(`\\b${token}\\b`, 'i'), token)
  }

  assert.match(sql, /UNIQUE KEY uk_mobile_operation_id \(operation_id\)/)
  assert.match(sql, /AUTO_INCREMENT/)
})

test('mobile birthday migration remains an explicitly one-shot ALTER', () => {
  const sql = readSchema(migrationPath)

  assert.match(sql, /ALTER TABLE birthdays/i)
  assert.doesNotMatch(sql, /ALTER TABLE IF NOT EXISTS birthdays/i)
})

test('mobile birthday fields preserve durable types and defaults', () => {
  for (const sql of [readSchema(migrationPath), readSchema(tablesPath)]) {
    assert.match(sql, /version\s+BIGINT UNSIGNED NOT NULL DEFAULT 1/i)
    assert.match(sql, /deleted_at\s+DATETIME\s+(?:NULL|DEFAULT NULL)/i)
    assert.match(sql, /notify_day_before\s+TINYINT\(1\) NOT NULL DEFAULT 1/i)
    assert.match(sql, /notify_same_day\s+TINYINT\(1\) NOT NULL DEFAULT 1/i)
    assert.match(sql, /(?:ADD )?KEY idx_birthdays_deleted_at \(deleted_at\)/i)
  }
})

test('mobile sync tables keep cursor and versions unsigned BIGINTs', () => {
  for (const sql of [readSchema(migrationPath), readSchema(tablesPath)]) {
    assert.match(sql, /seq BIGINT UNSIGNED NOT NULL AUTO_INCREMENT/i)
    assert.match(sql, /version BIGINT UNSIGNED NOT NULL/i)
  }
})

test('mobile operations store replay responses as JSON', () => {
  for (const sql of [readSchema(migrationPath), readSchema(tablesPath)]) {
    assert.match(sql, /response_json JSON NOT NULL/i)
    assert.match(sql, /UNIQUE KEY uk_mobile_operation_id \(operation_id\)/i)
  }
})

test('mobile device sessions persist only fixed-length token hashes', () => {
  for (const sql of [readSchema(migrationPath), readSchema(tablesPath)]) {
    assert.match(sql, /access_token_hash CHAR\(64\) NOT NULL/i)
    assert.match(sql, /refresh_token_hash CHAR\(64\) NOT NULL/i)
    assert.doesNotMatch(sql, /access_token\s+VARCHAR/i)
    assert.doesNotMatch(sql, /refresh_token\s+VARCHAR/i)
  }
})

test('clean-install schema mirrors mobile final state', () => {
  const sql = readSchema(tablesPath)

  for (const token of [
    'version',
    'deleted_at',
    'notify_day_before',
    'notify_same_day',
    'mobile_sync_changes',
    'mobile_sync_operations',
    'mobile_device_sessions'
  ]) {
    assert.match(sql, new RegExp(`\\b${token}\\b`, 'i'), token)
  }

  assert.match(sql, /CREATE TABLE IF NOT EXISTS mobile_sync_changes/i)
  assert.match(sql, /CREATE TABLE IF NOT EXISTS mobile_sync_operations/i)
  assert.match(sql, /CREATE TABLE IF NOT EXISTS mobile_device_sessions/i)
})
