-- =============================================================================
-- PEARL – Patient-Doctor Appointment Management Platform
-- Production-Grade PostgreSQL Schema
-- Version: 1.0.0
-- Architecture: 3NF Normalized, UUID PKs, Soft-Delete, Audit Fields
-- Target Scale: 1M users | 100K appointments/day
-- =============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";     -- for full-text/trigram search on doctor names
CREATE EXTENSION IF NOT EXISTS "btree_gin";   -- composite GIN indexes

-- =============================================================================
-- SECTION 1: ENUM TYPES
-- =============================================================================

CREATE TYPE user_role AS ENUM ('PATIENT', 'DOCTOR', 'ADMIN');

CREATE TYPE user_status AS ENUM ('PENDING_VERIFICATION', 'ACTIVE', 'SUSPENDED', 'DEACTIVATED');

CREATE TYPE auth_provider AS ENUM ('EMAIL', 'GOOGLE', 'PHONE');

CREATE TYPE verification_token_type AS ENUM (
  'EMAIL_VERIFICATION',
  'PHONE_OTP',
  'PASSWORD_RESET',
  'DOCTOR_CREDENTIAL_APPROVAL'
);

CREATE TYPE doctor_verification_status AS ENUM (
  'PENDING',
  'UNDER_REVIEW',
  'APPROVED',
  'REJECTED'
);

CREATE TYPE appointment_status AS ENUM (
  'SCHEDULED',
  'CONFIRMED',
  'CANCELLED_BY_PATIENT',
  'CANCELLED_BY_DOCTOR',
  'COMPLETED',
  'NO_SHOW',
  'RESCHEDULED'
);

CREATE TYPE slot_status AS ENUM ('AVAILABLE', 'BOOKED', 'BLOCKED', 'EXPIRED');

CREATE TYPE day_of_week AS ENUM (
  'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
  'FRIDAY', 'SATURDAY', 'SUNDAY'
);

CREATE TYPE notification_type AS ENUM (
  'APPOINTMENT_CONFIRMED',
  'APPOINTMENT_CANCELLED',
  'APPOINTMENT_RESCHEDULED',
  'APPOINTMENT_REMINDER',
  'SLOT_FREED',
  'DOCTOR_APPROVED',
  'GENERAL'
);

CREATE TYPE notification_channel AS ENUM ('EMAIL', 'SMS', 'PUSH', 'IN_APP');

CREATE TYPE notification_status AS ENUM ('PENDING', 'SENT', 'FAILED', 'READ');

CREATE TYPE engagement_action AS ENUM (
  'APPOINTMENT_BOOKED',
  'APPOINTMENT_CANCELLED',
  'APPOINTMENT_RESCHEDULED',
  'NOTIFICATION_READ',
  'PROFILE_UPDATED',
  'DOCTOR_SEARCHED',
  'SLOT_VIEWED'
);

CREATE TYPE cancellation_reason AS ENUM (
  'PATIENT_REQUEST',
  'DOCTOR_UNAVAILABLE',
  'EMERGENCY',
  'DUPLICATE_BOOKING',
  'OTHER'
);

-- =============================================================================
-- SECTION 2: CORE USER & AUTHENTICATION TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 users
-- Central identity table. One record per unique human.
-- Supports email, phone, and Google OAuth providers.
-- -----------------------------------------------------------------------------
CREATE TABLE users (
  id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  email             VARCHAR(255)  UNIQUE,
  phone             VARCHAR(20)   UNIQUE,
  google_id         VARCHAR(255)  UNIQUE,
  password_hash     VARCHAR(255),                          -- NULL for Google-only accounts
  role              user_role     NOT NULL,
  status            user_status   NOT NULL DEFAULT 'PENDING_VERIFICATION',
  auth_provider     auth_provider NOT NULL DEFAULT 'EMAIL',
  is_email_verified BOOLEAN       NOT NULL DEFAULT FALSE,
  is_phone_verified BOOLEAN       NOT NULL DEFAULT FALSE,
  last_login_at     TIMESTAMPTZ,
  deleted_at        TIMESTAMPTZ,                           -- soft delete
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- At least one of email, phone, or google_id must be present
  CONSTRAINT chk_users_identity CHECK (
    email IS NOT NULL OR phone IS NOT NULL OR google_id IS NOT NULL
  ),
  -- Password is only required for non-OAuth email accounts
  CONSTRAINT chk_users_password CHECK (
    auth_provider = 'GOOGLE' OR password_hash IS NOT NULL OR phone IS NOT NULL
  )
);

