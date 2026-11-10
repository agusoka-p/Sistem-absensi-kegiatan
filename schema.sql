-- =====================================================================
-- Skema Sistem Absensi (sesuai ERD terbaru, 15 tabel)
-- DBMS: MySQL 8.0.16+ (CHECK baru ditegakkan mulai versi ini)
-- Waktu disimpan sebagai DATETIME: simpan dalam UTC dari aplikasi.
-- DDL di MySQL auto-commit, jadi tidak memakai BEGIN/COMMIT.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS absensi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE absensi;

-- ---------------------------------------------------------------------
-- 1. Master pengguna dan organisasi
-- ---------------------------------------------------------------------
CREATE TABLE roles (
  role_id SMALLINT AUTO_INCREMENT PRIMARY KEY,
  code  VARCHAR(20) NOT NULL UNIQUE,   -- student, lecturer, staff, admin, superadmin
  name  VARCHAR(50) NOT NULL
);

CREATE TABLE departments (
  department_id INT AUTO_INCREMENT PRIMARY KEY,
  code  VARCHAR(20)  NOT NULL UNIQUE,
  name  VARCHAR(150) NOT NULL
);

CREATE TABLE users (
  user_id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  role_id         SMALLINT     NOT NULL,
  department_id   INT          NOT NULL,
  identity_number VARCHAR(30)  NOT NULL UNIQUE,   -- NIM / NIP / NIDN
  full_name       VARCHAR(150) NOT NULL,
  email           VARCHAR(150) NOT NULL UNIQUE,
  phone           VARCHAR(20),
  password_hash   VARCHAR(255) NOT NULL,
  status          VARCHAR(20)  NOT NULL DEFAULT 'active',
  CONSTRAINT fk_users_role FOREIGN KEY (role_id)
    REFERENCES roles(role_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_users_department FOREIGN KEY (department_id)
    REFERENCES departments(department_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_users_status CHECK (status IN ('active', 'inactive', 'suspended')),
  CONSTRAINT chk_users_email  CHECK (LOCATE('@', email) > 1)
);

-- Spesialisasi pengguna (1 : 0..1)
CREATE TABLE students (
  user_id    BIGINT   PRIMARY KEY,
  entry_year SMALLINT NOT NULL,
  CONSTRAINT fk_students_user FOREIGN KEY (user_id)
    REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT chk_students_year CHECK (entry_year BETWEEN 2000 AND 2100)
);

CREATE TABLE employees (
  user_id        BIGINT PRIMARY KEY,
  position_title VARCHAR(100),
  CONSTRAINT fk_employees_user FOREIGN KEY (user_id)
    REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 2. Kelas dan pendaftaran kelas
-- ---------------------------------------------------------------------
CREATE TABLE classes (
  class_id      INT AUTO_INCREMENT PRIMARY KEY,
  department_id INT         NOT NULL,
  name          VARCHAR(50) NOT NULL,
  CONSTRAINT fk_classes_department FOREIGN KEY (department_id)
    REFERENCES departments(department_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT uq_classes UNIQUE (department_id, name)
);

CREATE TABLE class_enrollments (
  class_enrollment_id BIGINT   AUTO_INCREMENT PRIMARY KEY,
  class_id    INT      NOT NULL,
  student_id  BIGINT   NOT NULL,
  is_active   BOOLEAN  NOT NULL DEFAULT TRUE,
  enrolled_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- kolom bantu pengganti partial index: 1 jika aktif, NULL jika tidak
  active_flag TINYINT GENERATED ALWAYS AS (IF(is_active, 1, NULL)) VIRTUAL,
  CONSTRAINT fk_enroll_class FOREIGN KEY (class_id)
    REFERENCES classes(class_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  -- ON UPDATE RESTRICT: student_id ikut index yang memuat kolom virtual
  CONSTRAINT fk_enroll_student FOREIGN KEY (student_id)
    REFERENCES students(user_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_class_enrollment UNIQUE (class_id, student_id),
  -- satu mahasiswa hanya punya satu kelas aktif pada satu waktu
  -- (NULL boleh berulang di UNIQUE, sehingga baris non-aktif tidak dibatasi)
  CONSTRAINT uq_enrollment_active_student UNIQUE (student_id, active_flag)
);

-- ---------------------------------------------------------------------
-- 3. Lokasi dan sesi
-- ---------------------------------------------------------------------
CREATE TABLE locations (
  location_id INT AUTO_INCREMENT PRIMARY KEY,
  name      VARCHAR(100)  NOT NULL UNIQUE,
  latitude  DECIMAL(9,6)  NOT NULL,
  longitude DECIMAL(9,6)  NOT NULL,
  radius_m  INT           NOT NULL DEFAULT 50,
  CONSTRAINT chk_loc_lat    CHECK (latitude  BETWEEN -90  AND 90),
  CONSTRAINT chk_loc_lng    CHECK (longitude BETWEEN -180 AND 180),
  CONSTRAINT chk_loc_radius CHECK (radius_m  BETWEEN 5 AND 5000)
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
  CONSTRAINT fk_sessions_location FOREIGN KEY (location_id)
    REFERENCES locations(location_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sessions_creator FOREIGN KEY (created_by)
    REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_sessions_status CHECK (status IN ('scheduled', 'open', 'closed', 'cancelled')),
  CONSTRAINT chk_sessions_time   CHECK (
    checkin_open_at <= start_at AND start_at <= late_after AND late_after <= end_at AND end_at > start_at
  )
);

-- Snapshot peserta yang diharapkan hadir
CREATE TABLE session_participants (
  session_id BIGINT   NOT NULL,
  user_id    BIGINT   NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (session_id, user_id),
  CONSTRAINT fk_part_session FOREIGN KEY (session_id)
    REFERENCES sessions(session_id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_part_user FOREIGN KEY (user_id)
    REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE qr_tokens (
  qr_token_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  session_id BIGINT   NOT NULL,
  token_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL UNIQUE,  -- SHA-256, token asli tidak disimpan
  expires_at DATETIME NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_qr_session FOREIGN KEY (session_id)
    REFERENCES sessions(session_id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT chk_qr_expiry CHECK (expires_at > created_at),
  -- target FK gabungan dari attendance_verifications
  CONSTRAINT uq_qr_id_session UNIQUE (qr_token_id, session_id)
);

-- ---------------------------------------------------------------------
-- 4. Izin / sakit (satu pengajuan per peserta per sesi)
-- ---------------------------------------------------------------------
-- Catatan: MySQL melarang kolom yang dipakai CHECK memiliki FK dengan
-- ON UPDATE/DELETE CASCADE / SET NULL. Karena itu FK pada kolom tersebut
-- memakai ON UPDATE RESTRICT (PK tidak pernah diubah, jadi tidak berdampak).
CREATE TABLE leave_requests (
  leave_request_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  session_id     BIGINT       NOT NULL,
  user_id        BIGINT       NOT NULL,
  leave_type     VARCHAR(20)  NOT NULL,
  reason         TEXT         NOT NULL,
  attachment_url VARCHAR(500),
  status         VARCHAR(20)  NOT NULL DEFAULT 'pending',
  reviewed_by    BIGINT,
  reviewed_at    DATETIME,
  review_note    TEXT,
  CONSTRAINT fk_leave_reviewer FOREIGN KEY (reviewed_by)
    REFERENCES users(user_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  -- pemohon harus peserta sesi tersebut
  CONSTRAINT fk_leave_participant FOREIGN KEY (session_id, user_id)
    REFERENCES session_participants (session_id, user_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT uq_leave_session_user UNIQUE (session_id, user_id),
  -- target FK gabungan dari attendances
  CONSTRAINT uq_leave_id_session_user UNIQUE (leave_request_id, session_id, user_id),
  CONSTRAINT chk_leave_type   CHECK (leave_type IN ('permission', 'sick')),
  CONSTRAINT chk_leave_status CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  -- keputusan wajib mencatat peninjau dan waktu
  CONSTRAINT chk_leave_review CHECK (
    status IN ('pending', 'cancelled') OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
  ),
  -- tidak boleh menyetujui/menolak izin sendiri
  CONSTRAINT chk_leave_not_self CHECK (reviewed_by IS NULL OR reviewed_by <> user_id)
);

-- ---------------------------------------------------------------------
-- 5. Absensi dan verifikasi
-- ---------------------------------------------------------------------
CREATE TABLE attendances (
  attendance_id    BIGINT AUTO_INCREMENT PRIMARY KEY,
  session_id       BIGINT       NOT NULL,
  user_id          BIGINT       NOT NULL,
  leave_request_id BIGINT,
  status           VARCHAR(20)  NOT NULL,
  check_in_at      DATETIME,
  check_out_at     DATETIME,
  corrected_by     BIGINT,
  note             TEXT,
  CONSTRAINT fk_att_corrector FOREIGN KEY (corrected_by)
    REFERENCES users(user_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  -- hanya peserta terdaftar yang boleh punya absensi
  CONSTRAINT fk_att_participant FOREIGN KEY (session_id, user_id)
    REFERENCES session_participants (session_id, user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  -- izin yang menjadi dasar harus milik sesi dan pengguna yang sama (dilewati jika NULL)
  CONSTRAINT fk_att_leave FOREIGN KEY (leave_request_id, session_id, user_id)
    REFERENCES leave_requests (leave_request_id, session_id, user_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  -- tidak ada absensi ganda; satu izin hanya menjadi dasar satu absensi
  CONSTRAINT uq_att_session_user UNIQUE (session_id, user_id),
  CONSTRAINT uq_att_leave        UNIQUE (leave_request_id),
  -- target FK gabungan dari attendance_verifications
  CONSTRAINT uq_att_id_session   UNIQUE (attendance_id, session_id),
  CONSTRAINT chk_att_status   CHECK (status IN ('present', 'late', 'permission', 'sick', 'absent')),
  CONSTRAINT chk_att_checkout CHECK (
    check_out_at IS NULL OR (check_in_at IS NOT NULL AND check_out_at >= check_in_at)
  ),
  CONSTRAINT chk_att_checkin_status CHECK (status IN ('present', 'late') OR check_in_at IS NULL),
  -- tautan izin hanya untuk status permission/sick
  CONSTRAINT chk_att_leave_link CHECK (leave_request_id IS NULL OR status IN ('permission', 'sick')),
  -- status permission/sick wajib punya izin, kecuali koreksi manual
  CONSTRAINT chk_att_leave_required CHECK (
    status NOT IN ('permission', 'sick') OR leave_request_id IS NOT NULL OR corrected_by IS NOT NULL
  ),
  -- koreksi manual wajib punya alasan
  CONSTRAINT chk_att_correction_note CHECK (corrected_by IS NULL OR note IS NOT NULL)
);

CREATE TABLE attendance_verifications (
  attendance_verification_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  attendance_id BIGINT        NOT NULL,
  session_id    BIGINT        NOT NULL,
  qr_token_id   BIGINT,
  event_type    VARCHAR(20)   NOT NULL,
  method        VARCHAR(10)   NOT NULL,
  is_passed     BOOLEAN       NOT NULL,
  latitude      DECIMAL(9,6),
  longitude     DECIMAL(9,6),
  distance_m    DECIMAL(8,2),
  created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- kolom bantu pengganti partial index: 1 jika lolos, NULL jika gagal
  passed_flag   TINYINT GENERATED ALWAYS AS (IF(is_passed, 1, NULL)) VIRTUAL,
  CONSTRAINT fk_verif_session FOREIGN KEY (session_id)
    REFERENCES sessions(session_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  -- absensi harus berada di sesi yang sama dengan verifikasi
  CONSTRAINT fk_verif_attendance FOREIGN KEY (attendance_id, session_id)
    REFERENCES attendances (attendance_id, session_id) ON UPDATE CASCADE ON DELETE CASCADE,
  -- token QR harus milik sesi yang sama (dilewati jika NULL)
  CONSTRAINT fk_verif_qr FOREIGN KEY (qr_token_id, session_id)
    REFERENCES qr_tokens (qr_token_id, session_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_verif_event  CHECK (event_type IN ('check_in', 'check_out')),
  CONSTRAINT chk_verif_method CHECK (method IN ('qr', 'gps')),
  CONSTRAINT chk_verif_lat    CHECK (latitude   IS NULL OR latitude  BETWEEN -90  AND 90),
  CONSTRAINT chk_verif_lng    CHECK (longitude  IS NULL OR longitude BETWEEN -180 AND 180),
  CONSTRAINT chk_verif_dist   CHECK (distance_m IS NULL OR distance_m >= 0),
  CONSTRAINT chk_verif_qr     CHECK (qr_token_id IS NULL OR method = 'qr'),
  -- percobaan gagal boleh berulang; yang lolos maksimal satu per event dan metode
  CONSTRAINT uq_verif_passed UNIQUE (attendance_id, event_type, method, passed_flag)
);

-- ---------------------------------------------------------------------
-- 6. Audit log
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
  audit_log_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  user_id     BIGINT,
  action      VARCHAR(50) NOT NULL,
  entity_type VARCHAR(50) NOT NULL,
  entity_id   BIGINT,
  created_at  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_audit_user FOREIGN KEY (user_id)
    REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE RESTRICT
);

-- ---------------------------------------------------------------------
-- 7. Index
--    InnoDB otomatis membuat index untuk kolom FK, jadi index berikut
--    (yang ada di versi PostgreSQL) tidak perlu dibuat lagi:
--    users.department_id, classes.department_id, sessions.created_by,
--    session_participants.user_id, attendance_verifications.session_id,
--    attendance_verifications.attendance_id, attendance_verifications.qr_token_id
--    Partial index diganti index biasa dengan kolom status di depan/belakang.
-- ---------------------------------------------------------------------
CREATE INDEX idx_users_role_status     ON users (role_id, status);
CREATE INDEX idx_enrollments_class     ON class_enrollments (class_id, is_active);

CREATE INDEX idx_sessions_start        ON sessions (start_at);
CREATE INDEX idx_sessions_active       ON sessions (status, start_at);
CREATE INDEX idx_qr_session_expiry     ON qr_tokens (session_id, expires_at DESC);

CREATE INDEX idx_leave_pending         ON leave_requests (session_id, status);
CREATE INDEX idx_leave_reviewer        ON leave_requests (reviewed_by, reviewed_at DESC);
CREATE INDEX idx_leave_user            ON leave_requests (user_id);

CREATE INDEX idx_att_user_session      ON attendances (user_id, session_id);
CREATE INDEX idx_att_session_status    ON attendances (session_id, status);
CREATE INDEX idx_att_checkin           ON attendances (check_in_at);

CREATE INDEX idx_audit_user_time       ON audit_logs (user_id, created_at DESC);
CREATE INDEX idx_audit_entity          ON audit_logs (entity_type, entity_id);
CREATE INDEX idx_audit_time            ON audit_logs (created_at DESC);

-- ---------------------------------------------------------------------
-- 8. Trigger: validasi status absensi terhadap jadwal dan izin
--    (CHECK tidak bisa lintas tabel, jadi memakai trigger)
--    Koreksi manual (corrected_by terisi) dilewati.
--    MySQL tidak punya trigger multi-event, jadi logika ditaruh di
--    stored procedure dan dipanggil dari trigger INSERT dan UPDATE.
-- ---------------------------------------------------------------------
DELIMITER $$

CREATE PROCEDURE sp_validate_attendance(
  IN p_session_id       BIGINT,
  IN p_status           VARCHAR(20),
  IN p_check_in_at      DATETIME,
  IN p_leave_request_id BIGINT,
  IN p_corrected_by     BIGINT
)
BEGIN
  DECLARE v_sess_status  VARCHAR(20);
  DECLARE v_open_at      DATETIME;
  DECLARE v_late_after   DATETIME;
  DECLARE v_end_at       DATETIME;
  DECLARE v_leave_status VARCHAR(20);
  DECLARE v_leave_type   VARCHAR(20);

  IF p_corrected_by IS NULL THEN

    SELECT status, checkin_open_at, late_after, end_at
      INTO v_sess_status, v_open_at, v_late_after, v_end_at
      FROM sessions
     WHERE session_id = p_session_id;

    IF p_check_in_at IS NOT NULL THEN
      IF v_sess_status <> 'open' THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'check-in ditolak: sesi tidak sedang dibuka';
      END IF;
      IF p_check_in_at < v_open_at OR p_check_in_at > v_end_at THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'check-in ditolak: di luar jendela sesi';
      END IF;
      IF p_status = 'late' AND p_check_in_at <= v_late_after THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'status late tidak valid: check-in belum melewati batas toleransi';
      END IF;
      IF p_status = 'present' AND p_check_in_at > v_late_after THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'status present tidak valid: check-in sudah melewati batas toleransi';
      END IF;
    END IF;

    IF p_leave_request_id IS NOT NULL THEN
      SELECT status, leave_type
        INTO v_leave_status, v_leave_type
        FROM leave_requests
       WHERE leave_request_id = p_leave_request_id;

      IF v_leave_status <> 'approved' THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'izin belum disetujui';
      END IF;
      IF (p_status = 'sick' AND v_leave_type <> 'sick')
      OR (p_status = 'permission' AND v_leave_type <> 'permission') THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'status absensi tidak cocok dengan jenis izin';
      END IF;
    END IF;

  END IF;
END$$

CREATE TRIGGER trg_att_validate_ins
  BEFORE INSERT ON attendances
  FOR EACH ROW
BEGIN
  CALL sp_validate_attendance(NEW.session_id, NEW.status, NEW.check_in_at,
                              NEW.leave_request_id, NEW.corrected_by);
END$$

-- hanya divalidasi jika kolom yang relevan berubah (setara UPDATE OF di PostgreSQL)
CREATE TRIGGER trg_att_validate_upd
  BEFORE UPDATE ON attendances
  FOR EACH ROW
BEGIN
  IF NOT (OLD.status           <=> NEW.status
      AND OLD.check_in_at      <=> NEW.check_in_at
      AND OLD.leave_request_id <=> NEW.leave_request_id
      AND OLD.corrected_by     <=> NEW.corrected_by) THEN
    CALL sp_validate_attendance(NEW.session_id, NEW.status, NEW.check_in_at,
                                NEW.leave_request_id, NEW.corrected_by);
  END IF;
END$$

-- ---------------------------------------------------------------------
-- 9. Trigger: audit_logs hanya boleh ditambah (append-only)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_audit_no_update
  BEFORE UPDATE ON audit_logs
  FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'audit_logs bersifat append-only (UPDATE ditolak)';
END$$

CREATE TRIGGER trg_audit_no_delete
  BEFORE DELETE ON audit_logs
  FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'audit_logs bersifat append-only (DELETE ditolak)';
END$$

DELIMITER ;

-- MySQL tidak punya trigger TRUNCATE, dan TRUNCATE tidak memicu trigger DELETE.
-- Cegah lewat hak akses: jalankan setelah user aplikasi dibuat
-- (ganti app_user dan host sesuai milik Anda). TRUNCATE butuh hak DROP.
-- REVOKE UPDATE, DELETE, DROP ON absensi.audit_logs FROM 'app_user'@'%';
