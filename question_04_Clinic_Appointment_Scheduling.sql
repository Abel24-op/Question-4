-- (a) Tables and seed data
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  TEXT NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT chk_appointments_valid_slot
        CHECK (slot_time IN (TIME '09:00:00', TIME '10:00:00', TIME '11:00:00', TIME '12:00:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cnt INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_cnt
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN COALESCE(v_cnt, 0);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION tf_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments
            WHERE doctor_id = NEW.doctor_id
              AND appointment_day = NEW.appointment_day
              AND slot_time = NEW.slot_time
              AND status <> 'CANCELLED'
              AND (TG_OP = 'INSERT' OR appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Clash detected for doctor %, date %, slot %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION tf_appointments_no_clash();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % cannot be in the past', p_day;
    END IF;

    IF p_slot NOT IN (TIME '09:00:00', TIME '10:00:00', TIME '11:00:00', TIME '12:00:00') THEN
        RAISE EXCEPTION 'Unsupported slot_time %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Seed 3 patients, 3 doctors, and 6 non-clashing appointments
INSERT INTO patients (full_name) VALUES
    ('Natasha Mwape'),
    ('Joseph Kasonde'),
    ('Faith Sichone');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Chilufya Mbewe'),
    ('Dr. Sampa Kapambwe'),
    ('Dr. Temwani Phiri');

CALL pr_book_appointment(1, 1, CURRENT_DATE, TIME '09:00:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE, TIME '10:00:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE, TIME '09:00:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, TIME '11:00:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, TIME '12:00:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, TIME '09:00:00');

-- (e) View
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- (f) Index, query, and plan
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

-- Justification: A non-unique composite index on (appointment_day, doctor_id) speeds up
-- daily doctor schedule lookups while allowing multiple slots per doctor on the same day.
EXPLAIN (ANALYZE, BUFFERS)
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- (g) Procedure and scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked    INTEGER;
    v_attended  INTEGER;
    v_cancelled INTEGER;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, COALESCE(v_booked, 0), COALESCE(v_attended, 0), COALESCE(v_cancelled, 0))
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- pg_cron daily at 01:00 for the previous day
SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary((CURRENT_DATE - INTERVAL '1 day')::DATE);$$
);