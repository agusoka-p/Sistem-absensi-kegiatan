CREATE DATABASE IF NOT EXISTS absensi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE absensi;

-- ---------------------------------------------------------------------
-- 1. Master pengguna dan organisasi
-- ---------------------------------------------------------------------
CREATE TABLE roles (
  role_id  SMALLINT AUTO_INCREMENT PRIMARY KEY,
  code     VARCHAR(20) NOT NULL UNIQUE,
  name     VARCHAR(50) NOT NULL
);

CREATE TABLE departments (
  department_id  INT AUTO_INCREMENT PRIMARY KEY,
  code           VARCHAR(20)  NOT NULL UNIQUE,
  name           VARCHAR(150) NOT NULL
);

CREATE TABLE users (
  user_id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  role_id         SMALLINT     NOT NULL,
  department_id   INT          NOT NULL,
  identity_number VARCHAR(30)  NOT NULL UNIQUE,
  full_name       VARCHAR(150) NOT NULL,
  email           VARCHAR(150) NOT NULL UNIQUE,
  phone           VARCHAR(20),
  password_hash   VARCHAR(255) NOT NULL,
  status          VARCHAR(20)  NOT NULL DEFAULT 'active',
  FOREIGN KEY (role_id)       REFERENCES roles(role_id)             ON UPDATE CASCADE ON DELETE RESTRICT,
  FOREIGN KEY (department_id) REFERENCES departments(department_id) ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE students (
  user_id    BIGINT   PRIMARY KEY,
  entry_year SMALLINT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE employees (
  user_id        BIGINT PRIMARY KEY,
  position_title VARCHAR(100),
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 2. Kelas dan pendaftaran kelas
-- ---------------------------------------------------------------------
CREATE TABLE classes (
  class_id      INT AUTO_INCREMENT PRIMARY KEY,
  department_id INT         NOT NULL,
  name          VARCHAR(50) NOT NULL,
  FOREIGN KEY (department_id) REFERENCES departments(department_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  UNIQUE (department_id, name)
);

CREATE TABLE class_enrollments (
  class_enrollment_id BIGINT   AUTO_INCREMENT PRIMARY KEY,
  class_id            INT      NOT NULL,
  student_id          BIGINT   NOT NULL,
  is_active           BOOLEAN  NOT NULL DEFAULT TRUE,
  enrolled_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (class_id)   REFERENCES classes(class_id)    ON UPDATE CASCADE ON DELETE RESTRICT,
  FOREIGN KEY (student_id) REFERENCES students(user_id)    ON UPDATE CASCADE ON DELETE RESTRICT,
  UNIQUE (class_id, student_id)
);

-- ---------------------------------------------------------------------
-- 3. Lokasi dan sesi
-- ---------------------------------------------------------------------
CREATE TABLE locations (
  location_id INT AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(100)  NOT NULL UNIQUE,
  latitude    DECIMAL(9,6)  NOT NULL,
  longitude   DECIMAL(9,6)  NOT NULL,
  radius_m    INT           NOT NULL DEFAULT 50
);

CREATE TABLE sessions (
  session_id      BIGINT AUTO_INCREMENT PRIMARY KEY,
  title           VARCHAR(200) NOT NULL,
  location_id     INT          NOT NULL,
  created_by      BIGINT       NOT NULL,
  checkin_open_at DATETIME     NOT NULL,
  start_at        DATETIME     NOT NULL,
  late_after      DATETIME     NOT NULL,
  end_at          DATETIME     NOT NULL,
  status          VARCHAR(20)  NOT NULL DEFAULT 'scheduled',
  require_qr      BOOLEAN      NOT NULL DEFAULT TRUE,
  require_gps     BOOLEAN      NOT NULL DEFAULT TRUE,
  FOREIGN KEY (location_id) REFERENCES locations(location_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  FOREIGN KEY (created_by)  REFERENCES users(user_id)         ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE session_participants (
  session_id BIGINT   NOT NULL,
  user_id    BIGINT   NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (session_id, user_id),
  FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON UPDATE CASCADE ON DELETE CASCADE,
  FOREIGN KEY (user_id)    REFERENCES users(user_id)       ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE qr_tokens (
  qr_token_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  session_id  BIGINT   NOT NULL,
  token_hash  CHAR(64) NOT NULL UNIQUE,
  expires_at  DATETIME NOT NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON UPDATE CASCADE ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 4. Izin / sakit
-- ---------------------------------------------------------------------
CREATE TABLE leave_requests (
  leave_request_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  session_id       BIGINT       NOT NULL,
  user_id          BIGINT       NOT NULL,
  leave_type       VARCHAR(20)  NOT NULL,
  reason           TEXT         NOT NULL,
  attachment_url   VARCHAR(500),
  status           VARCHAR(20)  NOT NULL DEFAULT 'pending',
  reviewed_by      BIGINT,
  reviewed_at      DATETIME,
  review_note      TEXT,
  FOREIGN KEY (reviewed_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  FOREIGN KEY (session_id, user_id) REFERENCES session_participants (session_id, user_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  UNIQUE (session_id, user_id)
);

-- ---------------------------------------------------------------------
-- 5. Absensi dan verifikasi
-- ---------------------------------------------------------------------
CREATE TABLE attendances (
  attendance_id    BIGINT AUTO_INCREMENT PRIMARY KEY,
  session_id       BIGINT      NOT NULL,
  user_id          BIGINT      NOT NULL,
  leave_request_id BIGINT,
  status           VARCHAR(20) NOT NULL,
  check_in_at      DATETIME,
  check_out_at     DATETIME,
  corrected_by     BIGINT,
  note             TEXT,
  FOREIGN KEY (corrected_by)     REFERENCES users(user_id)                    ON UPDATE CASCADE ON DELETE RESTRICT,
  FOREIGN KEY (leave_request_id) REFERENCES leave_requests(leave_request_id)  ON UPDATE CASCADE ON DELETE RESTRICT,
  FOREIGN KEY (session_id, user_id) REFERENCES session_participants (session_id, user_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  UNIQUE (session_id, user_id),
  UNIQUE (leave_request_id)
);

CREATE TABLE attendance_verifications (
  attendance_verification_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  attendance_id              BIGINT        NOT NULL,
  session_id                 BIGINT        NOT NULL,
  qr_token_id                BIGINT,
  event_type                 VARCHAR(20)   NOT NULL,
  method                     VARCHAR(10)   NOT NULL,
  is_passed                  BOOLEAN       NOT NULL,
  latitude                   DECIMAL(9,6),
  longitude                  DECIMAL(9,6),
  distance_m                 DECIMAL(8,2),
  created_at                 DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (attendance_id) REFERENCES attendances(attendance_id) ON UPDATE CASCADE ON DELETE CASCADE,
  FOREIGN KEY (session_id)    REFERENCES sessions(session_id)       ON UPDATE CASCADE ON DELETE RESTRICT,
  FOREIGN KEY (qr_token_id)   REFERENCES qr_tokens(qr_token_id)     ON UPDATE CASCADE ON DELETE RESTRICT
);

-- ---------------------------------------------------------------------
-- 6. Audit log
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
  audit_log_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  user_id      BIGINT,
  action       VARCHAR(50) NOT NULL,
  entity_type  VARCHAR(50) NOT NULL,
  entity_id    BIGINT,
  created_at   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE RESTRICT
);