-- -----------------------------------------------------------------------------
-- 2.2 verification_tokens
-- Stores OTP / email verification / password-reset tokens.
-- Design: short-lived, single-use, indexed for fast lookup.
-- -----------------------------------------------------------------------------
CREATE TABLE verification_tokens (
  id           UUID                    PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID                    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token        VARCHAR(512)            NOT NULL,
  token_type   verification_token_type NOT NULL,
  expires_at   TIMESTAMPTZ             NOT NULL,
  used_at      TIMESTAMPTZ,                              -- NULL = not used yet
  ip_address   INET,                                     -- for audit / abuse detection
  created_at   TIMESTAMPTZ             NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_token_not_expired_on_use CHECK (
    used_at IS NULL OR used_at <= expires_at
  )
);

-- =============================================================================
-- SECTION 3: PROFILE TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 patients
-- Extended patient data linked to users (1:1).
-- -----------------------------------------------------------------------------
CREATE TABLE patients (
  id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID         NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  first_name      VARCHAR(100) NOT NULL,
  last_name       VARCHAR(100) NOT NULL,
  date_of_birth   DATE,
  gender          VARCHAR(20),
  blood_group     VARCHAR(5),
  address         TEXT,
  emergency_contact_name  VARCHAR(200),
  emergency_contact_phone VARCHAR(20),
  profile_photo_url        TEXT,
  medical_history TEXT,                  -- free-form, could be JSON in v2
  deleted_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 3.2 doctors
-- Extended doctor data (1:1 with users). Holds professional credentials.
-- -----------------------------------------------------------------------------
CREATE TABLE doctors (
  id                      UUID                      PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                 UUID                      NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  first_name              VARCHAR(100)              NOT NULL,
  last_name               VARCHAR(100)              NOT NULL,
  bio                     TEXT,
  years_of_experience     SMALLINT                  DEFAULT 0,
  consultation_fee        NUMERIC(10, 2)            NOT NULL DEFAULT 0,
  currency                CHAR(3)                   NOT NULL DEFAULT 'INR',
  profile_photo_url       TEXT,
  license_number          VARCHAR(100)              UNIQUE,
  license_document_url    TEXT,
  verification_status     doctor_verification_status NOT NULL DEFAULT 'PENDING',
  verified_at             TIMESTAMPTZ,
  verified_by             UUID                      REFERENCES users(id),  -- Admin who verified
  avg_rating              NUMERIC(3, 2)             DEFAULT 0.00,
  total_reviews           INTEGER                   DEFAULT 0,
  is_accepting_patients   BOOLEAN                   NOT NULL DEFAULT TRUE,
  deleted_at              TIMESTAMPTZ,
  created_at              TIMESTAMPTZ               NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ               NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_consultation_fee CHECK (consultation_fee >= 0),
  CONSTRAINT chk_avg_rating CHECK (avg_rating BETWEEN 0 AND 5)
);

-- -----------------------------------------------------------------------------
-- 3.3 specializations
-- Lookup table for medical specializations.
-- -----------------------------------------------------------------------------
CREATE TABLE specializations (
  id          UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  name        VARCHAR(150) NOT NULL UNIQUE,
  slug        VARCHAR(150) NOT NULL UNIQUE,  -- URL-friendly: 'general-physician'
  description TEXT,
  icon_url    TEXT,
  is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 3.4 doctor_specializations (junction)
-- Many-to-many: one doctor can have multiple specializations.
-- Primary specialization flag allows ordering.
-- -----------------------------------------------------------------------------
CREATE TABLE doctor_specializations (
  id                UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  doctor_id         UUID        NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  specialization_id UUID        NOT NULL REFERENCES specializations(id) ON DELETE RESTRICT,
  is_primary        BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_doctor_specialization UNIQUE (doctor_id, specialization_id)
);

-- =============================================================================
-- SECTION 4: AVAILABILITY & SCHEDULING TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 availability_schedule
-- Defines a doctor's recurring weekly availability.
-- This is the "template" from which slots are generated.
-- -----------------------------------------------------------------------------
CREATE TABLE availability_schedule (
  id                UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  doctor_id         UUID        NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  day_of_week       day_of_week NOT NULL,
  start_time        TIME        NOT NULL,
  end_time          TIME        NOT NULL,
  slot_duration_min SMALLINT    NOT NULL DEFAULT 30,  -- minutes per slot
  max_patients      SMALLINT    NOT NULL DEFAULT 1,   -- simultaneous patients per slot
  is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
  effective_from    DATE        NOT NULL DEFAULT CURRENT_DATE,
  effective_until   DATE,                             -- NULL = indefinite
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_schedule_time CHECK (end_time > start_time),
  CONSTRAINT chk_slot_duration CHECK (slot_duration_min BETWEEN 5 AND 240),
  CONSTRAINT chk_max_patients CHECK (max_patients BETWEEN 1 AND 50)
);

-- -----------------------------------------------------------------------------
-- 4.2 slots
-- Concrete time slots derived from availability_schedule.
-- These are the actual bookable units for a specific date.
-- -----------------------------------------------------------------------------
CREATE TABLE slots (
  id                UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  doctor_id         UUID        NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  schedule_id       UUID        REFERENCES availability_schedule(id) ON DELETE SET NULL,
  slot_date         DATE        NOT NULL,
  start_time        TIME        NOT NULL,
  end_time          TIME        NOT NULL,
  max_capacity      SMALLINT    NOT NULL DEFAULT 1,
  booked_count      SMALLINT    NOT NULL DEFAULT 0,
  status            slot_status NOT NULL DEFAULT 'AVAILABLE',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_slot_doctor_datetime UNIQUE (doctor_id, slot_date, start_time),
  CONSTRAINT chk_slot_time CHECK (end_time > start_time),
  CONSTRAINT chk_booked_count CHECK (booked_count >= 0 AND booked_count <= max_capacity)
);

-- -----------------------------------------------------------------------------
-- 4.3 elastic_slots
-- Allows doctors to extend/override their normal schedule for specific dates.
-- Handles overflow, special hours, holiday blocking, etc.
-- -----------------------------------------------------------------------------
CREATE TABLE elastic_slots (
  id                UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  doctor_id         UUID        NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  slot_date         DATE        NOT NULL,
  start_time        TIME        NOT NULL,
  end_time          TIME        NOT NULL,
  max_capacity      SMALLINT    NOT NULL DEFAULT 1,
  reason            TEXT,               -- 'Holiday extension', 'Conference', etc.
  is_blocked        BOOLEAN     NOT NULL DEFAULT FALSE, -- TRUE = doctor unavailable
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_elastic_slot UNIQUE (doctor_id, slot_date, start_time),
  CONSTRAINT chk_elastic_time CHECK (end_time > start_time)
);

-- -----------------------------------------------------------------------------
-- 4.4 slot_allocations
-- Tracks individual patient allocations within a slot (for multi-patient slots).
-- One record per patient per slot.
-- -----------------------------------------------------------------------------
CREATE TABLE slot_allocations (
  id             UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  slot_id        UUID        NOT NULL REFERENCES slots(id) ON DELETE CASCADE,
  appointment_id UUID,                                  -- FK set after appointment creation
  patient_id     UUID        NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
  queue_position SMALLINT    NOT NULL DEFAULT 1,        -- ordering within the slot
  allocated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  released_at    TIMESTAMPTZ,                            -- NULL = still allocated

  CONSTRAINT uq_slot_patient UNIQUE (slot_id, patient_id)
);

-- =============================================================================
-- SECTION 5: APPOINTMENT TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 appointments
-- Core booking record. Immutable intent; status tracks lifecycle.
-- Partitioned by slot_date for scale (see partitioning strategy in docs).
-- -----------------------------------------------------------------------------
CREATE TABLE appointments (
  id                 UUID               PRIMARY KEY DEFAULT uuid_generate_v4(),
  patient_id         UUID               NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
  doctor_id          UUID               NOT NULL REFERENCES doctors(id) ON DELETE RESTRICT,
  slot_id            UUID               NOT NULL REFERENCES slots(id) ON DELETE RESTRICT,
  elastic_slot_id    UUID               REFERENCES elastic_slots(id) ON DELETE SET NULL,
  appointment_date   DATE               NOT NULL,
  start_time         TIME               NOT NULL,
  end_time           TIME               NOT NULL,
  status             appointment_status NOT NULL DEFAULT 'SCHEDULED',
  cancellation_reason cancellation_reason,
  cancellation_note  TEXT,
  cancelled_by       UUID               REFERENCES users(id),
  cancelled_at       TIMESTAMPTZ,
  consultation_fee   NUMERIC(10, 2)     NOT NULL DEFAULT 0,
  notes              TEXT,               -- doctor pre-consultation notes
  deleted_at         TIMESTAMPTZ,
  created_at         TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ        NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_appointment_time CHECK (end_time > start_time),
  CONSTRAINT chk_cancel_fields CHECK (
    (status NOT IN ('CANCELLED_BY_PATIENT','CANCELLED_BY_DOCTOR')) OR
    (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL)
  )
);

-- Add FK from slot_allocations → appointments (circular dependency resolved post-table creation)
ALTER TABLE slot_allocations
  ADD CONSTRAINT fk_slot_alloc_appointment
  FOREIGN KEY (appointment_id) REFERENCES appointments(id) ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- 5.2 reschedule_history
-- Immutable audit log of every reschedule action on an appointment.
-- -----------------------------------------------------------------------------
CREATE TABLE reschedule_history (
  id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  appointment_id      UUID        NOT NULL REFERENCES appointments(id) ON DELETE CASCADE,
  rescheduled_by      UUID        NOT NULL REFERENCES users(id),
  old_slot_id         UUID        REFERENCES slots(id) ON DELETE SET NULL,
  new_slot_id         UUID        REFERENCES slots(id) ON DELETE SET NULL,
  old_appointment_date DATE       NOT NULL,
  new_appointment_date DATE       NOT NULL,
  old_start_time      TIME        NOT NULL,
  new_start_time      TIME        NOT NULL,
  reason              TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 6: NOTIFICATIONS & ENGAGEMENT TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 notifications
-- Stores every notification generated by the system.
-- Delivery is handled by a queue (BullMQ); status tracked here.
-- -----------------------------------------------------------------------------
CREATE TABLE notifications (
  id                UUID                PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID                NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  appointment_id    UUID                REFERENCES appointments(id) ON DELETE SET NULL,
  type              notification_type   NOT NULL,
  channel           notification_channel NOT NULL,
  status            notification_status NOT NULL DEFAULT 'PENDING',
  title             VARCHAR(255)        NOT NULL,
  body              TEXT                NOT NULL,
  metadata          JSONB               DEFAULT '{}', -- template vars, deep-links, etc.
  scheduled_at      TIMESTAMPTZ,                      -- for reminder scheduling
  sent_at           TIMESTAMPTZ,
  read_at           TIMESTAMPTZ,
  failed_reason     TEXT,
  retry_count       SMALLINT            NOT NULL DEFAULT 0,
  deleted_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 6.2 engagement_history
-- Tracks every significant user action for analytics and re-engagement.
-- Append-only table (no updates).
-- -----------------------------------------------------------------------------
CREATE TABLE engagement_history (
  id             UUID              PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id        UUID              NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  action         engagement_action NOT NULL,
  entity_type    VARCHAR(50),               -- 'appointment', 'slot', 'doctor', etc.
  entity_id      UUID,                      -- FK-less for flexibility across entity types
  metadata       JSONB             DEFAULT '{}',
  ip_address     INET,
  user_agent     TEXT,
  created_at     TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 7: ANALYTICS TABLE
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 7.1 analytics
-- Pre-aggregated analytics snapshots per doctor per day.
-- Updated by a daily scheduled job (cron / BullMQ).
-- Row per doctor per date for efficient doctor-side dashboard queries.
-- -----------------------------------------------------------------------------
CREATE TABLE analytics (
  id                        UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  doctor_id                 UUID        NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  date                      DATE        NOT NULL,
  total_slots               INTEGER     NOT NULL DEFAULT 0,
  booked_slots              INTEGER     NOT NULL DEFAULT 0,
  available_slots           INTEGER     NOT NULL DEFAULT 0,
  cancelled_slots           INTEGER     NOT NULL DEFAULT 0,
  completed_appointments    INTEGER     NOT NULL DEFAULT 0,
  no_show_count             INTEGER     NOT NULL DEFAULT 0,
  total_revenue             NUMERIC(12, 2) NOT NULL DEFAULT 0,
  slot_utilization_pct      NUMERIC(5, 2)  GENERATED ALWAYS AS (
    CASE WHEN total_slots = 0 THEN 0
         ELSE ROUND((booked_slots::NUMERIC / total_slots) * 100, 2)
    END
  ) STORED,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_analytics_doctor_date UNIQUE (doctor_id, date),
  CONSTRAINT chk_analytics_counts CHECK (
    booked_slots >= 0 AND available_slots >= 0 AND total_slots >= 0
  )
);

-- =============================================================================
-- SECTION 8: INDEXES
-- =============================================================================

-- ----- users -----
CREATE INDEX idx_users_email        ON users(email)     WHERE deleted_at IS NULL;
CREATE INDEX idx_users_phone        ON users(phone)     WHERE deleted_at IS NULL;
CREATE INDEX idx_users_google_id    ON users(google_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_role_status  ON users(role, status) WHERE deleted_at IS NULL;

-- ----- verification_tokens -----
CREATE INDEX idx_vt_user_type       ON verification_tokens(user_id, token_type);
CREATE INDEX idx_vt_token           ON verification_tokens(token);
CREATE INDEX idx_vt_expires         ON verification_tokens(expires_at) WHERE used_at IS NULL;

-- ----- patients -----
CREATE INDEX idx_patients_user_id   ON patients(user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_patients_name_trgm ON patients USING GIN (
  (first_name || ' ' || last_name) gin_trgm_ops
);

-- ----- doctors -----
CREATE INDEX idx_doctors_user_id      ON doctors(user_id)            WHERE deleted_at IS NULL;
CREATE INDEX idx_doctors_verification ON doctors(verification_status) WHERE deleted_at IS NULL;
CREATE INDEX idx_doctors_accepting    ON doctors(is_accepting_patients, avg_rating DESC)
  WHERE deleted_at IS NULL AND verification_status = 'APPROVED';
CREATE INDEX idx_doctors_name_trgm    ON doctors USING GIN (
  (first_name || ' ' || last_name) gin_trgm_ops
);

-- ----- doctor_specializations -----
CREATE INDEX idx_ds_doctor_id         ON doctor_specializations(doctor_id);
CREATE INDEX idx_ds_specialization_id ON doctor_specializations(specialization_id);

-- ----- specializations -----
CREATE INDEX idx_spec_slug            ON specializations(slug) WHERE is_active = TRUE;

-- ----- availability_schedule -----
CREATE INDEX idx_avail_doctor_day     ON availability_schedule(doctor_id, day_of_week)
  WHERE is_active = TRUE;

-- ----- slots -----
CREATE INDEX idx_slots_doctor_date        ON slots(doctor_id, slot_date, status);
CREATE INDEX idx_slots_doctor_date_time   ON slots(doctor_id, slot_date, start_time)
  WHERE status = 'AVAILABLE';
CREATE INDEX idx_slots_schedule           ON slots(schedule_id);
-- Composite index for patient availability search
CREATE INDEX idx_slots_search             ON slots(slot_date, status, doctor_id)
  WHERE status = 'AVAILABLE';

-- ----- elastic_slots -----
CREATE INDEX idx_elastic_doctor_date      ON elastic_slots(doctor_id, slot_date);

-- ----- slot_allocations -----
CREATE INDEX idx_alloc_slot_id            ON slot_allocations(slot_id);
CREATE INDEX idx_alloc_patient_id         ON slot_allocations(patient_id);
CREATE INDEX idx_alloc_appointment_id     ON slot_allocations(appointment_id);

-- ----- appointments -----
CREATE INDEX idx_apt_patient_id           ON appointments(patient_id)      WHERE deleted_at IS NULL;
CREATE INDEX idx_apt_doctor_id            ON appointments(doctor_id)        WHERE deleted_at IS NULL;
CREATE INDEX idx_apt_slot_id              ON appointments(slot_id)          WHERE deleted_at IS NULL;
CREATE INDEX idx_apt_status               ON appointments(status)           WHERE deleted_at IS NULL;
CREATE INDEX idx_apt_doctor_date_status   ON appointments(doctor_id, appointment_date, status)
  WHERE deleted_at IS NULL;
CREATE INDEX idx_apt_patient_date         ON appointments(patient_id, appointment_date DESC)
  WHERE deleted_at IS NULL;
-- For scheduler / reminder jobs
CREATE INDEX idx_apt_reminder             ON appointments(appointment_date, start_time, status)
  WHERE status = 'SCHEDULED' AND deleted_at IS NULL;

-- ----- reschedule_history -----
CREATE INDEX idx_rh_appointment_id        ON reschedule_history(appointment_id);
CREATE INDEX idx_rh_created_at            ON reschedule_history(created_at DESC);

-- ----- notifications -----
CREATE INDEX idx_notif_user_id            ON notifications(user_id)         WHERE deleted_at IS NULL;
CREATE INDEX idx_notif_status             ON notifications(status)           WHERE deleted_at IS NULL;
CREATE INDEX idx_notif_scheduled          ON notifications(scheduled_at)
  WHERE status = 'PENDING' AND deleted_at IS NULL;
CREATE INDEX idx_notif_appointment        ON notifications(appointment_id)   WHERE deleted_at IS NULL;

-- ----- engagement_history -----
CREATE INDEX idx_eng_user_id              ON engagement_history(user_id);
CREATE INDEX idx_eng_action               ON engagement_history(action, created_at DESC);
CREATE INDEX idx_eng_entity               ON engagement_history(entity_type, entity_id);

-- ----- analytics -----
CREATE INDEX idx_analytics_doctor_date    ON analytics(doctor_id, date DESC);

-- =============================================================================
-- SECTION 9: TRIGGER FUNCTIONS – AUTO-UPDATE updated_at
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to all tables with updated_at
DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'users', 'patients', 'doctors', 'specializations',
    'availability_schedule', 'slots', 'elastic_slots',
    'appointments', 'notifications', 'analytics'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated_at
       BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();',
      tbl, tbl
    );
  END LOOP;
END;
$$;

-- =============================================================================
-- SECTION 10: TRIGGER – ATOMIC SLOT BOOKING (Race Condition Prevention)
-- =============================================================================

-- This trigger enforces slot capacity atomically using SELECT FOR UPDATE NO WAIT
-- in the application layer (see booking service). The trigger is a safety net.
CREATE OR REPLACE FUNCTION fn_check_slot_capacity()
RETURNS TRIGGER AS $$
DECLARE
  v_max  SMALLINT;
  v_booked SMALLINT;
BEGIN
  -- Lock the slot row for this transaction
  SELECT max_capacity, booked_count
  INTO v_max, v_booked
  FROM slots
  WHERE id = NEW.slot_id
  FOR UPDATE;

  IF v_booked >= v_max THEN
    RAISE EXCEPTION 'SLOT_FULL: Slot % has reached maximum capacity of %', NEW.slot_id, v_max;
  END IF;

  -- Increment booked count atomically
  UPDATE slots
  SET booked_count = booked_count + 1,
      status = CASE WHEN booked_count + 1 >= max_capacity THEN 'BOOKED' ELSE status END,
      updated_at = NOW()
  WHERE id = NEW.slot_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_slot_allocation_capacity
  BEFORE INSERT ON slot_allocations
  FOR EACH ROW EXECUTE FUNCTION fn_check_slot_capacity();

-- Trigger to release slot capacity on deallocation
CREATE OR REPLACE FUNCTION fn_release_slot_capacity()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.released_at IS NOT NULL AND OLD.released_at IS NULL THEN
    UPDATE slots
    SET booked_count = GREATEST(0, booked_count - 1),
        status = CASE
          WHEN status = 'BOOKED' AND booked_count - 1 < max_capacity THEN 'AVAILABLE'
          ELSE status
        END,
        updated_at = NOW()
    WHERE id = NEW.slot_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_slot_release_capacity
  AFTER UPDATE OF released_at ON slot_allocations
  FOR EACH ROW EXECUTE FUNCTION fn_release_slot_capacity();

-- =============================================================================
-- SECTION 11: SEED DATA – Specializations
-- =============================================================================

INSERT INTO specializations (id, name, slug, description) VALUES
  (uuid_generate_v4(), 'General Physician',        'general-physician',       'General medicine and primary care'),
  (uuid_generate_v4(), 'Cardiologist',              'cardiologist',            'Heart and cardiovascular system'),
  (uuid_generate_v4(), 'Dermatologist',             'dermatologist',           'Skin, hair, and nail conditions'),
  (uuid_generate_v4(), 'Orthopedic Surgeon',        'orthopedic-surgeon',      'Bones, joints, and muscles'),
  (uuid_generate_v4(), 'Pediatrician',              'pediatrician',            'Child health and development'),
  (uuid_generate_v4(), 'Neurologist',               'neurologist',             'Brain and nervous system'),
  (uuid_generate_v4(), 'Gynecologist',              'gynecologist',            'Women's reproductive health'),
  (uuid_generate_v4(), 'Psychiatrist',              'psychiatrist',            'Mental health and disorders'),
  (uuid_generate_v4(), 'ENT Specialist',            'ent-specialist',          'Ear, nose, and throat'),
  (uuid_generate_v4(), 'Ophthalmologist',           'ophthalmologist',         'Eye care and vision'),
  (uuid_generate_v4(), 'Endocrinologist',           'endocrinologist',         'Hormones and diabetes'),
  (uuid_generate_v4(), 'Gastroenterologist',        'gastroenterologist',      'Digestive system'),
  (uuid_generate_v4(), 'Pulmonologist',             'pulmonologist',           'Lungs and respiratory system'),
  (uuid_generate_v4(), 'Nephrologist',              'nephrologist',            'Kidney health'),
  (uuid_generate_v4(), 'Oncologist',                'oncologist',              'Cancer diagnosis and treatment');

-- =============================================================================
-- SECTION 12: VIEWS (Convenience Read-Optimized)
-- =============================================================================

-- Active doctors with their primary specialization (used in search)
CREATE VIEW v_doctor_search AS
SELECT
  d.id                    AS doctor_id,
  d.first_name,
  d.last_name,
  d.avg_rating,
  d.total_reviews,
  d.consultation_fee,
  d.currency,
  d.years_of_experience,
  d.is_accepting_patients,
  d.profile_photo_url,
  s.id                    AS primary_specialization_id,
  s.name                  AS specialization_name,
  s.slug                  AS specialization_slug,
  u.email,
  u.phone
FROM doctors d
JOIN users u           ON u.id = d.user_id
JOIN doctor_specializations ds ON ds.doctor_id = d.id AND ds.is_primary = TRUE
JOIN specializations s ON s.id = ds.specialization_id
WHERE d.deleted_at IS NULL
  AND d.verification_status = 'APPROVED'
  AND d.is_accepting_patients = TRUE
  AND u.status = 'ACTIVE';

-- Upcoming appointments for notification/reminder jobs
CREATE VIEW v_upcoming_appointments AS
SELECT
  a.id                AS appointment_id,
  a.appointment_date,
  a.start_time,
  a.status,
  p.user_id           AS patient_user_id,
  pa.first_name       AS patient_first_name,
  pa.last_name        AS patient_last_name,
  d.user_id           AS doctor_user_id,
  doc.first_name      AS doctor_first_name,
  doc.last_name       AS doctor_last_name
FROM appointments a
JOIN patients pa ON pa.id = a.patient_id
JOIN users p    ON p.id  = pa.user_id
JOIN doctors doc ON doc.id = a.doctor_id
JOIN users d    ON d.id  = doc.user_id
WHERE a.deleted_at IS NULL
  AND a.status = 'SCHEDULED'
  AND a.appointment_date >= CURRENT_DATE;

-- =============================================================================
-- END OF SCHEMA
-- =============================================================================
