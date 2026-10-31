-- AAROGYA DRISHTI - complete PostgreSQL schema v3 (synthetic data only, NOT FOR CLINICAL USE)
-- Requires PostgreSQL 13+. Run:  psql -d <db> -v ON_ERROR_STOP=1 -f ALL_IN_ONE.sql
BEGIN;

-- >>> 00_extensions_and_types.sql
-- 00_extensions_and_types.sql  | Run first.
-- AAROGYA DRISHTI - SYNTHETIC DATA ONLY - NOT FOR CLINICAL USE
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- needed by the slot-overlap exclusion constraint
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- crypt()/gen_salt(): used ONLY by the demo seed

-- Application-generated identifiers
CREATE SEQUENCE seq_patient_code     START 1;
CREATE SEQUENCE seq_referral_code    START 1;
CREATE SEQUENCE seq_ai_analysis_code START 1;

CREATE TYPE user_status          AS ENUM ('ACTIVE','SUSPENDED','DISABLED');
CREATE TYPE registration_status AS ENUM ('PENDING','APPROVED','REJECTED');
CREATE TYPE sex_type             AS ENUM ('FEMALE','MALE','OTHER','UNDISCLOSED');
CREATE TYPE facility_type        AS ENUM ('PHC','HOSPITAL','SCREENING_SITE','DISTRICT_OFFICE');
CREATE TYPE case_state           AS ENUM ('DRAFT','CONSENTED','SCREENED','AWAITING_CLINICIAN','REVIEWED',
                                          'REFERRAL_PLANNED','APPOINTED','ASSESSED','DIAGNOSTICS_PENDING',
                                          'RESULT_REVIEWED','CARE_LINKED','CLOSED',
                                          'RESCHEDULED','MISSED','DECLINED','LOST_CONTACT');
CREATE TYPE history_type         AS ENUM ('EXPOSURE','CONDITION','PRIOR_SCREENING','PRIOR_REFERRAL');
CREATE TYPE consent_method       AS ENUM ('CHECKBOX','VERBAL_WITNESSED','SIGNATURE','THUMBPRINT');
CREATE TYPE duplicate_status     AS ENUM ('OPEN','CONFIRMED_DUPLICATE','NOT_DUPLICATE');
CREATE TYPE finding_type         AS ENUM ('SYMPTOM','EXAM');
CREATE TYPE oral_view            AS ENUM ('CHEEK_LINING','TONGUE','PALATE','GUMS','FLOOR_OF_MOUTH','OTHER');
CREATE TYPE photo_status         AS ENUM ('UPLOADED','QUALITY_FAILED','ACCEPTED','SUPERSEDED');
CREATE TYPE quality_status       AS ENUM ('ACCEPTABLE','RECAPTURE');
CREATE TYPE ai_status            AS ENUM ('QUEUED','COMPLETED','FAILED','UNAVAILABLE');
-- the three demonstration states required by the problem statement (Module C)
CREATE TYPE ai_result_label      AS ENUM ('IMAGE_INSUFFICIENT','SUSPICIOUS_FOR_CLINICAL_REVIEW','NO_SUSPICIOUS_FINDING_DEMO');
CREATE TYPE review_decision      AS ENUM ('NO_ACTION','ROUTINE_FOLLOW_UP','RESCREEN','REQUEST_RECAPTURE',
                                          'REQUEST_MORE_INFO','SPECIALIST_REVIEW','URGENT_REFERRAL');
CREATE TYPE ai_agreement         AS ENUM ('NOT_AVAILABLE','AGREE','DISAGREE','DEFER');
CREATE TYPE classification_level AS ENUM ('SCREEN_POSITIVE','CLINICAL_SUSPICION','PRECANCER_CLINICIAN_CONFIRMED',
                                          'MALIGNANCY_PATHOLOGY_CONFIRMED','BENIGN_OR_NO_CONCERN','INCONCLUSIVE');
CREATE TYPE referral_mode        AS ENUM ('VIDEO_CONSULT','HOSPITAL_VISIT','BOTH');
CREATE TYPE referral_status      AS ENUM ('PLANNED','SENT','ACCEPTED','COMPLETED','DECLINED','CANCELLED');
CREATE TYPE consult_mode         AS ENUM ('VIDEO','IN_PERSON');
CREATE TYPE attendance_status    AS ENUM ('PENDING','ATTENDED','NO_SHOW');
CREATE TYPE diagnosis_category   AS ENUM ('BENIGN','PRE_MALIGNANT','MALIGNANT','INCONCLUSIVE');
CREATE TYPE linkage_status       AS ENUM ('PLANNED','CONFIRMED','STARTED','COMPLETED','DECLINED','LOST');
CREATE TYPE followup_task_type   AS ENUM ('MISSED_APPOINTMENT','REMINDER','TRANSPORT','RESULT_COLLECTION','LOST_CONTACT','TREATMENT_LINKAGE','OTHER');
CREATE TYPE contact_channel      AS ENUM ('PHONE','HOME_VISIT','SMS','IN_PERSON','OTHER');
CREATE TYPE contact_outcome      AS ENUM ('REACHED','NOT_REACHED','WRONG_NUMBER','REFUSED','RESCHEDULED');
CREATE TYPE transport_status     AS ENUM ('REQUESTED','ARRANGED','COMPLETED','CANCELLED');
CREATE TYPE escalation_status    AS ENUM ('OPEN','ACKNOWLEDGED','RESOLVED');
CREATE TYPE notification_channel AS ENUM ('IN_APP','SMS','PUSH');
CREATE TYPE notification_status  AS ENUM ('PENDING','SENT','FAILED','CANCELLED');
CREATE TYPE sync_status          AS ENUM ('PENDING','UPLOADING','CONFIRMED','FAILED');
CREATE TYPE sync_operation       AS ENUM ('CREATE','UPDATE');
CREATE TYPE conflict_resolution  AS ENUM ('OPEN','KEPT_LOCAL','KEPT_SERVER','MERGED');
CREATE TYPE error_severity       AS ENUM ('DEBUG','INFO','WARNING','ERROR','CRITICAL');

-- >>> 01_functions.sql
-- 01_functions.sql | Shared trigger functions (plpgsql bodies are resolved at run time).

CREATE FUNCTION fn_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

CREATE FUNCTION fn_block_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % not allowed', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'integrity_constraint_violation';
END $$;

-- Generic: column TG_ARGV[0] must reference a user whose role code is in comma list TG_ARGV[1]
CREATE FUNCTION fn_require_role() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE uid UUID; rcode TEXT;
BEGIN
  uid := (to_jsonb(NEW) ->> TG_ARGV[0])::uuid;
  IF uid IS NULL THEN RETURN NEW; END IF;
  SELECT r.code INTO rcode FROM tbl_users u JOIN mst_roles r ON r.id = u.role_id WHERE u.id = uid;
  IF rcode IS NULL OR NOT (rcode = ANY (string_to_array(TG_ARGV[1], ','))) THEN
    RAISE EXCEPTION '%.% must be a user with role in (%), got %',
          TG_TABLE_NAME, TG_ARGV[0], TG_ARGV[1], COALESCE(rcode, 'unknown')
          USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

-- Generic: latest consent row (granted / withdrawn) of purpose TG_ARGV[0] for NEW.patient_id must be granted
CREATE FUNCTION fn_require_consent() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pid UUID; g BOOLEAN;
BEGIN
  pid := (to_jsonb(NEW) ->> 'patient_id')::uuid;
  SELECT pc.granted INTO g
    FROM tbl_patient_consents pc JOIN mst_consent_purposes cp ON cp.id = pc.purpose_id
   WHERE pc.patient_id = pid AND cp.code = TG_ARGV[0]
   ORDER BY pc.consent_seq DESC LIMIT 1;
  IF g IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'operation rejected: no active % consent for this patient', TG_ARGV[0]
          USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

-- screening.consent_id must be a GRANTED consent with purpose SCREENING
CREATE FUNCTION fn_screening_consent_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pcode TEXT; g BOOLEAN;
BEGIN
  IF NEW.consent_id IS NOT NULL THEN
    SELECT cp.code, pc.granted INTO pcode, g
      FROM tbl_patient_consents pc JOIN mst_consent_purposes cp ON cp.id = pc.purpose_id
     WHERE pc.id = NEW.consent_id;
    IF pcode IS DISTINCT FROM 'SCREENING' OR g IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'screening.consent_id must reference a granted SCREENING consent'
            USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- Signed clinician reviews: optimistic version control, no silent rewrite
CREATE FUNCTION fn_review_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.screening_id <> OLD.screening_id OR NEW.patient_id <> OLD.patient_id THEN
    RAISE EXCEPTION 'a review cannot be moved to another screening/patient' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.version <> OLD.version + 1 THEN
    RAISE EXCEPTION 'version conflict on review %: expected %, got %', OLD.id, OLD.version + 1, NEW.version
          USING ERRCODE = 'serialization_failure';
  END IF;
  IF OLD.signed_at IS NOT NULL THEN
    IF NEW.doctor_id <> OLD.doctor_id THEN
      RAISE EXCEPTION 'a signed review cannot be rewritten by another user' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.amendment_reason IS NULL OR NEW.amendment_reason IS NOT DISTINCT FROM OLD.amendment_reason THEN
      RAISE EXCEPTION 'amending a signed review requires a new amendment_reason' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION fn_review_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actor UUID;
BEGIN
  actor := COALESCE(NULLIF(current_setting('app.user_id', true), '')::uuid, NEW.doctor_id);
  INSERT INTO tbl_clinical_review_versions (review_id, version_no, snapshot, edited_by)
  VALUES (NEW.id, NEW.version, to_jsonb(NEW), actor);
  RETURN NEW;
END $$;

-- A referral needs a SIGNED review whose decision is a referral decision
CREATE FUNCTION fn_referral_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE sa TIMESTAMPTZ; dec review_decision;
BEGIN
  SELECT cr.signed_at, cr.decision INTO sa, dec FROM tbl_clinical_reviews cr WHERE cr.id = NEW.review_id;
  IF sa IS NULL THEN
    RAISE EXCEPTION 'a referral requires a signed clinician review' USING ERRCODE = 'check_violation';
  END IF;
  IF dec NOT IN ('SPECIALIST_REVIEW','URGENT_REFERRAL') THEN
    RAISE EXCEPTION 'review decision % does not authorise a referral', dec USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

-- AI rows: snapshot model provenance, forbid invented localisation, immutable once finished
CREATE FUNCTION fn_ai_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE prov TEXT; ver TEXT; sl BOOLEAN;
BEGIN
  SELECT m.provider, m.model_version, m.supports_localization INTO prov, ver, sl
    FROM mst_ai_models m WHERE m.id = NEW.ai_model_id;
  IF TG_OP = 'INSERT' THEN
    NEW.model_provider := prov;
    NEW.model_version  := ver;
  ELSE
    IF OLD.status IN ('COMPLETED','FAILED','UNAVAILABLE') THEN
      RAISE EXCEPTION 'finished AI output is immutable; create a new assessment (retry)'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.ai_model_id <> OLD.ai_model_id THEN
      RAISE EXCEPTION 'model cannot change on an existing assessment' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF NEW.localization IS NOT NULL AND NOT COALESCE(sl, FALSE) THEN
    RAISE EXCEPTION 'model % does not support localisation; overlays/heatmaps must not be stored', ver
          USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

-- Signed pathology reviews are immutable (corrections = new row with supersedes_id)
CREATE FUNCTION fn_pathology_review_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.signed_at IS NOT NULL THEN
    RAISE EXCEPTION 'a signed pathology review is immutable; add a superseding review'
          USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END $$;

-- Only clinicians may set anything above SCREEN_POSITIVE; confirmations need signed evidence
CREATE FUNCTION fn_classification_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE rc TEXT; dcat diagnosis_category; psigned TIMESTAMPTZ; rsigned TIMESTAMPTZ;
BEGIN
  SELECT r.code INTO rc FROM tbl_users u JOIN mst_roles r ON r.id = u.role_id WHERE u.id = NEW.set_by;
  IF NEW.level <> 'SCREEN_POSITIVE' AND rc NOT IN ('MEDICAL_OFFICER','SPECIALIST') THEN
    RAISE EXCEPTION 'only a clinician may set classification %', NEW.level USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.level = 'MALIGNANCY_PATHOLOGY_CONFIRMED' THEN
    SELECT pr.diagnosis_category, pr.signed_at INTO dcat, psigned
      FROM tbl_pathology_reviews pr WHERE pr.id = NEW.pathology_review_id;
    IF dcat IS DISTINCT FROM 'MALIGNANT' OR psigned IS NULL THEN
      RAISE EXCEPTION 'MALIGNANCY_PATHOLOGY_CONFIRMED needs a signed pathology review with category MALIGNANT'
            USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.level = 'PRECANCER_CLINICIAN_CONFIRMED' THEN
    SELECT pr.signed_at INTO psigned FROM tbl_pathology_reviews pr
     WHERE pr.id = NEW.pathology_review_id AND pr.diagnosis_category = 'PRE_MALIGNANT';
    SELECT cr.signed_at INTO rsigned FROM tbl_clinical_reviews cr WHERE cr.id = NEW.clinical_review_id;
    IF psigned IS NULL AND rsigned IS NULL THEN
      RAISE EXCEPTION 'PRECANCER_CLINICIAN_CONFIRMED needs a signed PRE_MALIGNANT pathology review or a signed clinical review'
            USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- Case state machine (handbook section 6) + evidence gates
