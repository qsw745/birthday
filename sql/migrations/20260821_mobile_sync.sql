-- One-shot migration: deployment must verify these birthday columns are absent
-- before execution and present afterward.
ALTER TABLE birthdays
  ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  ADD COLUMN deleted_at DATETIME NULL,
  ADD COLUMN notify_day_before TINYINT(1) NOT NULL DEFAULT 1,
  ADD COLUMN notify_same_day TINYINT(1) NOT NULL DEFAULT 1,
  ADD KEY idx_birthdays_deleted_at (deleted_at);

-- Historical reminder provenance was not stored. This one-shot heuristic marks
-- reminders matching the birthday-derived time (or lacking one) as derived.
ALTER TABLE email_reminders
  ADD COLUMN schedule_mode ENUM('derived','exact') NULL,
  ADD COLUMN generation CHAR(36) NULL;

UPDATE email_reminders r
JOIN birthdays b ON b.id = r.birthday_id
   SET r.schedule_mode = CASE
         WHEN b.nextSolarDate IS NULL OR r.remind_time = b.nextSolarDate THEN 'derived'
         ELSE 'exact'
       END,
       r.generation = UUID();

ALTER TABLE email_reminders
  MODIFY COLUMN schedule_mode ENUM('derived','exact') NOT NULL,
  MODIFY COLUMN generation CHAR(36) NOT NULL;

CREATE TABLE IF NOT EXISTS mobile_sync_changes (
  seq BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type VARCHAR(32) NOT NULL,
  entity_id VARCHAR(36) NOT NULL,
  operation ENUM('upsert','delete') NOT NULL,
  version BIGINT UNSIGNED NOT NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (seq),
  KEY idx_mobile_changes_entity (entity_type, entity_id, seq)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS mobile_sync_operations (
  operation_id VARCHAR(36) NOT NULL,
  device_id VARCHAR(36) NOT NULL,
  response_json JSON NOT NULL,
  processed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mobile_operation_id (operation_id),
  KEY idx_mobile_operations_device (device_id, processed_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS mobile_device_sessions (
  device_id VARCHAR(36) NOT NULL,
  username VARCHAR(64) NOT NULL,
  device_name VARCHAR(100) NOT NULL,
  access_token_hash CHAR(64) NOT NULL,
  refresh_token_hash CHAR(64) NOT NULL,
  access_expires_at DATETIME NOT NULL,
  refresh_expires_at DATETIME NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TIMESTAMP NULL DEFAULT NULL,
  revoked_at TIMESTAMP NULL DEFAULT NULL,
  PRIMARY KEY (device_id),
  UNIQUE KEY uk_mobile_access_hash (access_token_hash),
  UNIQUE KEY uk_mobile_refresh_hash (refresh_token_hash),
  KEY idx_mobile_sessions_username (username, revoked_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
