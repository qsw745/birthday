CREATE TABLE IF NOT EXISTS birthdays (
  id           VARCHAR(36)  NOT NULL,          -- UUID
  name         VARCHAR(64)  NOT NULL,
  lunarMonth   TINYINT UNSIGNED NOT NULL,       -- 1-12
  lunarDay     TINYINT UNSIGNED NOT NULL,       -- 1-30
  isLeapMonth  TINYINT(1)   NOT NULL DEFAULT 0, -- 0/1
  remindTime   VARCHAR(8)   DEFAULT NULL,       -- HH:mm 或 HH:mm:ss
  nextSolarDate DATETIME    DEFAULT NULL,       -- 下一次阳历提醒时间

  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (id),
  KEY idx_nextSolarDate (nextSolarDate),
  KEY idx_lunar (lunarMonth, lunarDay, isLeapMonth)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS email_reminders (
  id          VARCHAR(36)   NOT NULL,          -- UUID
  birthday_id VARCHAR(36)   NOT NULL,          -- 对应 birthdays.id（你代码里每个生日一条提醒）
  name        VARCHAR(64)   NOT NULL,
  email       VARCHAR(128)  NOT NULL,
  remind_time DATETIME      NOT NULL,
  message     TEXT          NOT NULL,
  status      TINYINT       NOT NULL DEFAULT 0, -- 0=待发

  created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (id),
  UNIQUE KEY uk_birthday_id (birthday_id),      -- 保证“每个生日一条提醒”（符合你 update 假设）
  KEY idx_status_time (status, remind_time),
  CONSTRAINT fk_email_reminders_birthdays
    FOREIGN KEY (birthday_id) REFERENCES birthdays(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