CREATE FUNCTION fn_check_case_transition() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE ok BOOLEAN;
BEGIN
  IF NEW.case_state IS NOT DISTINCT FROM OLD.case_state THEN RETURN NEW; END IF;

  SELECT EXISTS (
      SELECT 1 FROM (VALUES
        ('DRAFT','CONSENTED'),('DRAFT','CLOSED'),('CONSENTED','SCREENED'),
        ('SCREENED','AWAITING_CLINICIAN'),('SCREENED','CLOSED'),
        ('AWAITING_CLINICIAN','REVIEWED'),('AWAITING_CLINICIAN','SCREENED'),      -- SCREENED = recapture requested
        ('REVIEWED','REFERRAL_PLANNED'),('REVIEWED','CLOSED'),
        ('REFERRAL_PLANNED','APPOINTED'),('APPOINTED','ASSESSED'),
        ('ASSESSED','DIAGNOSTICS_PENDING'),('ASSESSED','CLOSED'),
        ('DIAGNOSTICS_PENDING','RESULT_REVIEWED'),
        ('RESULT_REVIEWED','CARE_LINKED'),('RESULT_REVIEWED','DIAGNOSTICS_PENDING'),('RESULT_REVIEWED','CLOSED'),
        ('CARE_LINKED','CLOSED')
      ) AS t(a, b)
      WHERE a = OLD.case_state::text AND b = NEW.case_state::text)
    OR (NEW.case_state IN ('RESCHEDULED','MISSED','DECLINED','LOST_CONTACT')
        AND OLD.case_state NOT IN ('DRAFT','CLOSED'))
    OR (OLD.case_state IN ('RESCHEDULED','MISSED','DECLINED','LOST_CONTACT')
        AND NEW.case_state IN ('REFERRAL_PLANNED','APPOINTED','ASSESSED','DIAGNOSTICS_PENDING','CLOSED','LOST_CONTACT'))
  INTO ok;

  IF NOT ok THEN
    RAISE EXCEPTION 'invalid case transition % -> %', OLD.case_state, NEW.case_state
          USING ERRCODE = 'check_violation';
  END IF;

  -- AI can never bypass the clinician
  IF NEW.case_state = 'REVIEWED' AND NOT EXISTS (
        SELECT 1 FROM tbl_clinical_reviews cr WHERE cr.screening_id = NEW.id AND cr.signed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'case cannot be REVIEWED without a signed clinician review' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.case_state = 'REFERRAL_PLANNED' AND NOT EXISTS (
        SELECT 1 FROM tbl_referrals r JOIN tbl_clinical_reviews cr ON cr.id = r.review_id
         WHERE cr.screening_id = NEW.id AND r.status <> 'CANCELLED') THEN
    RAISE EXCEPTION 'REFERRAL_PLANNED needs a referral record' USING ERRCODE = 'check_violation';
  END IF;
  -- creating a referral is NOT completing specialist care
  IF NEW.case_state = 'ASSESSED' AND NOT EXISTS (
        SELECT 1 FROM tbl_referrals r JOIN tbl_clinical_reviews cr ON cr.id = r.review_id
         WHERE cr.screening_id = NEW.id AND r.assessment_completed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'ASSESSED needs a completed specialist assessment on the referral' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.case_state = 'RESULT_REVIEWED' AND NOT EXISTS (
        SELECT 1 FROM tbl_pathology_reviews pr
          JOIN tbl_pathology_reports rep ON rep.id = pr.report_id
          JOIN tbl_investigation_orders o ON o.id = rep.order_id
          JOIN tbl_referrals r ON r.id = o.referral_id
          JOIN tbl_clinical_reviews cr ON cr.id = r.review_id
         WHERE cr.screening_id = NEW.id AND pr.signed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'RESULT_REVIEWED needs a signed clinician review of the report' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.case_state = 'CARE_LINKED' AND NOT EXISTS (
        SELECT 1 FROM tbl_treatment_linkages tl
          JOIN tbl_referrals r ON r.id = tl.referral_id
          JOIN tbl_clinical_reviews cr ON cr.id = r.review_id
         WHERE cr.screening_id = NEW.id AND tl.status IN ('CONFIRMED','STARTED','COMPLETED')) THEN
    RAISE EXCEPTION 'CARE_LINKED needs a confirmed treatment linkage' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

-- >>> 02_masters.sql
-- 02_masters.sql | Master / lookup tables (mst_*)

CREATE TABLE mst_roles (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         TEXT NOT NULL UNIQUE,
    name_en      TEXT NOT NULL,
    name_te      TEXT,
    description  TEXT,
    mfa_required BOOLEAN NOT NULL DEFAULT FALSE,   -- enforced at login by the API (privileged users)
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE mst_permissions (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,
    resource    TEXT NOT NULL,
    action      TEXT NOT NULL,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE mst_languages (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,
    name_en     TEXT NOT NULL,
    native_name TEXT NOT NULL,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_districts (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code       TEXT NOT NULL UNIQUE,
    name_en    TEXT NOT NULL,
    name_te    TEXT,
    state_name TEXT NOT NULL DEFAULT 'Andhra Pradesh',
    is_active  BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_mandals (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    district_id BIGINT NOT NULL REFERENCES mst_districts(id),
    code        TEXT NOT NULL UNIQUE,
    name_en     TEXT NOT NULL,
    name_te     TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_mandals_district ON mst_mandals (district_id);

CREATE TABLE mst_gram_panchayats (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mandal_id BIGINT NOT NULL REFERENCES mst_mandals(id),
    code      TEXT NOT NULL UNIQUE,
    name_en   TEXT NOT NULL,
    name_te   TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_gp_mandal ON mst_gram_panchayats (mandal_id);

CREATE TABLE mst_villages (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gram_panchayat_id BIGINT NOT NULL REFERENCES mst_gram_panchayats(id),
    code              TEXT NOT NULL UNIQUE,
    name_en           TEXT NOT NULL,
    name_te           TEXT,
    is_active         BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_villages_gp ON mst_villages (gram_panchayat_id);

CREATE TABLE mst_phcs (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mandal_id BIGINT NOT NULL REFERENCES mst_mandals(id),
    code      TEXT NOT NULL UNIQUE,
    name_en   TEXT NOT NULL,
    name_te   TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_phcs_mandal ON mst_phcs (mandal_id);

CREATE TABLE mst_hospitals (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    district_id BIGINT NOT NULL REFERENCES mst_districts(id),
    code        TEXT NOT NULL UNIQUE,
    name_en     TEXT NOT NULL,
    name_te     TEXT,
    level       TEXT,                           -- CHC / AH / DH / TERTIARY
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_facilities (                   -- unified facility for assignments / reporting
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    district_id   BIGINT NOT NULL REFERENCES mst_districts(id),
    facility_type facility_type NOT NULL,
    phc_id        BIGINT REFERENCES mst_phcs(id),
    hospital_id   BIGINT REFERENCES mst_hospitals(id),
    code          TEXT NOT NULL UNIQUE,
    name_en       TEXT NOT NULL,
    name_te       TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT ck_facility_one_parent CHECK (phc_id IS NULL OR hospital_id IS NULL)
);
CREATE INDEX idx_facilities_district ON mst_facilities (district_id, facility_type);

CREATE TABLE mst_screening_sites (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    village_id  BIGINT REFERENCES mst_villages(id),
    facility_id BIGINT REFERENCES mst_facilities(id),
    code        TEXT NOT NULL UNIQUE,
    name_en     TEXT NOT NULL,
    name_te     TEXT,
    site_type   TEXT NOT NULL DEFAULT 'CAMP' CHECK (site_type IN ('CAMP','PHC','HOME','MOBILE_UNIT')),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_specialties (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code      TEXT NOT NULL UNIQUE,
    name_en   TEXT NOT NULL,
    name_te   TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_consent_purposes (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,           -- SCREENING, IMAGE_CAPTURE, TELECONSULT, DATA_PROCESSING, AI_RESEARCH
    name_en     TEXT NOT NULL,
    name_te     TEXT,
    text_en     TEXT NOT NULL,
    text_te     TEXT,
    version     TEXT NOT NULL DEFAULT 'v1',
    is_required BOOLEAN NOT NULL DEFAULT TRUE,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_symptoms (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code      TEXT NOT NULL UNIQUE,
    name_en   TEXT NOT NULL,
    name_te   TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_exposure_types (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code      TEXT NOT NULL UNIQUE,
    name_en   TEXT NOT NULL,
    name_te   TEXT,
    category  TEXT NOT NULL DEFAULT 'TOBACCO' CHECK (category IN ('TOBACCO','ARECA','ALCOHOL','OTHER')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_referral_priorities (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code          TEXT NOT NULL UNIQUE,
    name_en       TEXT NOT NULL,
    name_te       TEXT,
    priority_rank SMALLINT NOT NULL UNIQUE,      -- 1 = most urgent
    target_days   INT,                           -- set by approved clinical protocol, not by software
    is_active     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_investigation_types (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code      TEXT NOT NULL UNIQUE,
    name_en   TEXT NOT NULL,
    name_te   TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_appointment_statuses (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,
    name_en     TEXT NOT NULL,
    name_te     TEXT,
    is_terminal BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order  SMALLINT NOT NULL DEFAULT 0
);

CREATE TABLE mst_investigation_statuses (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,
    name_en     TEXT NOT NULL,
    name_te     TEXT,
    is_terminal BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order  SMALLINT NOT NULL DEFAULT 0
);

CREATE TABLE mst_followup_statuses (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,
    name_en     TEXT NOT NULL,
    name_te     TEXT,
    is_terminal BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order  SMALLINT NOT NULL DEFAULT 0
);

CREATE TABLE mst_missed_reasons (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code      TEXT NOT NULL UNIQUE,
    name_en   TEXT NOT NULL,
    name_te   TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE mst_notification_templates (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL,
    language_id BIGINT NOT NULL REFERENCES mst_languages(id),
    channel     notification_channel NOT NULL DEFAULT 'IN_APP',
    subject     TEXT,
    body        TEXT NOT NULL,                   -- must contain NO diagnosis / sensitive detail
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (code, language_id, channel)
);

-- Configurable follow-up / reminder / escalation rules. Values are decided by clinical protocol.
CREATE TABLE mst_protocol_rules (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,
    rule_type       TEXT NOT NULL CHECK (rule_type IN ('REMINDER','FOLLOWUP_TASK','OVERDUE_ESCALATION')),
    applies_to      TEXT NOT NULL CHECK (applies_to IN ('HOSPITAL_APPOINTMENT','VIDEO_CONSULTATION','REFERRAL','INVESTIGATION','TREATMENT_LINKAGE')),
    offset_minutes  INT NOT NULL,                -- relative to the event time (negative = before)
    template_code   TEXT,
    escalation_level SMALLINT CHECK (escalation_level BETWEEN 1 AND 5),
    is_placeholder  BOOLEAN NOT NULL DEFAULT TRUE,   -- TRUE until a clinical protocol approves the value
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    notes           TEXT
);

-- Stable translation dictionary: key -> English / Telugu
CREATE TABLE mst_ui_translations (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    msg_key      TEXT NOT NULL,
    language_id  BIGINT NOT NULL REFERENCES mst_languages(id),
    msg_text     TEXT NOT NULL,
    module       TEXT,
    needs_review BOOLEAN NOT NULL DEFAULT TRUE,  -- Telugu must be verified by a qualified clinician
    UNIQUE (msg_key, language_id)
);

CREATE TABLE mst_ai_models (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider            TEXT NOT NULL,           -- mock / research
    model_version       TEXT NOT NULL,
    description         TEXT,
    permitted_use       TEXT NOT NULL DEFAULT 'Hackathon demonstration only - NOT FOR CLINICAL USE',
    validation_status   TEXT NOT NULL DEFAULT 'NOT_VALIDATED',
    supports_localization BOOLEAN NOT NULL DEFAULT FALSE,   -- never TRUE unless a supervised localiser exists
    dataset_card_ref    TEXT,
    model_card_ref      TEXT,
    is_research_only    BOOLEAN NOT NULL DEFAULT TRUE,
    clinical_use        BOOLEAN NOT NULL DEFAULT FALSE,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider, model_version),
    CONSTRAINT ck_model_never_clinical CHECK (clinical_use = FALSE AND is_research_only = TRUE)
);

-- >>> 03_access_and_patients.sql
-- 03_access_and_patients.sql | Users, access control, patients, consent

CREATE TABLE tbl_users (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username             TEXT NOT NULL,
    auth_id              TEXT UNIQUE,
    password_hash        TEXT NOT NULL,          -- argon2id/bcrypt, never plaintext
    full_name            TEXT NOT NULL,
    phone                TEXT,
    email                TEXT,
    designation          TEXT CHECK (designation IN ('ASHA','ANM','CHO','OTHER')),   -- health workers
    employee_ref         TEXT,
    role_id              BIGINT NOT NULL REFERENCES mst_roles(id),
    status               user_status NOT NULL DEFAULT 'ACTIVE',
    mfa_enabled          BOOLEAN NOT NULL DEFAULT FALSE,
    mfa_secret_encrypted TEXT,
    must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
    failed_login_count   INT NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    password_changed_at  TIMESTAMPTZ,
    is_synthetic         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ
);
CREATE UNIQUE INDEX uq_users_username ON tbl_users (lower(username));
CREATE INDEX idx_users_role ON tbl_users (role_id) WHERE deleted_at IS NULL;
CREATE TRIGGER trg_tbl_users_updated_at BEFORE UPDATE ON tbl_users
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- Self-registration of health workers: stays PENDING until a SYSTEM_ADMIN approves (no shared / auto-active accounts)
CREATE TABLE tbl_user_registration_requests (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name         TEXT NOT NULL,
    username          TEXT NOT NULL,
    phone             TEXT NOT NULL,
    email             TEXT,
    designation       TEXT NOT NULL CHECK (designation IN ('ASHA','ANM','CHO','OTHER')),
    employee_ref      TEXT,
    facility_id       BIGINT NOT NULL REFERENCES mst_facilities(id),
    language_id       BIGINT NOT NULL REFERENCES mst_languages(id),
    password_hash     TEXT NOT NULL,              -- hash only, never plaintext
    requested_role    TEXT NOT NULL DEFAULT 'HEALTH_WORKER' CHECK (requested_role = 'HEALTH_WORKER'),
    terms_accepted_at TIMESTAMPTZ NOT NULL,
    status            registration_status NOT NULL DEFAULT 'PENDING',
    reviewed_by       UUID REFERENCES tbl_users(id),
    reviewed_at       TIMESTAMPTZ,
    rejection_reason  TEXT,
    created_user_id   UUID REFERENCES tbl_users(id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_reg_approved CHECK (status <> 'APPROVED' OR (created_user_id IS NOT NULL AND reviewed_by IS NOT NULL)),
    CONSTRAINT ck_reg_rejected CHECK (status <> 'REJECTED' OR rejection_reason IS NOT NULL)
);
CREATE UNIQUE INDEX uq_reg_pending_username ON tbl_user_registration_requests (lower(username)) WHERE status = 'PENDING';
CREATE INDEX idx_reg_status ON tbl_user_registration_requests (status, created_at);
CREATE TRIGGER trg_reg_reviewer_role BEFORE INSERT OR UPDATE ON tbl_user_registration_requests
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('reviewed_by', 'SYSTEM_ADMIN');

CREATE TABLE tbl_user_sessions (                 -- strong sessions: expiry + revocation (lost token)
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID NOT NULL REFERENCES tbl_users(id),
    refresh_token_hash TEXT NOT NULL UNIQUE,     -- hash only, never the token
    device_id          TEXT,
    ip_address         INET,
    user_agent         TEXT,
    mfa_verified       BOOLEAN NOT NULL DEFAULT FALSE,
    issued_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at         TIMESTAMPTZ NOT NULL,
    last_seen_at       TIMESTAMPTZ,
    revoked_at         TIMESTAMPTZ,
    revoke_reason      TEXT,
    CONSTRAINT ck_session_expiry CHECK (expires_at > issued_at)
);
CREATE INDEX idx_sessions_user ON tbl_user_sessions (user_id) WHERE revoked_at IS NULL;

CREATE TABLE tbl_user_facility_assignments (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES tbl_users(id),
    facility_id BIGINT NOT NULL REFERENCES mst_facilities(id),
    is_primary  BOOLEAN NOT NULL DEFAULT FALSE,
    valid_from  DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to    DATE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, facility_id, valid_from),
    CONSTRAINT ck_assignment_dates CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE INDEX idx_ufa_user     ON tbl_user_facility_assignments (user_id);
CREATE INDEX idx_ufa_facility ON tbl_user_facility_assignments (facility_id);

CREATE TABLE tbl_role_permissions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id       BIGINT NOT NULL REFERENCES mst_roles(id),
    permission_id BIGINT NOT NULL REFERENCES mst_permissions(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (role_id, permission_id)
);

CREATE TABLE tbl_user_language_preferences (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL UNIQUE REFERENCES tbl_users(id),
    language_id BIGINT NOT NULL REFERENCES mst_languages(id),
    font_scale  NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (font_scale BETWEEN 0.75 AND 2.00),
    voice_guidance BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_tbl_user_language_preferences_updated_at BEFORE UPDATE ON tbl_user_language_preferences
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE tbl_patients (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_code           TEXT NOT NULL UNIQUE
        DEFAULT ('AD-' || to_char(now(),'YYYY') || '-' || lpad(nextval('seq_patient_code')::text, 6, '0')),
    full_name              TEXT NOT NULL,
    sex                    sex_type NOT NULL DEFAULT 'UNDISCLOSED',
    date_of_birth          DATE,
    age_years              SMALLINT CHECK (age_years BETWEEN 0 AND 120),
    village_id             BIGINT REFERENCES mst_villages(id),  -- village -> gram panchayat -> mandal
    habitation             TEXT,
    address_line           TEXT,
    contact_phone          TEXT,                 -- synthetic numbers only; encrypt in app layer
    preferred_language_id  BIGINT REFERENCES mst_languages(id),
    phc_id                 BIGINT REFERENCES mst_phcs(id),
    registered_facility_id BIGINT NOT NULL REFERENCES mst_facilities(id),
    registered_by          UUID NOT NULL REFERENCES tbl_users(id),
    duplicate_hint         TEXT,                 -- normalised hash for duplicate warning
    idempotency_key        TEXT,
    client_created_at      TIMESTAMPTZ,
    version                INT NOT NULL DEFAULT 1,
    is_synthetic           BOOLEAN NOT NULL DEFAULT TRUE CHECK (is_synthetic),  -- blocks real data
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at             TIMESTAMPTZ,
    -- NOTE: Aadhaar is deliberately NOT stored (must not be mandatory)
    CONSTRAINT ck_patient_age_known CHECK (date_of_birth IS NOT NULL OR age_years IS NOT NULL),
    UNIQUE (registered_by, idempotency_key)
);
CREATE INDEX idx_patients_facility  ON tbl_patients (registered_facility_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_patients_village   ON tbl_patients (village_id);
CREATE INDEX idx_patients_phc       ON tbl_patients (phc_id);
CREATE INDEX idx_patients_duplicate ON tbl_patients (duplicate_hint);
CREATE TRIGGER trg_tbl_patients_updated_at BEFORE UPDATE ON tbl_patients
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE tbl_patient_duplicate_flags (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id     UUID NOT NULL REFERENCES tbl_patients(id),
    candidate_id   UUID NOT NULL REFERENCES tbl_patients(id),
    match_reason   TEXT,
    status         duplicate_status NOT NULL DEFAULT 'OPEN',
    reviewed_by    UUID REFERENCES tbl_users(id),
    reviewed_at    TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_dup_distinct CHECK (patient_id <> candidate_id),
    UNIQUE (patient_id, candidate_id)
);

-- Care relationship: patient-level access is granted ONLY through this (or own-facility rules, see fn_user_has_patient_access)
CREATE TABLE tbl_case_assignments (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id  UUID NOT NULL REFERENCES tbl_patients(id),
    referral_id UUID,                            -- FK added after tbl_referrals exists
    user_id     UUID NOT NULL REFERENCES tbl_users(id),
    assigned_by UUID NOT NULL REFERENCES tbl_users(id),
    reason      TEXT,
    valid_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_to    TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_case_assign_dates CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE UNIQUE INDEX uq_case_assign_active ON tbl_case_assignments
    (patient_id, user_id, COALESCE(referral_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE valid_to IS NULL;
CREATE INDEX idx_case_assign_user ON tbl_case_assignments (user_id) WHERE valid_to IS NULL;
CREATE TRIGGER trg_case_assign_role BEFORE INSERT OR UPDATE ON tbl_case_assignments
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('user_id', 'HEALTH_WORKER,MEDICAL_OFFICER,SPECIALIST,NAVIGATOR,HOSPITAL_STAFF');

CREATE TABLE tbl_patient_medical_histories (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id        UUID NOT NULL REFERENCES tbl_patients(id),
    history_kind      history_type NOT NULL DEFAULT 'EXPOSURE',
    exposure_type_id  BIGINT REFERENCES mst_exposure_types(id),
    condition_text    TEXT,
    duration_years    NUMERIC(4,1) CHECK (duration_years >= 0),
    frequency_per_day SMALLINT CHECK (frequency_per_day >= 0),
    is_current        BOOLEAN,
    event_date        DATE,                      -- for prior screening / prior referral
    recorded_by       UUID NOT NULL REFERENCES tbl_users(id),
    recorded_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_history_has_content CHECK (exposure_type_id IS NOT NULL OR condition_text IS NOT NULL)
);
CREATE INDEX idx_history_patient ON tbl_patient_medical_histories (patient_id);

CREATE TABLE tbl_patient_consents (              -- APPEND-ONLY: withdrawal = new row with granted = false
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    consent_seq     BIGINT GENERATED ALWAYS AS IDENTITY,   -- strict ordering within a transaction
    patient_id      UUID NOT NULL REFERENCES tbl_patients(id),
    purpose_id      BIGINT NOT NULL REFERENCES mst_consent_purposes(id),
    language_id     BIGINT NOT NULL REFERENCES mst_languages(id),
    consent_version TEXT NOT NULL,
    method          consent_method NOT NULL DEFAULT 'CHECKBOX',
    granted         BOOLEAN NOT NULL,
    captured_by     UUID NOT NULL REFERENCES tbl_users(id),
    witness_name    TEXT,
    device_id       TEXT,
    notes           TEXT,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (id, patient_id)
);
CREATE INDEX idx_consents_patient ON tbl_patient_consents (patient_id, purpose_id, consent_seq DESC);
CREATE TRIGGER trg_tbl_patient_consents_append_only BEFORE UPDATE OR DELETE ON tbl_patient_consents
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

-- >>> 04_screening_ai_review.sql
-- 04_screening_ai_review.sql | Screening, photos, AI, clinician review, referral

CREATE TABLE tbl_screenings (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id          UUID NOT NULL REFERENCES tbl_patients(id),
    examiner_id         UUID NOT NULL REFERENCES tbl_users(id),
    facility_id         BIGINT NOT NULL REFERENCES mst_facilities(id),
    screening_site_id   BIGINT REFERENCES mst_screening_sites(id),
    screening_date      DATE NOT NULL DEFAULT CURRENT_DATE,
    case_state          case_state NOT NULL DEFAULT 'DRAFT',
    consent_id          UUID,
    tobacco_current     BOOLEAN,
    chief_complaint     TEXT,
    clinical_exam_done  BOOLEAN NOT NULL DEFAULT FALSE,   -- photos supplement, never replace, the clinical exam
    notes               TEXT,
    version             INT NOT NULL DEFAULT 1,
    idempotency_key     TEXT,
    client_created_at   TIMESTAMPTZ,                      -- device time for offline drafts
    submitted_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (id, patient_id),
    UNIQUE (examiner_id, idempotency_key),
    FOREIGN KEY (consent_id, patient_id) REFERENCES tbl_patient_consents (id, patient_id),  -- same patient only
    CONSTRAINT ck_consent_gate CHECK (case_state = 'DRAFT' OR consent_id IS NOT NULL)
);
CREATE INDEX idx_screenings_patient  ON tbl_screenings (patient_id, screening_date DESC);
CREATE INDEX idx_screenings_facility ON tbl_screenings (facility_id, case_state);
CREATE INDEX idx_screenings_examiner ON tbl_screenings (examiner_id);
CREATE TRIGGER trg_tbl_screenings_updated_at BEFORE UPDATE ON tbl_screenings
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_screening_examiner_role BEFORE INSERT OR UPDATE ON tbl_screenings
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('examiner_id', 'HEALTH_WORKER,MEDICAL_OFFICER');
CREATE TRIGGER trg_screening_consent BEFORE INSERT OR UPDATE OF consent_id ON tbl_screenings
    FOR EACH ROW EXECUTE FUNCTION fn_screening_consent_check();
CREATE TRIGGER trg_screening_state BEFORE UPDATE OF case_state ON tbl_screenings
    FOR EACH ROW EXECUTE FUNCTION fn_check_case_transition();

CREATE TABLE tbl_screening_findings (            -- health-worker / clinician findings (separate from AI)
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    screening_id  UUID NOT NULL REFERENCES tbl_screenings(id),
    finding_kind  finding_type NOT NULL,
    symptom_id    BIGINT REFERENCES mst_symptoms(id),
    oral_site     oral_view,
    description   TEXT,
    duration_days INT CHECK (duration_days >= 0),
    recorded_by   UUID NOT NULL REFERENCES tbl_users(id),
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_finding_content CHECK (symptom_id IS NOT NULL OR description IS NOT NULL)
);
CREATE INDEX idx_findings_screening ON tbl_screening_findings (screening_id);

CREATE TABLE tbl_screening_photos (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    screening_id       UUID NOT NULL,
    patient_id         UUID NOT NULL,
    view_type          oral_view NOT NULL,
    annotation_site    TEXT,                     -- body-site annotation entered by the examiner
    private_key        TEXT NOT NULL UNIQUE,     -- object-store key, never a public URL
    checksum_sha256    CHAR(64) NOT NULL,
    mime_type          TEXT NOT NULL CHECK (mime_type IN ('image/jpeg','image/png','image/webp')),
    size_bytes         INT NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 10485760),
    width_px           INT CHECK (width_px > 0),
    height_px          INT CHECK (height_px > 0),
    metadata_stripped  BOOLEAN NOT NULL DEFAULT TRUE,
    status             photo_status NOT NULL DEFAULT 'UPLOADED',
    supersedes_photo_id UUID REFERENCES tbl_screening_photos(id),   -- recapture chain
    captured_by        UUID NOT NULL REFERENCES tbl_users(id),
    captured_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    idempotency_key    TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (screening_id, patient_id) REFERENCES tbl_screenings (id, patient_id),  -- same patient only
    UNIQUE (id, screening_id),
    UNIQUE (screening_id, checksum_sha256),      -- no duplicate image on retry
    UNIQUE (captured_by, idempotency_key),
    CONSTRAINT ck_photo_key_private CHECK (private_key !~* '^(https?:)?//')
);
CREATE INDEX idx_photos_screening ON tbl_screening_photos (screening_id);
CREATE TRIGGER trg_photo_requires_consent BEFORE INSERT ON tbl_screening_photos
    FOR EACH ROW EXECUTE FUNCTION fn_require_consent('IMAGE_CAPTURE');

CREATE TABLE tbl_image_quality_results (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    photo_id        UUID NOT NULL REFERENCES tbl_screening_photos(id),
    checker_version TEXT NOT NULL,
    status          quality_status NOT NULL,
    reason          TEXT CHECK (reason IN ('invalid_image','blurry','underexposed','overexposed','glare')),
    blur_score      NUMERIC(10,3),
    brightness_mean NUMERIC(6,2),
    glare_ratio     NUMERIC(5,4),
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_quality_reason CHECK ((status = 'ACCEPTABLE' AND reason IS NULL)
                                     OR (status = 'RECAPTURE'  AND reason IS NOT NULL))
);
CREATE INDEX idx_quality_photo ON tbl_image_quality_results (photo_id);

CREATE TABLE tbl_ai_assessments (                -- advisory, NON-CLINICAL; stored separately from clinical conclusion
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_code             TEXT NOT NULL UNIQUE DEFAULT ('DEMO-AI-' || lpad(nextval('seq_ai_analysis_code')::text, 3, '0')),
    screening_id              UUID NOT NULL,
    photo_id                  UUID NOT NULL,
    ai_model_id               BIGINT NOT NULL REFERENCES mst_ai_models(id),
    model_provider            TEXT NOT NULL,     -- snapshot filled by trigger
    model_version             TEXT NOT NULL,     -- snapshot filled by trigger
    status                    ai_status NOT NULL DEFAULT 'QUEUED',
    result_label              ai_result_label,
    image_quality_status      quality_status,
    score                     NUMERIC(5,4) CHECK (score BETWEEN 0 AND 1),   -- NOT a probability of cancer
    localization              JSONB,             -- only if model.supports_localization (trigger-enforced)
    clinical_use              BOOLEAN NOT NULL DEFAULT FALSE CHECK (clinical_use = FALSE),
    requires_clinician_review BOOLEAN NOT NULL DEFAULT TRUE CHECK (requires_clinician_review),
    warning                   TEXT NOT NULL DEFAULT 'NOT FOR CLINICAL USE' CHECK (warning ILIKE '%NOT FOR CLINICAL USE%'),
    error_code                TEXT,
    attempt_no                SMALLINT NOT NULL DEFAULT 1,
    requested_by              UUID NOT NULL REFERENCES tbl_users(id),
    requested_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at              TIMESTAMPTZ,
    FOREIGN KEY (photo_id, screening_id) REFERENCES tbl_screening_photos (id, screening_id),
    UNIQUE (id, screening_id),
    CONSTRAINT ck_ai_completed_has_label CHECK (status <> 'COMPLETED' OR (result_label IS NOT NULL AND completed_at IS NOT NULL)),
    CONSTRAINT ck_ai_failed_no_label     CHECK (status NOT IN ('FAILED','UNAVAILABLE') OR result_label IS NULL)
);
CREATE INDEX idx_ai_photo     ON tbl_ai_assessments (photo_id);
CREATE INDEX idx_ai_screening ON tbl_ai_assessments (screening_id);
CREATE TRIGGER trg_ai_guard BEFORE INSERT OR UPDATE ON tbl_ai_assessments
    FOR EACH ROW EXECUTE FUNCTION fn_ai_guard();

CREATE TABLE tbl_ai_assessment_logs (            -- APPEND-ONLY; no image content / PHI
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id UUID NOT NULL REFERENCES tbl_ai_assessments(id),
    event         TEXT NOT NULL,                 -- QUEUED / CALLED / TIMEOUT / FAILED / COMPLETED
    http_status   INT,
    latency_ms    INT CHECK (latency_ms >= 0),
    error_code    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_ai_logs_assessment ON tbl_ai_assessment_logs (assessment_id);
CREATE TRIGGER trg_tbl_ai_assessment_logs_append_only BEFORE UPDATE OR DELETE ON tbl_ai_assessment_logs
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_clinical_reviews (              -- the SIGNED clinical conclusion (never AI output)
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    screening_id        UUID NOT NULL UNIQUE,
    patient_id          UUID NOT NULL,
    doctor_id           UUID NOT NULL REFERENCES tbl_users(id),
    finding             TEXT NOT NULL,
    impression          TEXT,
    ai_assessment_id    UUID,
    ai_agreement        ai_agreement NOT NULL DEFAULT 'NOT_AVAILABLE',
    ai_discrepancy_note TEXT,
    decision            review_decision,
    followup_instructions TEXT,
    referral_reason     TEXT,
    request_note        TEXT,                    -- recapture / more-information request
    version             INT NOT NULL DEFAULT 1,
    amendment_reason    TEXT,
    signed_at           TIMESTAMPTZ,
    signature_hash      TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (screening_id, patient_id) REFERENCES tbl_screenings (id, patient_id),
    FOREIGN KEY (ai_assessment_id, screening_id) REFERENCES tbl_ai_assessments (id, screening_id),
    UNIQUE (id, patient_id),
    CONSTRAINT ck_sign_needs_decision CHECK (signed_at IS NULL OR (decision IS NOT NULL AND signature_hash IS NOT NULL)),
    CONSTRAINT ck_ai_agreement_needs_ai CHECK (ai_agreement = 'NOT_AVAILABLE' OR ai_assessment_id IS NOT NULL),
    CONSTRAINT ck_ai_disagree_note CHECK (ai_agreement <> 'DISAGREE' OR ai_discrepancy_note IS NOT NULL),
    CONSTRAINT ck_request_needs_note CHECK (decision NOT IN ('REQUEST_RECAPTURE','REQUEST_MORE_INFO') OR request_note IS NOT NULL)
);
CREATE INDEX idx_reviews_doctor ON tbl_clinical_reviews (doctor_id, signed_at);
CREATE TRIGGER trg_tbl_clinical_reviews_updated_at BEFORE UPDATE ON tbl_clinical_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_review_doctor_role BEFORE INSERT OR UPDATE ON tbl_clinical_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('doctor_id', 'MEDICAL_OFFICER');
CREATE TRIGGER trg_review_guard BEFORE UPDATE ON tbl_clinical_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_review_guard();
CREATE TRIGGER trg_review_snapshot AFTER INSERT OR UPDATE ON tbl_clinical_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_review_snapshot();

CREATE TABLE tbl_clinical_review_versions (      -- APPEND-ONLY, filled by trigger
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    review_id  UUID NOT NULL REFERENCES tbl_clinical_reviews(id),
    version_no INT NOT NULL,
    snapshot   JSONB NOT NULL,
    edited_by  UUID NOT NULL REFERENCES tbl_users(id),
    edited_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (review_id, version_no)
);
CREATE TRIGGER trg_tbl_clinical_review_versions_append_only BEFORE UPDATE OR DELETE ON tbl_clinical_review_versions
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_referrals (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_code           TEXT NOT NULL UNIQUE
        DEFAULT ('REF-' || to_char(now(),'YYYY') || '-' || lpad(nextval('seq_referral_code')::text, 6, '0')),
    review_id               UUID NOT NULL,
    patient_id              UUID NOT NULL,
    from_facility_id        BIGINT NOT NULL REFERENCES mst_facilities(id),
    to_hospital_id          BIGINT NOT NULL REFERENCES mst_hospitals(id),
    specialty_id            BIGINT NOT NULL REFERENCES mst_specialties(id),
    priority_id             BIGINT NOT NULL REFERENCES mst_referral_priorities(id),
    mode                    referral_mode NOT NULL DEFAULT 'HOSPITAL_VISIT',
    status                  referral_status NOT NULL DEFAULT 'PLANNED',
    reason                  TEXT NOT NULL,
    assigned_specialist_id  UUID REFERENCES tbl_users(id),
    assigned_navigator_id   UUID REFERENCES tbl_users(id),
    assessment_completed_at TIMESTAMPTZ,         -- specialist assessment done (not just referral created)
    assessment_completed_by UUID REFERENCES tbl_users(id),
    cancel_reason           TEXT,
    created_by              UUID NOT NULL REFERENCES tbl_users(id),
    idempotency_key         TEXT,
    version                 INT NOT NULL DEFAULT 1,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (review_id, patient_id) REFERENCES tbl_clinical_reviews (id, patient_id),  -- no cross-patient link
    UNIQUE (id, patient_id),
    UNIQUE (created_by, idempotency_key),
    CONSTRAINT ck_ref_complete CHECK ((status = 'COMPLETED') = (assessment_completed_at IS NOT NULL)),
    CONSTRAINT ck_ref_cancel   CHECK (status <> 'CANCELLED' OR cancel_reason IS NOT NULL)
);
CREATE INDEX idx_referrals_patient  ON tbl_referrals (patient_id);
CREATE INDEX idx_referrals_hospital ON tbl_referrals (to_hospital_id, status);
CREATE INDEX idx_referrals_review   ON tbl_referrals (review_id);
CREATE TRIGGER trg_tbl_referrals_updated_at BEFORE UPDATE ON tbl_referrals
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_referral_author_role BEFORE INSERT ON tbl_referrals
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('created_by', 'MEDICAL_OFFICER');
CREATE TRIGGER trg_referral_guard BEFORE INSERT ON tbl_referrals
    FOR EACH ROW EXECUTE FUNCTION fn_referral_guard();
CREATE TRIGGER trg_referral_specialist_role BEFORE INSERT OR UPDATE ON tbl_referrals
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('assigned_specialist_id', 'SPECIALIST');
CREATE TRIGGER trg_referral_navigator_role BEFORE INSERT OR UPDATE ON tbl_referrals
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('assigned_navigator_id', 'NAVIGATOR');

ALTER TABLE tbl_case_assignments
    ADD CONSTRAINT fk_case_assign_referral FOREIGN KEY (referral_id, patient_id)
    REFERENCES tbl_referrals (id, patient_id);

CREATE TABLE tbl_referral_status_history (       -- APPEND-ONLY
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_id UUID NOT NULL REFERENCES tbl_referrals(id),
    from_status referral_status,
    to_status   referral_status NOT NULL,
    changed_by  UUID NOT NULL REFERENCES tbl_users(id),
    reason      TEXT,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_ref_hist_referral ON tbl_referral_status_history (referral_id, changed_at);
CREATE TRIGGER trg_tbl_referral_status_history_append_only BEFORE UPDATE OR DELETE ON tbl_referral_status_history
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_referral_slips (                -- printable Telugu / English referral slip
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_id   UUID NOT NULL REFERENCES tbl_referrals(id),
    language_id   BIGINT NOT NULL REFERENCES mst_languages(id),
    file_key      TEXT NOT NULL UNIQUE,          -- private object key
    checksum_sha256 CHAR(64) NOT NULL,
    generated_by  UUID NOT NULL REFERENCES tbl_users(id),
    generated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    print_count   INT NOT NULL DEFAULT 0 CHECK (print_count >= 0),
    CONSTRAINT ck_slip_key_private CHECK (file_key !~* '^(https?:)?//')
);
CREATE INDEX idx_slips_referral ON tbl_referral_slips (referral_id);

-- >>> 05_appointments_investigations.sql
-- 05_appointments_investigations.sql | Telemedicine, hospital appointments, diagnostics, classification, treatment

CREATE TABLE tbl_consultation_slots (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    specialist_id UUID NOT NULL REFERENCES tbl_users(id),
    hospital_id   BIGINT REFERENCES mst_hospitals(id),
    slot_start    TIMESTAMPTZ NOT NULL,
    slot_end      TIMESTAMPTZ NOT NULL,
    mode          consult_mode NOT NULL DEFAULT 'VIDEO',
    is_booked     BOOLEAN NOT NULL DEFAULT FALSE,
    created_by    UUID NOT NULL REFERENCES tbl_users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_slot_range CHECK (slot_end > slot_start),
    CONSTRAINT ex_no_overlapping_slots EXCLUDE USING gist
        (specialist_id WITH =, tstzrange(slot_start, slot_end) WITH &&)
);
CREATE INDEX idx_slots_specialist ON tbl_consultation_slots (specialist_id, slot_start);
CREATE TRIGGER trg_slot_specialist_role BEFORE INSERT OR UPDATE ON tbl_consultation_slots
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('specialist_id', 'SPECIALIST');

CREATE TABLE tbl_video_consultations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_id         UUID NOT NULL,
    patient_id          UUID NOT NULL,
    slot_id             UUID NOT NULL REFERENCES tbl_consultation_slots(id),
    specialist_id       UUID NOT NULL REFERENCES tbl_users(id),
    requested_by        UUID NOT NULL REFERENCES tbl_users(id),
    status_id           BIGINT NOT NULL REFERENCES mst_appointment_statuses(id),
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,        -- FALSE once cancelled/rescheduled (frees the slot)
    rescheduled_from_id UUID REFERENCES tbl_video_consultations(id),
    cancel_reason       TEXT,
    provider            TEXT,
    room_ref            TEXT,                    -- opaque id; join tokens minted per join, short-lived
    meeting_expires_at  TIMESTAMPTZ,
    started_at          TIMESTAMPTZ,
    ended_at            TIMESTAMPTZ,
    recording_enabled   BOOLEAN NOT NULL DEFAULT FALSE CHECK (recording_enabled = FALSE),  -- no recording by default
    attendance          attendance_status NOT NULL DEFAULT 'PENDING',
    idempotency_key     TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (referral_id, patient_id) REFERENCES tbl_referrals (id, patient_id),
    UNIQUE (id, patient_id),
    UNIQUE (requested_by, idempotency_key),
    CONSTRAINT ck_room_not_public_link CHECK (room_ref IS NULL OR room_ref !~* '^(https?:)?//'),
    CONSTRAINT ck_call_times CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at)
);
CREATE UNIQUE INDEX uq_video_active_slot ON tbl_video_consultations (slot_id) WHERE is_active;
CREATE INDEX idx_video_referral   ON tbl_video_consultations (referral_id);
CREATE INDEX idx_video_specialist ON tbl_video_consultations (specialist_id);
CREATE TRIGGER trg_tbl_video_consultations_updated_at BEFORE UPDATE ON tbl_video_consultations
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_video_specialist_role BEFORE INSERT OR UPDATE ON tbl_video_consultations
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('specialist_id', 'SPECIALIST');
CREATE TRIGGER trg_video_requires_consent BEFORE INSERT ON tbl_video_consultations
    FOR EACH ROW EXECUTE FUNCTION fn_require_consent('TELECONSULT');

CREATE TABLE tbl_video_join_tokens (             -- time-limited, per-participant, hash only
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    consultation_id UUID NOT NULL REFERENCES tbl_video_consultations(id),
    user_id         UUID NOT NULL REFERENCES tbl_users(id),
    token_hash      TEXT NOT NULL UNIQUE,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    first_used_at   TIMESTAMPTZ,
    left_at         TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ,
    ip_address      INET,
    CONSTRAINT ck_token_lifetime CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '2 hours')
);
CREATE INDEX idx_join_tokens_consult ON tbl_video_join_tokens (consultation_id, user_id);

CREATE TABLE tbl_consultation_notes (            -- specialist notes, separate from attendance; versioned, append-only
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    consultation_id UUID NOT NULL,
    patient_id      UUID NOT NULL,
    author_id       UUID NOT NULL REFERENCES tbl_users(id),
    version_no      INT NOT NULL DEFAULT 1,
    note_text       TEXT NOT NULL,
    outcome         TEXT,
    next_action     TEXT,
    signed_at       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (consultation_id, patient_id) REFERENCES tbl_video_consultations (id, patient_id),
    UNIQUE (consultation_id, version_no)
);
CREATE TRIGGER trg_consult_note_author_role BEFORE INSERT ON tbl_consultation_notes
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('author_id', 'SPECIALIST,MEDICAL_OFFICER');
CREATE TRIGGER trg_tbl_consultation_notes_append_only BEFORE UPDATE OR DELETE ON tbl_consultation_notes
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_hospital_appointments (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_id         UUID NOT NULL,
    patient_id          UUID NOT NULL,
    hospital_id         BIGINT NOT NULL REFERENCES mst_hospitals(id),
    specialty_id        BIGINT NOT NULL REFERENCES mst_specialties(id),
    assigned_service    TEXT,
    location_note       TEXT,
    scheduled_at        TIMESTAMPTZ NOT NULL,
    status_id           BIGINT NOT NULL REFERENCES mst_appointment_statuses(id),
    attendance          attendance_status NOT NULL DEFAULT 'PENDING',
    attended_at         TIMESTAMPTZ,
    missed_reason_id    BIGINT REFERENCES mst_missed_reasons(id),
    missed_reason_text  TEXT,
    cancel_reason       TEXT,
    clinician_outcome   TEXT,                    -- stored separately from attendance
    outcome_recorded_by UUID REFERENCES tbl_users(id),
    outcome_recorded_at TIMESTAMPTZ,
    booked_by           UUID NOT NULL REFERENCES tbl_users(id),
    confirmed_by        UUID REFERENCES tbl_users(id),
    confirmed_at        TIMESTAMPTZ,
    rescheduled_from_id UUID REFERENCES tbl_hospital_appointments(id),
    idempotency_key     TEXT,
    version             INT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (referral_id, patient_id) REFERENCES tbl_referrals (id, patient_id),
    UNIQUE (id, patient_id),
    UNIQUE (booked_by, idempotency_key)
);
CREATE INDEX idx_appt_referral ON tbl_hospital_appointments (referral_id);
CREATE INDEX idx_appt_sched    ON tbl_hospital_appointments (scheduled_at, status_id);
CREATE TRIGGER trg_tbl_hospital_appointments_updated_at BEFORE UPDATE ON tbl_hospital_appointments
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_appt_booker_role BEFORE INSERT OR UPDATE ON tbl_hospital_appointments
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('booked_by', 'MEDICAL_OFFICER,NAVIGATOR,HOSPITAL_STAFF,SPECIALIST');
CREATE TRIGGER trg_appt_confirmer_role BEFORE INSERT OR UPDATE ON tbl_hospital_appointments
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('confirmed_by', 'HOSPITAL_STAFF,NAVIGATOR,SPECIALIST');

CREATE TABLE tbl_appointment_status_history (    -- APPEND-ONLY; exactly one parent
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    video_consultation_id   UUID REFERENCES tbl_video_consultations(id),
    hospital_appointment_id UUID REFERENCES tbl_hospital_appointments(id),
    from_status_id          BIGINT REFERENCES mst_appointment_statuses(id),
    to_status_id            BIGINT NOT NULL REFERENCES mst_appointment_statuses(id),
    changed_by              UUID NOT NULL REFERENCES tbl_users(id),
    reason                  TEXT,
    changed_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_one_appointment_parent CHECK (num_nonnulls(video_consultation_id, hospital_appointment_id) = 1)
);
CREATE INDEX idx_appt_hist_video ON tbl_appointment_status_history (video_consultation_id);
CREATE INDEX idx_appt_hist_hosp  ON tbl_appointment_status_history (hospital_appointment_id);
CREATE TRIGGER trg_tbl_appointment_status_history_append_only BEFORE UPDATE OR DELETE ON tbl_appointment_status_history
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_investigation_orders (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_id           UUID NOT NULL,
    patient_id            UUID NOT NULL,
    investigation_type_id BIGINT NOT NULL REFERENCES mst_investigation_types(id),
    status_id             BIGINT NOT NULL REFERENCES mst_investigation_statuses(id),
    hospital_id           BIGINT REFERENCES mst_hospitals(id),
    indication            TEXT,                  -- clinical reason (must be clinician-entered)
    ordered_by            UUID NOT NULL REFERENCES tbl_users(id),
    ordered_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    scheduled_at          TIMESTAMPTZ,
    performed_at          TIMESTAMPTZ,           -- performed / sample collected
    report_received_at    TIMESTAMPTZ,
    reviewed_at           TIMESTAMPTZ,
    next_action           TEXT,
    cancel_reason         TEXT,
    due_date              DATE,
    idempotency_key       TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (referral_id, patient_id) REFERENCES tbl_referrals (id, patient_id),
    UNIQUE (id, patient_id),
    UNIQUE (ordered_by, idempotency_key)
);
CREATE INDEX idx_inv_orders_referral ON tbl_investigation_orders (referral_id);
CREATE INDEX idx_inv_orders_patient  ON tbl_investigation_orders (patient_id);
CREATE TRIGGER trg_tbl_investigation_orders_updated_at BEFORE UPDATE ON tbl_investigation_orders
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_inv_orderer_role BEFORE INSERT ON tbl_investigation_orders
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('ordered_by', 'SPECIALIST,MEDICAL_OFFICER');

CREATE TABLE tbl_investigation_status_history (  -- APPEND-ONLY
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id       UUID NOT NULL REFERENCES tbl_investigation_orders(id),
    from_status_id BIGINT REFERENCES mst_investigation_statuses(id),
    to_status_id   BIGINT NOT NULL REFERENCES mst_investigation_statuses(id),
    changed_by     UUID NOT NULL REFERENCES tbl_users(id),
    reason         TEXT,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_inv_hist_order ON tbl_investigation_status_history (order_id, changed_at);
CREATE TRIGGER trg_tbl_investigation_status_history_append_only BEFORE UPDATE OR DELETE ON tbl_investigation_status_history
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_pathology_reports (             -- uploaded documents (simulated in the hackathon)
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        UUID NOT NULL,
    patient_id      UUID NOT NULL,
    doc_kind        TEXT NOT NULL DEFAULT 'PATHOLOGY_REPORT'
                    CHECK (doc_kind IN ('ORDER_FORM','PATHOLOGY_REPORT','IMAGING_REPORT','OTHER')),
    report_key      TEXT NOT NULL UNIQUE,        -- private object key
    checksum_sha256 CHAR(64) NOT NULL,
    mime_type       TEXT NOT NULL CHECK (mime_type IN ('application/pdf','image/jpeg','image/png')),
    is_simulated    BOOLEAN NOT NULL DEFAULT TRUE CHECK (is_simulated),
    summary_text    TEXT,
    uploaded_by     UUID NOT NULL REFERENCES tbl_users(id),
    reported_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (order_id, patient_id) REFERENCES tbl_investigation_orders (id, patient_id),
    UNIQUE (id, patient_id),
    CONSTRAINT ck_report_key_private CHECK (report_key !~* '^(https?:)?//')
);
CREATE INDEX idx_path_reports_order ON tbl_pathology_reports (order_id);

CREATE TABLE tbl_pathology_reviews (             -- diagnosis is ENTERED BY A CLINICIAN, never by AI
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id          UUID NOT NULL,
    patient_id         UUID NOT NULL,
    reviewer_id        UUID NOT NULL REFERENCES tbl_users(id),
    diagnosis_text     TEXT NOT NULL,
    diagnosis_category diagnosis_category NOT NULL,
    next_action        TEXT,
    supersedes_id      UUID REFERENCES tbl_pathology_reviews(id),
    signed_at          TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (report_id, patient_id) REFERENCES tbl_pathology_reports (id, patient_id),
    UNIQUE (id, patient_id)
);
CREATE INDEX idx_path_reviews_report ON tbl_pathology_reviews (report_id);
CREATE TRIGGER trg_pathology_reviewer_role BEFORE INSERT OR UPDATE ON tbl_pathology_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('reviewer_id', 'MEDICAL_OFFICER,SPECIALIST');
CREATE TRIGGER trg_pathology_review_guard BEFORE UPDATE ON tbl_pathology_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_pathology_review_guard();
CREATE TRIGGER trg_pathology_review_no_delete BEFORE DELETE ON tbl_pathology_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

-- Separates: screen-positive abnormality / clinical suspicion / precancer / pathology-confirmed malignancy
CREATE TABLE tbl_case_classifications (          -- APPEND-ONLY history; latest row = current classification
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    seq                 BIGINT GENERATED ALWAYS AS IDENTITY,
    patient_id          UUID NOT NULL,
    screening_id        UUID NOT NULL,
    level               classification_level NOT NULL,
    clinical_review_id  UUID,
    pathology_review_id UUID,
    set_by              UUID NOT NULL REFERENCES tbl_users(id),
    note                TEXT,
    set_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (screening_id, patient_id)        REFERENCES tbl_screenings (id, patient_id),
    FOREIGN KEY (clinical_review_id, patient_id)  REFERENCES tbl_clinical_reviews (id, patient_id),
    FOREIGN KEY (pathology_review_id, patient_id) REFERENCES tbl_pathology_reviews (id, patient_id)
);
CREATE INDEX idx_classification_case ON tbl_case_classifications (screening_id, seq DESC);
CREATE TRIGGER trg_classification_guard BEFORE INSERT ON tbl_case_classifications
    FOR EACH ROW EXECUTE FUNCTION fn_classification_guard();
CREATE TRIGGER trg_tbl_case_classifications_append_only BEFORE UPDATE OR DELETE ON tbl_case_classifications
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_treatment_linkages (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_id         UUID NOT NULL,
    patient_id          UUID NOT NULL,
    pathology_review_id UUID,
    hospital_id         BIGINT REFERENCES mst_hospitals(id),
    linkage_type        TEXT NOT NULL CHECK (linkage_type IN
                          ('SURGERY','RADIOTHERAPY','CHEMOTHERAPY','PALLIATIVE','OBSERVATION','OTHER')),
    status              linkage_status NOT NULL DEFAULT 'PLANNED',
    planned_date        DATE,
    started_on          DATE,
    linked_by           UUID NOT NULL REFERENCES tbl_users(id),
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (referral_id, patient_id)          REFERENCES tbl_referrals (id, patient_id),
    FOREIGN KEY (pathology_review_id, patient_id)  REFERENCES tbl_pathology_reviews (id, patient_id),
    CONSTRAINT ck_linkage_started CHECK (status NOT IN ('STARTED','COMPLETED') OR started_on IS NOT NULL)
);
CREATE INDEX idx_treatment_referral ON tbl_treatment_linkages (referral_id);
CREATE TRIGGER trg_tbl_treatment_linkages_updated_at BEFORE UPDATE ON tbl_treatment_linkages
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_linkage_role BEFORE INSERT ON tbl_treatment_linkages
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('linked_by', 'MEDICAL_OFFICER,SPECIALIST,NAVIGATOR');

-- >>> 06_navigation_governance.sql
-- 06_navigation_governance.sql | Navigation, notifications, offline sync, audit, demo/ops

CREATE TABLE tbl_followup_tasks (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referral_id            UUID NOT NULL,
    patient_id             UUID NOT NULL,
    owner_id               UUID NOT NULL REFERENCES tbl_users(id),   -- navigator
    task_type              followup_task_type NOT NULL,
    trigger_event          TEXT,                                     -- e.g. appointment missed
    related_appointment_id UUID REFERENCES tbl_hospital_appointments(id),
    related_investigation_id UUID REFERENCES tbl_investigation_orders(id),
    missed_reason_id       BIGINT REFERENCES mst_missed_reasons(id),
    priority               SMALLINT NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    due_at                 TIMESTAMPTZ NOT NULL,
    status_id              BIGINT NOT NULL REFERENCES mst_followup_statuses(id),
    accepted_at            TIMESTAMPTZ,
    closed_at              TIMESTAMPTZ,
    closure_reason         TEXT,
    created_by             UUID REFERENCES tbl_users(id),            -- NULL = system generated
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (referral_id, patient_id) REFERENCES tbl_referrals (id, patient_id),
    UNIQUE (id, patient_id),
    CONSTRAINT ck_task_closed CHECK (closed_at IS NULL OR closure_reason IS NOT NULL)
);
CREATE INDEX idx_followup_owner_due ON tbl_followup_tasks (owner_id, due_at) WHERE closed_at IS NULL;
CREATE INDEX idx_followup_patient   ON tbl_followup_tasks (patient_id);
CREATE TRIGGER trg_tbl_followup_tasks_updated_at BEFORE UPDATE ON tbl_followup_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_followup_owner_role BEFORE INSERT OR UPDATE ON tbl_followup_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_require_role('owner_id', 'NAVIGATOR');

CREATE TABLE tbl_patient_contact_history (       -- APPEND-ONLY
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id   UUID NOT NULL REFERENCES tbl_patients(id),
    task_id      UUID,
    contacted_by UUID NOT NULL REFERENCES tbl_users(id),
    channel      contact_channel NOT NULL,
    outcome      contact_outcome NOT NULL,
    notes        TEXT,
    contacted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (task_id, patient_id) REFERENCES tbl_followup_tasks (id, patient_id)
);
CREATE INDEX idx_contact_patient ON tbl_patient_contact_history (patient_id, contacted_at DESC);
CREATE TRIGGER trg_tbl_patient_contact_history_append_only BEFORE UPDATE OR DELETE ON tbl_patient_contact_history
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_transport_support_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         UUID,
    referral_id     UUID NOT NULL,
    patient_id      UUID NOT NULL,
    from_village_id BIGINT REFERENCES mst_villages(id),
    to_hospital_id  BIGINT REFERENCES mst_hospitals(id),
    travel_date     DATE,
    mode            TEXT,
    status          transport_status NOT NULL DEFAULT 'REQUESTED',
    amount_inr      NUMERIC(10,2) CHECK (amount_inr >= 0),
    arranged_by     UUID REFERENCES tbl_users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (referral_id, patient_id) REFERENCES tbl_referrals (id, patient_id),
    FOREIGN KEY (task_id, patient_id)     REFERENCES tbl_followup_tasks (id, patient_id)
);
CREATE INDEX idx_transport_referral ON tbl_transport_support_records (referral_id);
CREATE TRIGGER trg_tbl_transport_support_records_updated_at BEFORE UPDATE ON tbl_transport_support_records
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE tbl_case_escalations (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id      UUID NOT NULL REFERENCES tbl_followup_tasks(id),
    referral_id  UUID NOT NULL REFERENCES tbl_referrals(id),
    level        SMALLINT NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 5),
    escalated_by UUID REFERENCES tbl_users(id),     -- NULL = overdue rule fired
    escalated_to UUID REFERENCES tbl_users(id),
    reason       TEXT NOT NULL,
    status       escalation_status NOT NULL DEFAULT 'OPEN',
    escalated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at  TIMESTAMPTZ
);
CREATE INDEX idx_escalations_task ON tbl_case_escalations (task_id, status);

CREATE TABLE tbl_notifications (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_user_id   UUID REFERENCES tbl_users(id),
    patient_id          UUID REFERENCES tbl_patients(id),
    template_id         BIGINT NOT NULL REFERENCES mst_notification_templates(id),
    channel             notification_channel NOT NULL DEFAULT 'IN_APP',
    language_id         BIGINT REFERENCES mst_languages(id),
    status              notification_status NOT NULL DEFAULT 'PENDING',
    payload             JSONB NOT NULL DEFAULT '{}'::jsonb,   -- no diagnosis or sensitive details
    related_task_id     UUID REFERENCES tbl_followup_tasks(id),
    related_appointment_id UUID REFERENCES tbl_hospital_appointments(id),
    related_video_id    UUID REFERENCES tbl_video_consultations(id),
    attempts            SMALLINT NOT NULL DEFAULT 0,
    last_error          TEXT,
    scheduled_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_notification_recipient CHECK (num_nonnulls(recipient_user_id, patient_id) >= 1),
    CONSTRAINT ck_notification_no_sensitive CHECK (NOT (payload ?| ARRAY['diagnosis','finding','result','pathology','cancer','biopsy','ai']))
);
CREATE INDEX idx_notif_recipient ON tbl_notifications (recipient_user_id, status);
CREATE INDEX idx_notif_patient   ON tbl_notifications (patient_id);
CREATE INDEX idx_notif_due       ON tbl_notifications (scheduled_at) WHERE status = 'PENDING';

CREATE TABLE tbl_offline_sync_queue (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES tbl_users(id),
    device_id           TEXT NOT NULL,
    idempotency_key     TEXT NOT NULL,
    entity_type         TEXT NOT NULL,
    operation           sync_operation NOT NULL,
    payload             JSONB NOT NULL,
    status              sync_status NOT NULL DEFAULT 'PENDING',
    attempts            INT NOT NULL DEFAULT 0,
    last_error          TEXT,
    client_created_at   TIMESTAMPTZ NOT NULL,
    server_ack_at       TIMESTAMPTZ,              -- set ONLY on server acknowledgement
    resulting_entity_id UUID,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, idempotency_key),            -- replays create exactly one record
    CONSTRAINT ck_confirmed_has_ack CHECK (status <> 'CONFIRMED' OR server_ack_at IS NOT NULL)
);
CREATE INDEX idx_sync_status ON tbl_offline_sync_queue (user_id, status);

CREATE TABLE tbl_sync_conflicts (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    queue_id       UUID REFERENCES tbl_offline_sync_queue(id),
    entity_type    TEXT NOT NULL,
    entity_id      UUID NOT NULL,
    local_version  INT,
    server_version INT,
    local_payload  JSONB,
    server_payload JSONB,                          -- both kept: clinician notes never discarded
    resolution     conflict_resolution NOT NULL DEFAULT 'OPEN',
    resolved_by    UUID REFERENCES tbl_users(id),
    resolved_at    TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_conflicts_open ON tbl_sync_conflicts (resolution) WHERE resolution = 'OPEN';

CREATE TABLE tbl_audit_logs (                    -- APPEND-ONLY; metadata must not contain PHI
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_id      UUID REFERENCES tbl_users(id),
    actor_role    TEXT,
    event         TEXT NOT NULL,                  -- IMAGE_VIEW, REVIEW_SIGNED, DIAGNOSIS_ENTERED, ACCESS_DENIED, EXPORT ...
    outcome       TEXT NOT NULL DEFAULT 'SUCCESS' CHECK (outcome IN ('SUCCESS','DENIED','ERROR')),
    resource_type TEXT NOT NULL,
    resource_id   TEXT,
    patient_id    UUID,                           -- no FK: audit must outlive record changes
    ip_address    INET,
    request_id    TEXT,
    metadata      JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX idx_audit_resource   ON tbl_audit_logs (resource_type, resource_id);
CREATE INDEX idx_audit_actor_time ON tbl_audit_logs (actor_id, occurred_at DESC);
CREATE INDEX idx_audit_patient    ON tbl_audit_logs (patient_id, occurred_at DESC);
CREATE TRIGGER trg_tbl_audit_logs_append_only BEFORE UPDATE OR DELETE ON tbl_audit_logs
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_data_exports (                  -- APPEND-ONLY; every export is logged
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exported_by          UUID NOT NULL REFERENCES tbl_users(id),
    export_kind          TEXT NOT NULL,
    filters              JSONB NOT NULL DEFAULT '{}'::jsonb,
    row_count            INT CHECK (row_count >= 0),
    contains_identifiers BOOLEAN NOT NULL DEFAULT FALSE,
    approved_by          UUID REFERENCES tbl_users(id),
    exported_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_identifiable_export_approved CHECK (contains_identifiers = FALSE OR approved_by IS NOT NULL)
);
CREATE TRIGGER trg_tbl_data_exports_append_only BEFORE UPDATE OR DELETE ON tbl_data_exports
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();

CREATE TABLE tbl_demo_datasets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            TEXT NOT NULL UNIQUE,         -- e.g. JURY_12_CASES
    description     TEXT,
    expected_counts JSONB NOT NULL DEFAULT '{}'::jsonb,
    seeded_by       UUID REFERENCES tbl_users(id),
    seeded_at       TIMESTAMPTZ,
    last_reset_at   TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE tbl_system_error_logs (             -- sanitised; no PHI, no secrets
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    service     TEXT NOT NULL,                    -- api / ai / web / sync
    severity    error_severity NOT NULL DEFAULT 'ERROR',
    error_code  TEXT,
    message     TEXT NOT NULL,
    request_id  TEXT,
    user_id     UUID REFERENCES tbl_users(id),
    context     JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX idx_errors_time ON tbl_system_error_logs (occurred_at DESC, severity);

-- >>> 07_functions_views.sql
-- 07_functions_views.sql | Access helper + views (run after all tables)

-- Patient-level access rule for the API (deny by default). The API must ALSO check role permissions.
--  * DISTRICT_ADMIN / SYSTEM_ADMIN: never (aggregate views only)
--  * any clinical user with an ACTIVE care assignment to the patient
--  * HEALTH_WORKER: patients they registered ; MEDICAL_OFFICER: patients of their assigned facility
CREATE FUNCTION fn_user_has_patient_access(p_user UUID, p_patient UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM tbl_users u JOIN mst_roles r ON r.id = u.role_id
     WHERE u.id = p_user AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
       AND r.code NOT IN ('DISTRICT_ADMIN','SYSTEM_ADMIN')
       AND (
            EXISTS (SELECT 1 FROM tbl_case_assignments ca
                     WHERE ca.patient_id = p_patient AND ca.user_id = p_user
                       AND ca.valid_from <= now() AND (ca.valid_to IS NULL OR ca.valid_to > now()))
         OR (r.code = 'HEALTH_WORKER' AND EXISTS (
                SELECT 1 FROM tbl_patients p WHERE p.id = p_patient AND p.registered_by = p_user))
         OR (r.code = 'MEDICAL_OFFICER' AND EXISTS (
                SELECT 1 FROM tbl_patients p
                  JOIN tbl_user_facility_assignments ufa ON ufa.facility_id = p.registered_facility_id
                 WHERE p.id = p_patient AND ufa.user_id = p_user
                   AND ufa.valid_from <= CURRENT_DATE AND (ufa.valid_to IS NULL OR ufa.valid_to >= CURRENT_DATE)))
       )
  );
$$;

-- Current consent state per patient and purpose (latest row wins)
CREATE VIEW vw_patient_current_consents AS
SELECT DISTINCT ON (pc.patient_id, pc.purpose_id)
       pc.patient_id, cp.code AS purpose_code, pc.granted, pc.consent_version, pc.captured_at, pc.id AS consent_id
  FROM tbl_patient_consents pc JOIN mst_consent_purposes cp ON cp.id = pc.purpose_id
 ORDER BY pc.patient_id, pc.purpose_id, pc.consent_seq DESC;

-- Latest classification per screening
CREATE VIEW vw_case_current_classification AS
SELECT DISTINCT ON (screening_id) screening_id, patient_id, level, set_by, set_at
  FROM tbl_case_classifications
 ORDER BY screening_id, seq DESC;

-- Module H: single case timeline (codes / ids only - no free-text clinical content). Filter by patient_id and
-- authorise with fn_user_has_patient_access() before use.
CREATE VIEW vw_patient_timeline AS
          SELECT p.id AS patient_id, p.created_at AS event_time, 'REGISTRATION' AS event_type, 'patient' AS resource_type, p.id AS resource_id, p.registered_by AS actor_id, NULL::text AS detail_code FROM tbl_patients p
UNION ALL SELECT c.patient_id, c.captured_at, CASE WHEN c.granted THEN 'CONSENT_GRANTED' ELSE 'CONSENT_WITHDRAWN' END, 'consent', c.id, c.captured_by, cp.code FROM tbl_patient_consents c JOIN mst_consent_purposes cp ON cp.id = c.purpose_id
UNION ALL SELECT s.patient_id, s.created_at, 'SCREENING', 'screening', s.id, s.examiner_id, s.case_state::text FROM tbl_screenings s
UNION ALL SELECT ph.patient_id, ph.captured_at, 'IMAGE_CAPTURED', 'photo', ph.id, ph.captured_by, ph.view_type::text FROM tbl_screening_photos ph
UNION ALL SELECT s.patient_id, a.requested_at, 'AI_ASSESSMENT', 'ai_assessment', a.id, a.requested_by, a.status::text FROM tbl_ai_assessments a JOIN tbl_screenings s ON s.id = a.screening_id
UNION ALL SELECT cr.patient_id, COALESCE(cr.signed_at, cr.created_at), CASE WHEN cr.signed_at IS NULL THEN 'CLINICAL_REVIEW_DRAFT' ELSE 'CLINICAL_REVIEW_SIGNED' END, 'clinical_review', cr.id, cr.doctor_id, cr.decision::text FROM tbl_clinical_reviews cr
UNION ALL SELECT r.patient_id, r.created_at, 'REFERRAL', 'referral', r.id, r.created_by, r.status::text FROM tbl_referrals r
UNION ALL SELECT v.patient_id, v.created_at, 'VIDEO_CONSULTATION', 'video_consultation', v.id, v.requested_by, v.attendance::text FROM tbl_video_consultations v
UNION ALL SELECT a.patient_id, a.scheduled_at, 'HOSPITAL_APPOINTMENT', 'hospital_appointment', a.id, a.booked_by, a.attendance::text FROM tbl_hospital_appointments a
UNION ALL SELECT o.patient_id, o.ordered_at, 'INVESTIGATION_ORDERED', 'investigation_order', o.id, o.ordered_by, NULL FROM tbl_investigation_orders o
UNION ALL SELECT rp.patient_id, rp.created_at, 'REPORT_UPLOADED', 'pathology_report', rp.id, rp.uploaded_by, rp.doc_kind FROM tbl_pathology_reports rp
UNION ALL SELECT pr.patient_id, COALESCE(pr.signed_at, pr.created_at), 'PATHOLOGY_REVIEWED', 'pathology_review', pr.id, pr.reviewer_id, pr.diagnosis_category::text FROM tbl_pathology_reviews pr
UNION ALL SELECT cc.patient_id, cc.set_at, 'CLASSIFICATION', 'classification', cc.id, cc.set_by, cc.level::text FROM tbl_case_classifications cc
UNION ALL SELECT tl.patient_id, tl.created_at, 'TREATMENT_LINKAGE', 'treatment_linkage', tl.id, tl.linked_by, tl.status::text FROM tbl_treatment_linkages tl
UNION ALL SELECT t.patient_id, t.created_at, 'FOLLOWUP_TASK', 'followup_task', t.id, t.owner_id, t.task_type::text FROM tbl_followup_tasks t
UNION ALL SELECT h.patient_id, h.contacted_at, 'CONTACT_ATTEMPT', 'contact', h.id, h.contacted_by, h.outcome::text FROM tbl_patient_contact_history h;

-- Navigator work queue: open tasks past due
CREATE VIEW vw_overdue_followups AS
SELECT t.id AS task_id, t.patient_id, t.referral_id, t.owner_id, t.task_type, t.due_at, t.priority
  FROM tbl_followup_tasks t JOIN mst_followup_statuses fs ON fs.id = t.status_id
 WHERE t.closed_at IS NULL AND NOT fs.is_terminal AND t.due_at < now();

-- INTERNAL one-row-per-screening fact view (contains patient_id: do NOT expose to admin accounts)
CREATE VIEW vw_case_facts AS
SELECT s.id AS screening_id, s.patient_id, s.screening_date,
       date_trunc('month', s.screening_date)::date AS month_start,
       f.district_id,
       COALESCE(m.id, ph.mandal_id) AS mandal_id,
       p.phc_id, p.village_id, s.case_state,
       (s.case_state NOT IN ('DRAFT','CONSENTED'))               AS is_screened,
       COALESCE(cr.signed_at IS NOT NULL, FALSE)                  AS is_reviewed,
       CASE WHEN cr.signed_at IS NOT NULL
            THEN EXTRACT(EPOCH FROM (cr.signed_at - s.created_at)) / 3600.0 END AS review_hours,
       EXISTS (SELECT 1 FROM tbl_ai_assessments a WHERE a.screening_id = s.id AND a.status = 'COMPLETED'
                  AND a.result_label = 'SUSPICIOUS_FOR_CLINICAL_REVIEW')            AS ai_flagged,
       (COALESCE(cr.decision IN ('SPECIALIST_REVIEW','URGENT_REFERRAL'), FALSE)
        OR COALESCE(cl.level IN ('SCREEN_POSITIVE','CLINICAL_SUSPICION','PRECANCER_CLINICIAN_CONFIRMED',
                                 'MALIGNANCY_PATHOLOGY_CONFIRMED'), FALSE))          AS suspicious_finding,
       (r.id IS NOT NULL)                                          AS is_referred,
       COALESCE(r.assessment_completed_at IS NOT NULL, FALSE)      AS assessment_completed,
       EXISTS (SELECT 1 FROM tbl_hospital_appointments a JOIN mst_appointment_statuses st ON st.id = a.status_id
                WHERE a.referral_id = r.id AND st.code = 'COMPLETED')               AS appointment_completed,
       (EXISTS (SELECT 1 FROM tbl_hospital_appointments a JOIN mst_appointment_statuses st ON st.id = a.status_id
                 WHERE a.referral_id = r.id AND a.scheduled_at < now() AND NOT st.is_terminal)
        OR EXISTS (SELECT 1 FROM tbl_followup_tasks t JOIN mst_followup_statuses fs ON fs.id = t.status_id
                    WHERE t.referral_id = r.id AND t.due_at < now() AND t.closed_at IS NULL AND NOT fs.is_terminal)) AS is_overdue,
       EXISTS (SELECT 1 FROM tbl_investigation_orders o JOIN mst_investigation_types it ON it.id = o.investigation_type_id
                WHERE o.referral_id = r.id AND it.code IN ('BIOPSY','HISTOPATHOLOGY'))   AS biopsy_ordered,
       EXISTS (SELECT 1 FROM tbl_investigation_orders o JOIN mst_investigation_types it ON it.id = o.investigation_type_id
                 JOIN mst_investigation_statuses ist ON ist.id = o.status_id
                WHERE o.referral_id = r.id AND it.code IN ('BIOPSY','HISTOPATHOLOGY') AND NOT ist.is_terminal) AS biopsy_pending,
       EXISTS (SELECT 1 FROM tbl_investigation_orders o JOIN mst_investigation_types it ON it.id = o.investigation_type_id
                 JOIN tbl_pathology_reports rep ON rep.order_id = o.id
                WHERE o.referral_id = r.id AND it.code IN ('BIOPSY','HISTOPATHOLOGY')) AS pathology_received,
       EXISTS (SELECT 1 FROM tbl_pathology_reviews pr JOIN tbl_pathology_reports rep ON rep.id = pr.report_id
                 JOIN tbl_investigation_orders o ON o.id = rep.order_id
                WHERE o.referral_id = r.id AND pr.signed_at IS NOT NULL)             AS pathology_reviewed,
       COALESCE(cl.level = 'PRECANCER_CLINICIAN_CONFIRMED', FALSE)       AS precancer_confirmed,
       COALESCE(cl.level = 'MALIGNANCY_PATHOLOGY_CONFIRMED', FALSE)      AS cancer_confirmed,
       EXISTS (SELECT 1 FROM tbl_treatment_linkages tl WHERE tl.referral_id = r.id
                  AND tl.status IN ('CONFIRMED','STARTED','COMPLETED'))              AS treatment_linked,
       EXISTS (SELECT 1 FROM tbl_treatment_linkages tl WHERE tl.referral_id = r.id
                  AND tl.status IN ('STARTED','COMPLETED'))                          AS treatment_started,
       (s.case_state = 'LOST_CONTACT'
        OR EXISTS (SELECT 1 FROM tbl_treatment_linkages tl WHERE tl.referral_id = r.id AND tl.status = 'LOST')
        OR EXISTS (SELECT 1 FROM tbl_followup_tasks t WHERE t.referral_id = r.id AND t.task_type = 'LOST_CONTACT')) AS lost_to_followup,
       (SELECT EXTRACT(EPOCH FROM (MIN(pr.signed_at) - s.created_at)) / 3600.0
          FROM tbl_pathology_reviews pr JOIN tbl_pathology_reports rep ON rep.id = pr.report_id
          JOIN tbl_investigation_orders o ON o.id = rep.order_id
         WHERE o.referral_id = r.id AND pr.signed_at IS NOT NULL)                    AS diagnosis_hours
  FROM tbl_screenings s
  JOIN tbl_patients p      ON p.id = s.patient_id
  JOIN mst_facilities f    ON f.id = s.facility_id
  LEFT JOIN mst_villages v ON v.id = p.village_id
  LEFT JOIN mst_gram_panchayats gp ON gp.id = v.gram_panchayat_id
  LEFT JOIN mst_mandals m  ON m.id = gp.mandal_id
  LEFT JOIN mst_phcs ph    ON ph.id = p.phc_id
  LEFT JOIN tbl_clinical_reviews cr ON cr.screening_id = s.id
  LEFT JOIN vw_case_current_classification cl ON cl.screening_id = s.id
  LEFT JOIN LATERAL (SELECT r2.* FROM tbl_referrals r2
                      WHERE r2.review_id = cr.id AND r2.status <> 'CANCELLED'
                      ORDER BY r2.created_at DESC LIMIT 1) r ON TRUE;

-- Module J: AGGREGATE ONLY (no patient identifiers). Filter by district / mandal / phc / village / month.
-- Rates are computed by the API from these counts (e.g. referrals / screenings).
-- Production note: suppress small cells (e.g. < 5) before showing village-level figures.
CREATE VIEW vw_district_dashboard_summary AS
SELECT district_id, mandal_id, phc_id, village_id, month_start,
       COUNT(*) FILTER (WHERE is_screened)                          AS screenings_total,
       COUNT(*) FILTER (WHERE is_reviewed)                          AS doctor_reviews,
       COUNT(*) FILTER (WHERE ai_flagged)                           AS ai_flagged_for_review,
       COUNT(*) FILTER (WHERE suspicious_finding)                   AS suspicious_findings,
       COUNT(*) FILTER (WHERE is_referred)                          AS specialist_referrals,
       COUNT(*) FILTER (WHERE appointment_completed)                AS appointments_completed,
       COUNT(*) FILTER (WHERE assessment_completed)                 AS specialist_assessments_completed,
       COUNT(*) FILTER (WHERE is_overdue)                           AS overdue_cases,
       COUNT(*) FILTER (WHERE biopsy_ordered)                       AS biopsies_ordered,
       COUNT(*) FILTER (WHERE biopsy_pending)                       AS biopsies_pending,
       COUNT(*) FILTER (WHERE pathology_reviewed)                   AS pathology_completed,
       COUNT(*) FILTER (WHERE precancer_confirmed)                  AS precancers_clinician_confirmed,
       COUNT(*) FILTER (WHERE cancer_confirmed)                     AS cancers_pathology_confirmed,
       COUNT(*) FILTER (WHERE treatment_linked)                     AS treatment_linked,
       COUNT(*) FILTER (WHERE treatment_started)                    AS treatment_started,
       COUNT(*) FILTER (WHERE lost_to_followup)                     AS lost_to_followup,
       ROUND(AVG(review_hours)::numeric, 1)                         AS avg_hours_to_review,
       ROUND(AVG(diagnosis_hours)::numeric, 1)                      AS avg_hours_to_diagnosis
  FROM vw_case_facts
 GROUP BY district_id, mandal_id, phc_id, village_id, month_start;

-- >>> 08_seed_masters.sql
-- 08_seed_masters.sql | Master seed data (synthetic demo).
-- ALL Telugu (name_te / msg_text / *_te) is a DRAFT: have a qualified Telugu-speaking clinician verify it before real use.

INSERT INTO mst_languages (code, name_en, native_name) VALUES ('en','English','English'), ('te','Telugu','తెలుగు');

INSERT INTO mst_roles (code, name_en, name_te, description, mfa_required) VALUES
 ('HEALTH_WORKER','Village health worker','గ్రామ ఆరోగ్య కార్యకర్త','Registers patients, screening intake, image capture, assigned follow-up',FALSE),
 ('MEDICAL_OFFICER','Medical Officer','వైద్యాధికారి','Reviews findings independently of AI, signs review, decides referral',TRUE),
 ('SPECIALIST','Specialist','నిపుణ వైద్యుడు','Sees referred cases, consultations, investigations',TRUE),
 ('NAVIGATOR','Patient navigator','రోగి మార్గదర్శకుడు','Appointments, contacts, transport, missed-visit workflow',FALSE),
 ('HOSPITAL_STAFF','Hospital staff','ఆసుపత్రి సిబ్బంది','Confirms / reschedules hospital appointments, records attendance',FALSE),
 ('DISTRICT_ADMIN','District administrator','జిల్లా నిర్వాహకుడు','Aggregated programme indicators only; no default access to identifiable records',TRUE),
 ('SYSTEM_ADMIN','System administrator','సిస్టమ్ నిర్వాహకుడు','User management and audit review; no clinical record access',TRUE);

INSERT INTO mst_permissions (code, resource, action, description) VALUES
 ('patient.register','patient','create','Register synthetic patient'),
 ('patient.read_assigned','patient','read','Read patients within a care relationship'),
 ('consent.record','consent','create','Record purpose-specific consent'),
 ('screening.create','screening','create','Create screening and history'),
 ('image.upload','image','create','Upload oral photo for assigned screening'),
 ('image.view','image','read','View image via short-lived signed access (audited)'),
 ('ai.analyze','ai','create','Queue non-clinical AI analysis'),
 ('review.create','review','create','Save clinician observations'),
 ('review.sign','review','sign','Sign clinical review'),
 ('referral.create','referral','create','Create specialist referral'),
 ('referral.view','referral','read','View referrals in care relationship'),
 ('appointment.book','appointment','create','Book or request appointment'),
 ('appointment.confirm','appointment','confirm','Confirm / reschedule hospital appointment, record attendance'),
 ('appointment.view','appointment','read','View appointments'),
 ('video.join','video','join','Join authorised video consultation'),
 ('consultation.note','consultation','create','Record consultation notes and outcome'),
 ('investigation.record','investigation','create','Order / track biopsy and investigations'),
 ('pathology.review','pathology','review','Enter diagnosis on a pathology report'),
 ('classification.set','classification','create','Set clinician classification'),
 ('treatment.link','treatment','create','Create treatment linkage'),
 ('treatment.track','treatment','update','Track treatment initiation'),
 ('navigation.update','navigation','update','Track contact and attendance'),
 ('case.assign','case','assign','Assign care team / navigator'),
 ('dashboard.view_aggregate','dashboard','read','View aggregate reporting'),
 ('export.aggregate','export','create','Export aggregate report'),
 ('user.manage','user','manage','Manage users and assignments'),
 ('registration.review','registration','review','Approve / reject health worker registration requests'),
 ('audit.view','audit','read','View audit trail');

INSERT INTO tbl_role_permissions (role_id, permission_id)
SELECT r.id, p.id
  FROM (VALUES
   ('HEALTH_WORKER','patient.register'),('HEALTH_WORKER','patient.read_assigned'),('HEALTH_WORKER','consent.record'),
   ('HEALTH_WORKER','screening.create'),('HEALTH_WORKER','image.upload'),('HEALTH_WORKER','image.view'),('HEALTH_WORKER','ai.analyze'),
   ('MEDICAL_OFFICER','patient.read_assigned'),('MEDICAL_OFFICER','image.view'),('MEDICAL_OFFICER','review.create'),
   ('MEDICAL_OFFICER','review.sign'),('MEDICAL_OFFICER','referral.create'),('MEDICAL_OFFICER','referral.view'),
   ('MEDICAL_OFFICER','appointment.book'),('MEDICAL_OFFICER','appointment.view'),('MEDICAL_OFFICER','video.join'),
   ('MEDICAL_OFFICER','investigation.record'),('MEDICAL_OFFICER','classification.set'),('MEDICAL_OFFICER','case.assign'),
   ('SPECIALIST','patient.read_assigned'),('SPECIALIST','image.view'),('SPECIALIST','referral.view'),
   ('SPECIALIST','appointment.view'),('SPECIALIST','video.join'),('SPECIALIST','consultation.note'),
   ('SPECIALIST','investigation.record'),('SPECIALIST','pathology.review'),('SPECIALIST','classification.set'),('SPECIALIST','treatment.link'),
   ('NAVIGATOR','patient.read_assigned'),('NAVIGATOR','referral.view'),('NAVIGATOR','appointment.book'),
   ('NAVIGATOR','appointment.view'),('NAVIGATOR','navigation.update'),('NAVIGATOR','treatment.track'),
   ('HOSPITAL_STAFF','patient.read_assigned'),('HOSPITAL_STAFF','referral.view'),('HOSPITAL_STAFF','appointment.view'),('HOSPITAL_STAFF','appointment.confirm'),
   ('DISTRICT_ADMIN','dashboard.view_aggregate'),('DISTRICT_ADMIN','export.aggregate'),
   ('SYSTEM_ADMIN','user.manage'),('SYSTEM_ADMIN','registration.review'),('SYSTEM_ADMIN','audit.view')
  ) AS m(role_code, perm_code)
  JOIN mst_roles r ON r.code = m.role_code
  JOIN mst_permissions p ON p.code = m.perm_code;

INSERT INTO mst_appointment_statuses (code, name_en, name_te, is_terminal, sort_order) VALUES
 ('REQUESTED','Requested','అభ్యర్థించబడింది',FALSE,1),('CONFIRMED','Confirmed','నిర్ధారించబడింది',FALSE,2),
 ('RESCHEDULED','Rescheduled','తిరిగి షెడ్యూల్ చేయబడింది',TRUE,3),('COMPLETED','Completed','పూర్తయింది',TRUE,4),
 ('MISSED','Missed','హాజరు కాలేదు',TRUE,5),('CANCELLED','Cancelled','రద్దు చేయబడింది',TRUE,6);

INSERT INTO mst_investigation_statuses (code, name_en, name_te, is_terminal, sort_order) VALUES
 ('ADVISED','Advised','సూచించబడింది',FALSE,1),('SCHEDULED','Scheduled','షెడ్యూల్ చేయబడింది',FALSE,2),
 ('SAMPLE_COLLECTED','Performed / sample collected','నమూనా సేకరించబడింది',FALSE,3),
 ('REPORT_PENDING','Report pending','నివేదిక పెండింగ్‌లో ఉంది',FALSE,4),
 ('REPORT_RECEIVED','Report received','నివేదిక అందింది',FALSE,5),
 ('CLINICIAN_REVIEWED','Clinician reviewed','వైద్యుడు సమీక్షించారు',TRUE,6),
 ('CANCELLED','Cancelled','రద్దు చేయబడింది',TRUE,7);

INSERT INTO mst_followup_statuses (code, name_en, name_te, is_terminal, sort_order) VALUES
 ('OPEN','Open','తెరిచి ఉంది',FALSE,1),('IN_PROGRESS','In progress','పురోగతిలో ఉంది',FALSE,2),
 ('ESCALATED','Escalated','ఉన్నత స్థాయికి పంపబడింది',FALSE,3),('CLOSED','Closed','ముగించబడింది',TRUE,4);

INSERT INTO mst_missed_reasons (code, name_en, name_te) VALUES
 ('TRANSPORT','No transport / distance','రవాణా సమస్య'),('TRAVEL_COST','Cost of travel','ప్రయాణ ఖర్చు'),
 ('WORK_FARMING','Work / farming','పని / వ్యవసాయ పనులు'),('FORGOT','Forgot','మర్చిపోయారు'),
 ('FEAR','Fear / anxiety','భయం / ఆందోళన'),('FAMILY','Family reason','కుటుంబ కారణాలు'),
 ('ROAD_WEATHER','Road / weather problem','రోడ్డు / వాతావరణ సమస్య'),('HOSPITAL_RESCHEDULED','Hospital rescheduled','ఆసుపత్రి తేదీ మార్చింది'),
 ('UNREACHABLE','Could not be contacted','సంప్రదించలేకపోయాం'),('OTHER','Other','ఇతర');

INSERT INTO mst_referral_priorities (code, name_en, name_te, priority_rank, target_days) VALUES   -- target_days: clinical protocol decides
 ('URGENT','Urgent','అత్యవసరం',1,NULL),('SOON','Soon','త్వరగా',2,NULL),('ROUTINE','Routine','సాధారణం',3,NULL);

INSERT INTO mst_consent_purposes (code, name_en, name_te, text_en, is_required) VALUES
 ('SCREENING','Oral screening examination','నోటి పరీక్ష','I agree to a demonstration oral screening examination (synthetic data only).',TRUE),
 ('IMAGE_CAPTURE','Photograph capture','ఫోటో తీయడం','I agree to oral photographs being taken for this demonstration.',TRUE),
 ('TELECONSULT','Video consultation','వీడియో సంప్రదింపు','I agree to a video consultation with a specialist (not recorded).',FALSE),
 ('DATA_PROCESSING','Data processing','డేటా ప్రాసెసింగ్','I agree to my demonstration record being stored and processed securely.',TRUE),
 ('AI_RESEARCH','Research AI demonstration','పరిశోధన AI ప్రదర్శన','I understand the AI output is a research demonstration, not a diagnosis.',FALSE);

INSERT INTO mst_exposure_types (code, name_en, name_te, category) VALUES
 ('SMOKED_TOBACCO','Smoked tobacco','పొగాకు తాగడం','TOBACCO'),
 ('SMOKELESS_TOBACCO','Chewing tobacco','పొగాకు నమలడం','TOBACCO'),
 ('GUTKHA','Gutkha','గుట్కా','TOBACCO'),
 ('REVERSE_SMOKING','Reverse smoking','రివర్స్ స్మోకింగ్','TOBACCO'),
 ('ARECA_NUT','Areca nut / betel quid','వక్క / తాంబూలం','ARECA'),
 ('ALCOHOL','Alcohol','మద్యం','ALCOHOL');

INSERT INTO mst_symptoms (code, name_en, name_te) VALUES
 ('MOUTH_ULCER','Non-healing mouth ulcer','మానని నోటి పుండు'),('WHITE_PATCH','White patch','తెల్లని మచ్చ'),
 ('RED_PATCH','Red patch','ఎర్రని మచ్చ'),('PAIN','Pain in mouth','నోటిలో నొప్పి'),
 ('DIFFICULTY_SWALLOWING','Difficulty swallowing','మింగడంలో ఇబ్బంది'),('LIMITED_MOUTH_OPENING','Limited mouth opening','నోరు తెరవడంలో ఇబ్బంది'),
 ('BLEEDING','Bleeding','రక్తస్రావం'),('VISIBLE_GROWTH','Visible growth / lump','నోటిలో గడ్డ'),
 ('NECK_SWELLING','Neck swelling','మెడలో వాపు');

INSERT INTO mst_investigation_types (code, name_en, name_te) VALUES
 ('CLINICAL_REEXAM','Specialist clinical re-examination','నిపుణుల తిరిగి పరీక్ష'),('BIOPSY','Biopsy','బయాప్సీ'),
 ('HISTOPATHOLOGY','Histopathology','హిస్టోపాథాలజీ'),('CT','CT scan','సిటి స్కాన్'),('MRI','MRI scan','ఎంఆర్‌ఐ స్కాన్'),('OTHER','Other investigation','ఇతర పరీక్ష');

INSERT INTO mst_specialties (code, name_en, name_te) VALUES
 ('ORAL_MEDICINE','Oral medicine','ఓరల్ మెడిసిన్'),('ORAL_SURGERY','Oral & maxillofacial surgery','నోరు మరియు దవడ శస్త్రచికిత్స'),
 ('ENT','ENT','చెవి ముక్కు గొంతు (ENT)'),('ONCOLOGY','Oncology','ఆంకాలజీ'),('PATHOLOGY','Pathology','పాథాలజీ');

INSERT INTO mst_ai_models (provider, model_version, description, supports_localization, is_research_only, clinical_use) VALUES
 ('mock','mock-v1','Mock adapter returning fixed example labels. NOT FOR CLINICAL USE',FALSE,TRUE,FALSE);

-- Clinical protocol rules: PLACEHOLDER values only - to be replaced by approved protocol
INSERT INTO mst_protocol_rules (code, rule_type, applies_to, offset_minutes, template_code, escalation_level, notes) VALUES
 ('APPT_REMINDER_24H','REMINDER','HOSPITAL_APPOINTMENT',-1440,'APPT_REMINDER',NULL,'Placeholder'),
 ('APPT_REMINDER_2H','REMINDER','HOSPITAL_APPOINTMENT',-120,'APPT_REMINDER',NULL,'Placeholder'),
 ('VIDEO_REMINDER_1H','REMINDER','VIDEO_CONSULTATION',-60,'APPT_REMINDER',NULL,'Placeholder'),
 ('MISSED_APPT_TASK','FOLLOWUP_TASK','HOSPITAL_APPOINTMENT',60,'MISSED_VISIT',NULL,'Create navigator task after missed appointment'),
 ('REFERRAL_OVERDUE_L1','OVERDUE_ESCALATION','REFERRAL',4320,'FOLLOWUP_REMINDER',1,'Placeholder'),
 ('REFERRAL_OVERDUE_L2','OVERDUE_ESCALATION','REFERRAL',10080,'FOLLOWUP_REMINDER',2,'Placeholder');

INSERT INTO mst_notification_templates (code, language_id, channel, subject, body)
SELECT t.code, l.id, 'IN_APP'::notification_channel, t.subject, t.body
  FROM (VALUES
   ('APPT_REMINDER','en','Appointment reminder','Reminder: you have an upcoming appointment. Please contact your health worker for details.'),
   ('APPT_REMINDER','te','అపాయింట్‌మెంట్ రిమైండర్','గుర్తు చేస్తున్నాము: మీకు త్వరలో అపాయింట్‌మెంట్ ఉంది. వివరాల కోసం దయచేసి మీ ఆరోగ్య కార్యకర్తను సంప్రదించండి.'),
   ('FOLLOWUP_REMINDER','en','Follow-up reminder','Your follow-up visit is pending. Please contact your health worker.'),
   ('FOLLOWUP_REMINDER','te','ఫాలో-అప్ రిమైండర్','మీ ఫాలో-అప్ సందర్శన పెండింగ్‌లో ఉంది. దయచేసి మీ ఆరోగ్య కార్యకర్తను సంప్రదించండి.'),
   ('MISSED_VISIT','en','Missed visit','We missed you at your appointment. Please contact us to choose a new date.'),
   ('MISSED_VISIT','te','హాజరు కాలేదు','మీరు అపాయింట్‌మెంట్‌కు రాలేకపోయారు. కొత్త తేదీ కోసం దయచేసి సంప్రదించండి.')
  ) AS t(code, lang, subject, body)
  JOIN mst_languages l ON l.code = t.lang;

INSERT INTO mst_ui_translations (msg_key, language_id, msg_text, module)
SELECT t.k, l.id, t.txt, t.module
  FROM (VALUES
   ('app.title','en','Aarogya Drishti','common'),('app.title','te','ఆరోగ్య దృష్టి','common'),
   ('common.save','en','Save','common'),('common.save','te','సేవ్ చేయండి','common'),
   ('common.cancel','en','Cancel','common'),('common.cancel','te','రద్దు చేయండి','common'),
   ('common.next','en','Next','common'),('common.next','te','తరువాత','common'),
   ('common.retake','en','Retake photo','screening'),('common.retake','te','మళ్లీ ఫోటో తీయండి','screening'),
   ('login.title','en','Login','auth'),('login.title','te','లాగిన్','auth'),
   ('sync.pending','en','Waiting to sync','sync'),('sync.pending','te','సమకాలీకరణ కోసం వేచి ఉంది','sync'),
   ('sync.confirmed','en','Synced','sync'),('sync.confirmed','te','సమకాలీకరించబడింది','sync'),
   ('ai.not_for_clinical_use','en','NOT FOR CLINICAL USE','ai'),('ai.not_for_clinical_use','te','వైద్య వినియోగానికి కాదు','ai'),
   ('ai.image_insufficient','en','Image insufficient','ai'),('ai.image_insufficient','te','చిత్రం సరిపోదు','ai'),
   ('error.network','en','Network error. Please try again.','error'),('error.network','te','నెట్‌వర్క్ లోపం. దయచేసి మళ్లీ ప్రయత్నించండి.','error'),
   ('error.required','en','This field is required','error'),('error.required','te','ఈ వివరం అవసరం','error'),
   ('error.consent_required','en','Consent is required first','error'),('error.consent_required','te','ముందుగా సమ్మతి అవసరం','error'),
   ('error.access_denied','en','You do not have access to this record','error'),('error.access_denied','te','ఈ రికార్డును చూడటానికి మీకు అనుమతి లేదు','error'),
   ('image.recapture','en','Image is not clear. Please retake.','screening'),('image.recapture','te','చిత్రం స్పష్టంగా లేదు. దయచేసి మళ్లీ తీయండి.','screening')
  ) AS t(k, lang, txt, module)
  JOIN mst_languages l ON l.code = t.lang;

-- Geography (demo subset - replace placeholder GP / village / PHC / hospital rows with official master data)
INSERT INTO mst_districts (code, name_en, name_te) VALUES ('ASR','Alluri Sitharama Raju','అల్లూరి సీతారామరాజు');
INSERT INTO mst_mandals (district_id, code, name_en, name_te)
SELECT d.id, m.code, m.en, m.te FROM mst_districts d,
 (VALUES ('PADERU','Paderu','పాడేరు'),('G_MADUGULA','G. Madugula','జి. మాడుగుల'),('HUKUMPETA','Hukumpeta','హుకుంపేట')) AS m(code,en,te)
 WHERE d.code = 'ASR';
INSERT INTO mst_gram_panchayats (mandal_id, code, name_en) SELECT id, 'GP_DEMO_GM', 'Demo Gram Panchayat (G. Madugula)' FROM mst_mandals WHERE code = 'G_MADUGULA';
INSERT INTO mst_villages (gram_panchayat_id, code, name_en)
SELECT g.id, v.code, v.name FROM mst_gram_panchayats g, (VALUES ('VIL_DEMO_1','Demo Village 1'),('VIL_DEMO_2','Demo Village 2')) AS v(code,name) WHERE g.code = 'GP_DEMO_GM';
INSERT INTO mst_phcs (mandal_id, code, name_en)
SELECT id, 'PHC_GM_DEMO', 'PHC G. Madugula (demo)' FROM mst_mandals WHERE code = 'G_MADUGULA';
INSERT INTO mst_hospitals (district_id, code, name_en, level)
SELECT
    d.id,
    h.code,
    h.name,
    h.lvl
FROM mst_districts AS d
CROSS JOIN (
    VALUES
        ('AH_PADERU_DEMO', 'Area Hospital Paderu (demo)', 'AH'),
        ('RCC_DEMO', 'Regional Cancer Centre (demo)', 'TERTIARY')
) AS h(code, name, lvl)
WHERE d.code = 'ASR';
INSERT INTO mst_facilities (district_id, facility_type, phc_id, hospital_id, code, name_en)
SELECT d.id, 'PHC', p.id, NULL, 'FAC_PHC_GM', p.name_en FROM mst_districts d, mst_phcs p WHERE d.code = 'ASR' AND p.code = 'PHC_GM_DEMO';
INSERT INTO mst_facilities (district_id, facility_type, phc_id, hospital_id, code, name_en)
SELECT d.id, 'HOSPITAL', NULL, h.id, 'FAC_' || h.code, h.name_en FROM mst_districts d, mst_hospitals h WHERE d.code = 'ASR';
INSERT INTO mst_facilities (district_id, facility_type, code, name_en)
SELECT id, 'DISTRICT_OFFICE', 'FAC_DISTRICT_OFFICE', 'District office (demo)' FROM mst_districts WHERE code = 'ASR';

COMMIT;
