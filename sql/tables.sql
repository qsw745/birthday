CREATE DATABASE IF NOT EXISTS email_server
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_general_ci;

USE email_server;

CREATE TABLE IF NOT EXISTS birthdays (
  id           VARCHAR(36)  NOT NULL,          -- UUID
  name         VARCHAR(64)  NOT NULL,
  lunarMonth   TINYINT UNSIGNED NOT NULL,       -- 1-12
  lunarDay     TINYINT UNSIGNED NOT NULL,       -- 1-30
  isLeapMonth  TINYINT(1)   NOT NULL DEFAULT 0, -- 0/1
  remindTime   VARCHAR(8)   DEFAULT NULL,       -- HH:mm 或 HH:mm:ss
  nextSolarDate DATETIME    DEFAULT NULL,       -- 下一次阳历提醒时间
  version      BIGINT NOT NULL DEFAULT 1,
  deleted_at   DATETIME NULL,
  notify_day_before TINYINT(1) NOT NULL DEFAULT 1,
  notify_same_day  TINYINT(1) NOT NULL DEFAULT 1,

  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (id),
  KEY idx_nextSolarDate (nextSolarDate),
  KEY idx_lunar (lunarMonth, lunarDay, isLeapMonth),
  KEY idx_birthdays_deleted_at (deleted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS webauthn_credentials (
  credential_id VARCHAR(255)  NOT NULL,          -- base64url 编码的凭证 ID
  username      VARCHAR(64)   NOT NULL,          -- 对应 AUTH_USERNAME
  public_key    BLOB          NOT NULL,          -- COSE 公钥
  counter       BIGINT UNSIGNED NOT NULL DEFAULT 0,
  transports    VARCHAR(255)  DEFAULT NULL,      -- JSON 数组字符串，如 ["internal","hybrid"]
  device_name   VARCHAR(100)  DEFAULT NULL,      -- 用户可读的设备备注
  created_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at  TIMESTAMP     NULL DEFAULT NULL,

  PRIMARY KEY (credential_id),
  KEY idx_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS email_reminders (
  id          VARCHAR(36)   NOT NULL,          -- UUID
  birthday_id VARCHAR(36)   NOT NULL,          -- 对应 birthdays.id（你代码里每个生日一条提醒）
  name        VARCHAR(64)   NOT NULL,
  email       VARCHAR(128)  NOT NULL,
  remind_time DATETIME      NOT NULL,
  message     TEXT          NOT NULL,
  status      TINYINT       NOT NULL DEFAULT 0, -- 0=当前 occurrence 待发，1=已送达
  schedule_mode ENUM('derived','exact') NOT NULL,
  generation  CHAR(36)      NOT NULL,
  claim_token CHAR(36)      NULL,
  claim_generation CHAR(36) NULL,
  claim_remind_time DATETIME NULL,
  claimed_at DATETIME       NULL,
  delivered_remind_time DATETIME NULL,

  created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (id),
  UNIQUE KEY uk_birthday_id (birthday_id),      -- 保证“每个生日一条提醒”（符合你 update 假设）
  KEY idx_status_time (status, remind_time),
  CONSTRAINT fk_email_reminders_birthdays
    FOREIGN KEY (birthday_id) REFERENCES birthdays(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS mobile_sync_changes (
  seq BIGINT NOT NULL AUTO_INCREMENT,
  entity_type VARCHAR(32) NOT NULL,
  entity_id VARCHAR(36) NOT NULL,
  operation ENUM('upsert','delete') NOT NULL,
  entity_version BIGINT NOT NULL,
  record_json JSON NOT NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (seq),
  KEY idx_mobile_changes_entity (entity_type, entity_id, seq)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS mobile_sync_operations (
  operation_id VARCHAR(36) NOT NULL,
  device_id VARCHAR(36) NOT NULL,
  base_version BIGINT NOT NULL,
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
