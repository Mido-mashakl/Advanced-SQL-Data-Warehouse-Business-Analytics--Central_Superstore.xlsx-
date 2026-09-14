-- This file is dedicated for building the different data warehouse layers
-- The first layer is the stagging layer where we are going to build
-- identical table that reflects the file of data
-- NOTES:
    -- the first note here is to reflect the same structure of the flat file
    -- the second note is to use the NVARCHAR(255) which is the biggest size of the char datatype
    -- this is for ensuring we are going to contain all the data regardless the size.
-- healthcare_dwh_s3

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'healthcare_dwh_s3')
    CREATE DATABASE healthcare_dwh_s3;


USE healthcare_dwh_s3;

-- Schemas for the four data warehouse layers
SELECT *
FROM sys.schemas;

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'staging')
    EXEC('CREATE SCHEMA staging');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze')
    EXEC('CREATE SCHEMA bronze');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')
    EXEC('CREATE SCHEMA silver');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')
    EXEC('CREATE SCHEMA gold');
GO

-- Now, we have the four schema we need to have the staging, bronze, silver, and gold one
-- Now, is the time for creating the table raw_encounters
-- Check the existnce of table before creating it

CREATE TABLE staging.raw_encounters (
    patient_id NVARCHAR(255),
    birth_year NVARCHAR(255),
    age NVARCHAR(255),
    sex NVARCHAR(255),
    race_ethnicity NVARCHAR(255),
    state NVARCHAR(255),
    encounter_id NVARCHAR(255),
    icd10_code NVARCHAR(255),
    diagnosis_display NVARCHAR(255),
    diagnosis_category NVARCHAR(255),
    severity_index NVARCHAR(255),
    comorbidity_count NVARCHAR(255),
    has_diabetes NVARCHAR(255),
    has_hypertension NVARCHAR(255),
    has_chf NVARCHAR(255),
    sbp_mmhg NVARCHAR(255),
    dbp_mmhg NVARCHAR(255),
    heart_rate_bpm NVARCHAR(255),
    spo2_pct NVARCHAR(255),
    temperature_f NVARCHAR(255),
    bmi NVARCHAR(255),
    respiratory_rate NVARCHAR(255),
    hba1c_pct NVARCHAR(255),
    glucose_mg_dl NVARCHAR(255),
    creatinine_mg_dl NVARCHAR(255),
    wbc_10e3_ul NVARCHAR(255),
    nt_probnp_pg_ml NVARCHAR(255),
    medication_adherence_pdc NVARCHAR(255),
    readmission_30d_flag NVARCHAR(255),
    triage_timestamp NVARCHAR(255),
    admit_timestamp NVARCHAR(255),
    bed_request_time NVARCHAR(255),
    bed_assign_time NVARCHAR(255),
    unit_assigned NVARCHAR(255),
    bed_occupancy_pct NVARCHAR(255),
    cpt_code NVARCHAR(255),
    procedure_display NVARCHAR(255),
    or_start NVARCHAR(255),
    or_end NVARCHAR(255),
    actual_or_minutes NVARCHAR(255),
    or_turnover_minutes NVARCHAR(255),
    los_days NVARCHAR(255),
    discharge_timestamp NVARCHAR(255),
    safety_incident_flag NVARCHAR(255),
    incident_type NVARCHAR(255),
    incident_severity NVARCHAR(255),
    claim_id NVARCHAR(255),
    payer NVARCHAR(255),
    npi_billing NVARCHAR(255),
    drg_weight NVARCHAR(255),
    submitted_charge_usd NVARCHAR(255),
    allowed_amount_usd NVARCHAR(255),
    patient_responsibility_usd NVARCHAR(255),
    fraud_upcoding_flag NVARCHAR(255),
    fraud_duplicate_flag NVARCHAR(255),
    fraud_unbundling_flag NVARCHAR(255),
    nurse_emp_id NVARCHAR(255),
    nurse_role NVARCHAR(255),
    nurse_unit NVARCHAR(255),
    nurse_tenure_years NVARCHAR(255),
    nurse_fte NVARCHAR(255),
    surgeon_emp_id NVARCHAR(255),
    surgeon_specialty NVARCHAR(255),
    shift_hours NVARCHAR(255),
    patients_per_nurse_ratio NVARCHAR(255),
    overtime_hours NVARCHAR(255),
    burnout_exhaustion_mbi NVARCHAR(255),
    burnout_cynicism_mbi NVARCHAR(255),
    burnout_personal_accomplishment_mbi NVARCHAR(255),
    turnover_risk_index NVARCHAR(255),
    cahps_nurse_communication NVARCHAR(255),
    cahps_doctor_communication NVARCHAR(255),
    cahps_responsiveness NVARCHAR(255),
    cahps_pain_management NVARCHAR(255),
    cahps_discharge_info NVARCHAR(255),
    cahps_care_transition NVARCHAR(255),
    cahps_cleanliness NVARCHAR(255),
    cahps_quietness NVARCHAR(255),
    surgical_kit_id NVARCHAR(255),
    kit_name NVARCHAR(255),
    kit_unit_cost_usd NVARCHAR(255),
    kit_current_stock NVARCHAR(255),
    kit_reorder_point NVARCHAR(255),
    kit_lead_time_days NVARCHAR(255),
    kit_expiration_date NVARCHAR(255),
    stockout_risk_flag NVARCHAR(255),
    weekly_procedure_volume NVARCHAR(255),
    projected_demand_4wk NVARCHAR(255),
    days_of_supply NVARCHAR(255),
    hedis_hba1c_tested NVARCHAR(255),
    hedis_hba1c_poor_control NVARCHAR(255),
    pdsa_cycle_id NVARCHAR(255),
    himss_emram_stage NVARCHAR(255)
);
SELECT *
FROM staging.raw_encounters;
-- Now, we are going to start reading the data from the file into the stagging table.
-- Here is our decision to build the staging area as full loading area with truncating
-- all the data inside the table first then we start loading the new data into it
-- It is a full truncate loading data
TRUNCATE TABLE staging.raw_encounters;

BULK INSERT staging.raw_encounters
FROM 'C:\Users\waleed\Documents\data_warehouse_project\encounters_50k.csv'
WITH (
    FIRSTROW = 2,              -- skip the header row
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"', -- Properly read the comma inside the double quotations
    CODEPAGE = '65001',        -- UTF-8
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\waleed\Documents\data_warehouse_project\raw_encounters_err.log'
);

select * from staging.raw_encounters;

-- ============================================================
-- BRONZE LAYER
-- ============================================================
-- Scope of this layer (kept intentionally narrow):
--   1. Incremental loading: bronze is append-only, never truncated.
--      Each run only adds rows that are not already present.
--   2. Deduplication is on the FULL ROW, not just encounter_id.
--      A row is skipped only if every column matches a row already
--      in bronze (true duplicate, e.g. an unchanged reload). If any
--      column differs for the same encounter_id (a correction /
--      update from source), it is inserted as a new row instead of
--      being silently dropped -- this is what lets silver later
--      upsert on encounter_id using the latest version.
--   3. bronze_id is a plain surrogate IDENTITY, used only so silver
--      can tell which bronze row for a given encounter_id is the
--      most recent (MAX(bronze_id)). It is not full load metadata
--      (batch id, load timestamp, etc.), which is still deferred.


CREATE TABLE bronze.encounters (
    bronze_id INT IDENTITY(1,1) PRIMARY KEY,
    patient_id NVARCHAR(255),
    birth_year NVARCHAR(255),
    age NVARCHAR(255),
    sex NVARCHAR(255),
    race_ethnicity NVARCHAR(255),
    state NVARCHAR(255),
    encounter_id NVARCHAR(255),
    icd10_code NVARCHAR(255),
    diagnosis_display NVARCHAR(255),
    diagnosis_category NVARCHAR(255),
    severity_index NVARCHAR(255),
    comorbidity_count NVARCHAR(255),
    has_diabetes NVARCHAR(255),
    has_hypertension NVARCHAR(255),
    has_chf NVARCHAR(255),
    sbp_mmhg NVARCHAR(255),
    dbp_mmhg NVARCHAR(255),
    heart_rate_bpm NVARCHAR(255),
    spo2_pct NVARCHAR(255),
    temperature_f NVARCHAR(255),
    bmi NVARCHAR(255),
    respiratory_rate NVARCHAR(255),
    hba1c_pct NVARCHAR(255),
    glucose_mg_dl NVARCHAR(255),
    creatinine_mg_dl NVARCHAR(255),
    wbc_10e3_ul NVARCHAR(255),
    nt_probnp_pg_ml NVARCHAR(255),
    medication_adherence_pdc NVARCHAR(255),
    readmission_30d_flag NVARCHAR(255),
    triage_timestamp NVARCHAR(255),
    admit_timestamp NVARCHAR(255),
    bed_request_time NVARCHAR(255),
    bed_assign_time NVARCHAR(255),
    unit_assigned NVARCHAR(255),
    bed_occupancy_pct NVARCHAR(255),
    cpt_code NVARCHAR(255),
    procedure_display NVARCHAR(255),
    or_start NVARCHAR(255),
    or_end NVARCHAR(255),
    actual_or_minutes NVARCHAR(255),
    or_turnover_minutes NVARCHAR(255),
    los_days NVARCHAR(255),
    discharge_timestamp NVARCHAR(255),
    safety_incident_flag NVARCHAR(255),
    incident_type NVARCHAR(255),
    incident_severity NVARCHAR(255),
    claim_id NVARCHAR(255),
    payer NVARCHAR(255),
    npi_billing NVARCHAR(255),
    drg_weight NVARCHAR(255),
    submitted_charge_usd NVARCHAR(255),
    allowed_amount_usd NVARCHAR(255),
    patient_responsibility_usd NVARCHAR(255),
    fraud_upcoding_flag NVARCHAR(255),
    fraud_duplicate_flag NVARCHAR(255),
    fraud_unbundling_flag NVARCHAR(255),
    nurse_emp_id NVARCHAR(255),
    nurse_role NVARCHAR(255),
    nurse_unit NVARCHAR(255),
    nurse_tenure_years NVARCHAR(255),
    nurse_fte NVARCHAR(255),
    surgeon_emp_id NVARCHAR(255),
    surgeon_specialty NVARCHAR(255),
    shift_hours NVARCHAR(255),
    patients_per_nurse_ratio NVARCHAR(255),
    overtime_hours NVARCHAR(255),
    burnout_exhaustion_mbi NVARCHAR(255),
    burnout_cynicism_mbi NVARCHAR(255),
    burnout_personal_accomplishment_mbi NVARCHAR(255),
    turnover_risk_index NVARCHAR(255),
    cahps_nurse_communication NVARCHAR(255),
    cahps_doctor_communication NVARCHAR(255),
    cahps_responsiveness NVARCHAR(255),
    cahps_pain_management NVARCHAR(255),
    cahps_discharge_info NVARCHAR(255),
    cahps_care_transition NVARCHAR(255),
    cahps_cleanliness NVARCHAR(255),
    cahps_quietness NVARCHAR(255),
    surgical_kit_id NVARCHAR(255),
    kit_name NVARCHAR(255),
    kit_unit_cost_usd NVARCHAR(255),
    kit_current_stock NVARCHAR(255),
    kit_reorder_point NVARCHAR(255),
    kit_lead_time_days NVARCHAR(255),
    kit_expiration_date NVARCHAR(255),
    stockout_risk_flag NVARCHAR(255),
    weekly_procedure_volume NVARCHAR(255),
    projected_demand_4wk NVARCHAR(255),
    days_of_supply NVARCHAR(255),
    hedis_hba1c_tested NVARCHAR(255),
    hedis_hba1c_poor_control NVARCHAR(255),
    pdsa_cycle_id NVARCHAR(255),
    himss_emram_stage NVARCHAR(255)
);

-- Incremental + deduplicated load: full-row anti-join via EXCEPT.
-- Only staging rows whose complete set of column values does not
-- already exist in bronze are inserted. An unchanged reload matches
-- exactly and is skipped; a corrected/updated row for the same
-- encounter_id differs in at least one column and flows through as
-- a new bronze_id version.
INSERT INTO bronze.encounters (
    patient_id, birth_year, age, sex, race_ethnicity, state, encounter_id,
    icd10_code, diagnosis_display, diagnosis_category, severity_index,
    comorbidity_count, has_diabetes, has_hypertension, has_chf, sbp_mmhg,
    dbp_mmhg, heart_rate_bpm, spo2_pct, temperature_f, bmi, respiratory_rate,
    hba1c_pct, glucose_mg_dl, creatinine_mg_dl, wbc_10e3_ul, nt_probnp_pg_ml,
    medication_adherence_pdc, readmission_30d_flag, triage_timestamp,
    admit_timestamp, bed_request_time, bed_assign_time, unit_assigned,
    bed_occupancy_pct, cpt_code, procedure_display, or_start, or_end,
    actual_or_minutes, or_turnover_minutes, los_days, discharge_timestamp,
    safety_incident_flag, incident_type, incident_severity, claim_id, payer,
    npi_billing, drg_weight, submitted_charge_usd, allowed_amount_usd,
    patient_responsibility_usd, fraud_upcoding_flag, fraud_duplicate_flag,
    fraud_unbundling_flag, nurse_emp_id, nurse_role, nurse_unit,
    nurse_tenure_years, nurse_fte, surgeon_emp_id, surgeon_specialty,
    shift_hours, patients_per_nurse_ratio, overtime_hours,
    burnout_exhaustion_mbi, burnout_cynicism_mbi,
    burnout_personal_accomplishment_mbi, turnover_risk_index,
    cahps_nurse_communication, cahps_doctor_communication,
    cahps_responsiveness, cahps_pain_management, cahps_discharge_info,
    cahps_care_transition, cahps_cleanliness, cahps_quietness,
    surgical_kit_id, kit_name, kit_unit_cost_usd, kit_current_stock,
    kit_reorder_point, kit_lead_time_days, kit_expiration_date,
    stockout_risk_flag, weekly_procedure_volume, projected_demand_4wk,
    days_of_supply, hedis_hba1c_tested, hedis_hba1c_poor_control,
    pdsa_cycle_id, himss_emram_stage
)
SELECT
    patient_id, birth_year, age, sex, race_ethnicity, state, encounter_id,
    icd10_code, diagnosis_display, diagnosis_category, severity_index,
    comorbidity_count, has_diabetes, has_hypertension, has_chf, sbp_mmhg,
    dbp_mmhg, heart_rate_bpm, spo2_pct, temperature_f, bmi, respiratory_rate,
    hba1c_pct, glucose_mg_dl, creatinine_mg_dl, wbc_10e3_ul, nt_probnp_pg_ml,
    medication_adherence_pdc, readmission_30d_flag, triage_timestamp,
    admit_timestamp, bed_request_time, bed_assign_time, unit_assigned,
    bed_occupancy_pct, cpt_code, procedure_display, or_start, or_end,
    actual_or_minutes, or_turnover_minutes, los_days, discharge_timestamp,
    safety_incident_flag, incident_type, incident_severity, claim_id, payer,
    npi_billing, drg_weight, submitted_charge_usd, allowed_amount_usd,
    patient_responsibility_usd, fraud_upcoding_flag, fraud_duplicate_flag,
    fraud_unbundling_flag, nurse_emp_id, nurse_role, nurse_unit,
    nurse_tenure_years, nurse_fte, surgeon_emp_id, surgeon_specialty,
    shift_hours, patients_per_nurse_ratio, overtime_hours,
    burnout_exhaustion_mbi, burnout_cynicism_mbi,
    burnout_personal_accomplishment_mbi, turnover_risk_index,
    cahps_nurse_communication, cahps_doctor_communication,
    cahps_responsiveness, cahps_pain_management, cahps_discharge_info,
    cahps_care_transition, cahps_cleanliness, cahps_quietness,
    surgical_kit_id, kit_name, kit_unit_cost_usd, kit_current_stock,
    kit_reorder_point, kit_lead_time_days, kit_expiration_date,
    stockout_risk_flag, weekly_procedure_volume, projected_demand_4wk,
    days_of_supply, hedis_hba1c_tested, hedis_hba1c_poor_control,
    pdsa_cycle_id, himss_emram_stage
FROM staging.raw_encounters
EXCEPT
SELECT
    patient_id, birth_year, age, sex, race_ethnicity, state, encounter_id,
    icd10_code, diagnosis_display, diagnosis_category, severity_index,
    comorbidity_count, has_diabetes, has_hypertension, has_chf, sbp_mmhg,
    dbp_mmhg, heart_rate_bpm, spo2_pct, temperature_f, bmi, respiratory_rate,
    hba1c_pct, glucose_mg_dl, creatinine_mg_dl, wbc_10e3_ul, nt_probnp_pg_ml,
    medication_adherence_pdc, readmission_30d_flag, triage_timestamp,
    admit_timestamp, bed_request_time, bed_assign_time, unit_assigned,
    bed_occupancy_pct, cpt_code, procedure_display, or_start, or_end,
    actual_or_minutes, or_turnover_minutes, los_days, discharge_timestamp,
    safety_incident_flag, incident_type, incident_severity, claim_id, payer,
    npi_billing, drg_weight, submitted_charge_usd, allowed_amount_usd,
    patient_responsibility_usd, fraud_upcoding_flag, fraud_duplicate_flag,
    fraud_unbundling_flag, nurse_emp_id, nurse_role, nurse_unit,
    nurse_tenure_years, nurse_fte, surgeon_emp_id, surgeon_specialty,
    shift_hours, patients_per_nurse_ratio, overtime_hours,
    burnout_exhaustion_mbi, burnout_cynicism_mbi,
    burnout_personal_accomplishment_mbi, turnover_risk_index,
    cahps_nurse_communication, cahps_doctor_communication,
    cahps_responsiveness, cahps_pain_management, cahps_discharge_info,
    cahps_care_transition, cahps_cleanliness, cahps_quietness,
    surgical_kit_id, kit_name, kit_unit_cost_usd, kit_current_stock,
    kit_reorder_point, kit_lead_time_days, kit_expiration_date,
    stockout_risk_flag, weekly_procedure_volume, projected_demand_4wk,
    days_of_supply, hedis_hba1c_tested, hedis_hba1c_poor_control,
    pdsa_cycle_id, himss_emram_stage
FROM bronze.encounters;

select * from bronze.encounters;

-- ============================================================
-- SILVER LAYER
-- ============================================================
-- Scope of this layer:
--   1. Upsert on encounter_id: for each encounter_id, take the latest
--      bronze version (MAX(bronze_id) via ROW_NUMBER) and MERGE it into
--      silver.encounters -- update if the encounter_id already exists,
--      insert if it does not. Silver always holds exactly one current
--      row per encounter.
--   2. Type conformance: every column is cast out of NVARCHAR(255) into
--      its proper type (INT/DECIMAL/BIT/DATETIME2/DATE) via TRY_CAST,
--      so a malformed value becomes NULL instead of failing the load.
--   3. Cleaning, per the six requested checks:
--        a. Removing duplicates -- already handled upstream: bronze's
--           full-row EXCEPT blocks exact duplicates, and this MERGE
--           upsert on encounter_id guarantees one row per encounter in
--           silver. No separate dedup step is needed here.
--        b. Data filtering -- rows with a missing/blank encounter_id
--           are excluded before cleaning (bronze_latest CTE), since
--           that is the upsert key.
--        c. Handling missing values -- has_missing_value flags a row
--           when any column in REQUIRED_COLUMNS (core identifying /
--           clinical / financial fields) is NULL after cleaning.
--        d. Handling invalid values -- has_invalid_value flags a row
--           when: (i) a raw value was present but failed TRY_CAST
--           (malformed data), or (ii) a value is outside a hardcoded
--           clinical/domain plausible range (e.g. age 0-120,
--           spo2_pct 0-100).
--        e. Handling unwanted spaces -- every string column is passed
--           through LTRIM(RTRIM(...)) and blanks are normalized to
--           NULL via NULLIF before casting or comparison.
--        f. Outlier detection -- has_outlier_value flags a row when a
--           financial/operational numeric column (no fixed clinical
--           range) falls outside data-driven IQR bounds
--           (Q1 - 1.5*IQR .. Q3 + 1.5*IQR), computed via
--           PERCENTILE_CONT over the current batch.
--   Per agreed policy: invalid/outlier values are FLAGGED, not
--   dropped or nulled -- the raw cast value is kept in the column and
--   the corresponding flag column is set to 1, so no data is lost.

IF OBJECT_ID('silver.encounters', 'U') IS NULL
BEGIN
    CREATE TABLE silver.encounters (
        patient_id NVARCHAR(20),
        birth_year SMALLINT,
        age SMALLINT,
        sex NVARCHAR(10),
        race_ethnicity NVARCHAR(50),
        state NVARCHAR(5),
        encounter_id NVARCHAR(64) NOT NULL,
        icd10_code NVARCHAR(10),
        diagnosis_display NVARCHAR(255),
        diagnosis_category NVARCHAR(20),
        severity_index DECIMAL(6,3),
        comorbidity_count TINYINT,
        has_diabetes BIT,
        has_hypertension BIT,
        has_chf BIT,
        sbp_mmhg DECIMAL(6,2),
        dbp_mmhg DECIMAL(6,2),
        heart_rate_bpm DECIMAL(6,2),
        spo2_pct DECIMAL(5,2),
        temperature_f DECIMAL(5,2),
        bmi DECIMAL(5,2),
        respiratory_rate SMALLINT,
        hba1c_pct DECIMAL(5,2),
        glucose_mg_dl DECIMAL(6,2),
        creatinine_mg_dl DECIMAL(6,2),
        wbc_10e3_ul DECIMAL(6,2),
        nt_probnp_pg_ml DECIMAL(10,2),
        medication_adherence_pdc DECIMAL(5,3),
        readmission_30d_flag BIT,
        triage_timestamp DATETIME2,
        admit_timestamp DATETIME2,
        bed_request_time DATETIME2,
        bed_assign_time DATETIME2,
        unit_assigned NVARCHAR(50),
        bed_occupancy_pct DECIMAL(5,2),
        cpt_code NVARCHAR(10),
        procedure_display NVARCHAR(255),
        or_start DATETIME2,
        or_end DATETIME2,
        actual_or_minutes SMALLINT,
        or_turnover_minutes SMALLINT,
        los_days SMALLINT,
        discharge_timestamp DATETIME2,
        safety_incident_flag BIT,
        incident_type NVARCHAR(50),
        incident_severity NVARCHAR(20),
        claim_id NVARCHAR(20),
        payer NVARCHAR(50),
        npi_billing NVARCHAR(15),
        drg_weight DECIMAL(8,4),
        submitted_charge_usd DECIMAL(12,2),
        allowed_amount_usd DECIMAL(12,2),
        patient_responsibility_usd DECIMAL(12,2),
        fraud_upcoding_flag BIT,
        fraud_duplicate_flag BIT,
        fraud_unbundling_flag BIT,
        nurse_emp_id NVARCHAR(20),
        nurse_role NVARCHAR(30),
        nurse_unit NVARCHAR(50),
        nurse_tenure_years DECIMAL(5,2),
        nurse_fte DECIMAL(4,2),
        surgeon_emp_id NVARCHAR(20),
        surgeon_specialty NVARCHAR(50),
        shift_hours TINYINT,
        patients_per_nurse_ratio SMALLINT,
        overtime_hours DECIMAL(5,2),
        burnout_exhaustion_mbi DECIMAL(5,2),
        burnout_cynicism_mbi DECIMAL(5,2),
        burnout_personal_accomplishment_mbi DECIMAL(5,2),
        turnover_risk_index DECIMAL(6,3),
        cahps_nurse_communication DECIMAL(4,2),
        cahps_doctor_communication DECIMAL(4,2),
        cahps_responsiveness DECIMAL(4,2),
        cahps_pain_management DECIMAL(4,2),
        cahps_discharge_info DECIMAL(4,2),
        cahps_care_transition DECIMAL(4,2),
        cahps_cleanliness DECIMAL(4,2),
        cahps_quietness DECIMAL(4,2),
        surgical_kit_id NVARCHAR(30),
        kit_name NVARCHAR(50),
        kit_unit_cost_usd DECIMAL(10,2),
        kit_current_stock SMALLINT,
        kit_reorder_point SMALLINT,
        kit_lead_time_days SMALLINT,
        kit_expiration_date DATE,
        stockout_risk_flag BIT,
        weekly_procedure_volume SMALLINT,
        projected_demand_4wk SMALLINT,
        days_of_supply DECIMAL(6,2),
        hedis_hba1c_tested BIT,
        hedis_hba1c_poor_control BIT,
        pdsa_cycle_id NVARCHAR(20),
        himss_emram_stage TINYINT,
        has_missing_value BIT NOT NULL DEFAULT 0,
        has_invalid_value BIT NOT NULL DEFAULT 0,
        has_outlier_value BIT NOT NULL DEFAULT 0,
        CONSTRAINT PK_silver_encounters PRIMARY KEY (encounter_id)
    );
END;

WITH bronze_latest AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY bronze_id DESC) AS rn
    FROM bronze.encounters
    WHERE NULLIF(LTRIM(RTRIM(encounter_id)), '') IS NOT NULL
),
cleaned AS (
    SELECT
        NULLIF(LTRIM(RTRIM(patient_id)), '') AS patient_id,
        TRY_CAST(NULLIF(LTRIM(RTRIM(birth_year)), '') AS SMALLINT) AS birth_year,
        NULLIF(LTRIM(RTRIM(birth_year)), '') AS raw_birth_year,
        TRY_CAST(NULLIF(LTRIM(RTRIM(age)), '') AS SMALLINT) AS age,
        NULLIF(LTRIM(RTRIM(age)), '') AS raw_age,
        NULLIF(LTRIM(RTRIM(sex)), '') AS sex,
        NULLIF(LTRIM(RTRIM(race_ethnicity)), '') AS race_ethnicity,
        NULLIF(LTRIM(RTRIM(state)), '') AS state,
        LTRIM(RTRIM(encounter_id)) AS encounter_id,
        NULLIF(LTRIM(RTRIM(icd10_code)), '') AS icd10_code,
        NULLIF(LTRIM(RTRIM(diagnosis_display)), '') AS diagnosis_display,
        NULLIF(LTRIM(RTRIM(diagnosis_category)), '') AS diagnosis_category,
        TRY_CAST(NULLIF(LTRIM(RTRIM(severity_index)), '') AS DECIMAL(6,3)) AS severity_index,
        NULLIF(LTRIM(RTRIM(severity_index)), '') AS raw_severity_index,
        TRY_CAST(NULLIF(LTRIM(RTRIM(comorbidity_count)), '') AS TINYINT) AS comorbidity_count,
        NULLIF(LTRIM(RTRIM(comorbidity_count)), '') AS raw_comorbidity_count,
        TRY_CAST(NULLIF(LTRIM(RTRIM(has_diabetes)), '') AS BIT) AS has_diabetes,
        NULLIF(LTRIM(RTRIM(has_diabetes)), '') AS raw_has_diabetes,
        TRY_CAST(NULLIF(LTRIM(RTRIM(has_hypertension)), '') AS BIT) AS has_hypertension,
        NULLIF(LTRIM(RTRIM(has_hypertension)), '') AS raw_has_hypertension,
        TRY_CAST(NULLIF(LTRIM(RTRIM(has_chf)), '') AS BIT) AS has_chf,
        NULLIF(LTRIM(RTRIM(has_chf)), '') AS raw_has_chf,
        TRY_CAST(NULLIF(LTRIM(RTRIM(sbp_mmhg)), '') AS DECIMAL(6,2)) AS sbp_mmhg,
        NULLIF(LTRIM(RTRIM(sbp_mmhg)), '') AS raw_sbp_mmhg,
        TRY_CAST(NULLIF(LTRIM(RTRIM(dbp_mmhg)), '') AS DECIMAL(6,2)) AS dbp_mmhg,
        NULLIF(LTRIM(RTRIM(dbp_mmhg)), '') AS raw_dbp_mmhg,
        TRY_CAST(NULLIF(LTRIM(RTRIM(heart_rate_bpm)), '') AS DECIMAL(6,2)) AS heart_rate_bpm,
        NULLIF(LTRIM(RTRIM(heart_rate_bpm)), '') AS raw_heart_rate_bpm,
        TRY_CAST(NULLIF(LTRIM(RTRIM(spo2_pct)), '') AS DECIMAL(5,2)) AS spo2_pct,
        NULLIF(LTRIM(RTRIM(spo2_pct)), '') AS raw_spo2_pct,
        TRY_CAST(NULLIF(LTRIM(RTRIM(temperature_f)), '') AS DECIMAL(5,2)) AS temperature_f,
        NULLIF(LTRIM(RTRIM(temperature_f)), '') AS raw_temperature_f,
        TRY_CAST(NULLIF(LTRIM(RTRIM(bmi)), '') AS DECIMAL(5,2)) AS bmi,
        NULLIF(LTRIM(RTRIM(bmi)), '') AS raw_bmi,
        TRY_CAST(NULLIF(LTRIM(RTRIM(respiratory_rate)), '') AS SMALLINT) AS respiratory_rate,
        NULLIF(LTRIM(RTRIM(respiratory_rate)), '') AS raw_respiratory_rate,
        TRY_CAST(NULLIF(LTRIM(RTRIM(hba1c_pct)), '') AS DECIMAL(5,2)) AS hba1c_pct,
        NULLIF(LTRIM(RTRIM(hba1c_pct)), '') AS raw_hba1c_pct,
        TRY_CAST(NULLIF(LTRIM(RTRIM(glucose_mg_dl)), '') AS DECIMAL(6,2)) AS glucose_mg_dl,
        NULLIF(LTRIM(RTRIM(glucose_mg_dl)), '') AS raw_glucose_mg_dl,
        TRY_CAST(NULLIF(LTRIM(RTRIM(creatinine_mg_dl)), '') AS DECIMAL(6,2)) AS creatinine_mg_dl,
        NULLIF(LTRIM(RTRIM(creatinine_mg_dl)), '') AS raw_creatinine_mg_dl,
        TRY_CAST(NULLIF(LTRIM(RTRIM(wbc_10e3_ul)), '') AS DECIMAL(6,2)) AS wbc_10e3_ul,
        NULLIF(LTRIM(RTRIM(wbc_10e3_ul)), '') AS raw_wbc_10e3_ul,
        TRY_CAST(NULLIF(LTRIM(RTRIM(nt_probnp_pg_ml)), '') AS DECIMAL(10,2)) AS nt_probnp_pg_ml,
        NULLIF(LTRIM(RTRIM(nt_probnp_pg_ml)), '') AS raw_nt_probnp_pg_ml,
        TRY_CAST(NULLIF(LTRIM(RTRIM(medication_adherence_pdc)), '') AS DECIMAL(5,3)) AS medication_adherence_pdc,
        NULLIF(LTRIM(RTRIM(medication_adherence_pdc)), '') AS raw_medication_adherence_pdc,
        TRY_CAST(NULLIF(LTRIM(RTRIM(readmission_30d_flag)), '') AS BIT) AS readmission_30d_flag,
        NULLIF(LTRIM(RTRIM(readmission_30d_flag)), '') AS raw_readmission_30d_flag,
        TRY_CAST(NULLIF(LTRIM(RTRIM(triage_timestamp)), '') AS DATETIME2) AS triage_timestamp,
        NULLIF(LTRIM(RTRIM(triage_timestamp)), '') AS raw_triage_timestamp,
        TRY_CAST(NULLIF(LTRIM(RTRIM(admit_timestamp)), '') AS DATETIME2) AS admit_timestamp,
        NULLIF(LTRIM(RTRIM(admit_timestamp)), '') AS raw_admit_timestamp,
        TRY_CAST(NULLIF(LTRIM(RTRIM(bed_request_time)), '') AS DATETIME2) AS bed_request_time,
        NULLIF(LTRIM(RTRIM(bed_request_time)), '') AS raw_bed_request_time,
        TRY_CAST(NULLIF(LTRIM(RTRIM(bed_assign_time)), '') AS DATETIME2) AS bed_assign_time,
        NULLIF(LTRIM(RTRIM(bed_assign_time)), '') AS raw_bed_assign_time,
        NULLIF(LTRIM(RTRIM(unit_assigned)), '') AS unit_assigned,
        TRY_CAST(NULLIF(LTRIM(RTRIM(bed_occupancy_pct)), '') AS DECIMAL(5,2)) AS bed_occupancy_pct,
        NULLIF(LTRIM(RTRIM(bed_occupancy_pct)), '') AS raw_bed_occupancy_pct,
        NULLIF(LTRIM(RTRIM(cpt_code)), '') AS cpt_code,
        NULLIF(LTRIM(RTRIM(procedure_display)), '') AS procedure_display,
        TRY_CAST(NULLIF(LTRIM(RTRIM(or_start)), '') AS DATETIME2) AS or_start,
        NULLIF(LTRIM(RTRIM(or_start)), '') AS raw_or_start,
        TRY_CAST(NULLIF(LTRIM(RTRIM(or_end)), '') AS DATETIME2) AS or_end,
        NULLIF(LTRIM(RTRIM(or_end)), '') AS raw_or_end,
        TRY_CAST(NULLIF(LTRIM(RTRIM(actual_or_minutes)), '') AS SMALLINT) AS actual_or_minutes,
        NULLIF(LTRIM(RTRIM(actual_or_minutes)), '') AS raw_actual_or_minutes,
        TRY_CAST(NULLIF(LTRIM(RTRIM(or_turnover_minutes)), '') AS SMALLINT) AS or_turnover_minutes,
        NULLIF(LTRIM(RTRIM(or_turnover_minutes)), '') AS raw_or_turnover_minutes,
        TRY_CAST(NULLIF(LTRIM(RTRIM(los_days)), '') AS SMALLINT) AS los_days,
        NULLIF(LTRIM(RTRIM(los_days)), '') AS raw_los_days,
        TRY_CAST(NULLIF(LTRIM(RTRIM(discharge_timestamp)), '') AS DATETIME2) AS discharge_timestamp,
        NULLIF(LTRIM(RTRIM(discharge_timestamp)), '') AS raw_discharge_timestamp,
        TRY_CAST(NULLIF(LTRIM(RTRIM(safety_incident_flag)), '') AS BIT) AS safety_incident_flag,
        NULLIF(LTRIM(RTRIM(safety_incident_flag)), '') AS raw_safety_incident_flag,
        NULLIF(LTRIM(RTRIM(incident_type)), '') AS incident_type,
        NULLIF(LTRIM(RTRIM(incident_severity)), '') AS incident_severity,
        NULLIF(LTRIM(RTRIM(claim_id)), '') AS claim_id,
        NULLIF(LTRIM(RTRIM(payer)), '') AS payer,
        NULLIF(LTRIM(RTRIM(npi_billing)), '') AS npi_billing,
        TRY_CAST(NULLIF(LTRIM(RTRIM(drg_weight)), '') AS DECIMAL(8,4)) AS drg_weight,
        NULLIF(LTRIM(RTRIM(drg_weight)), '') AS raw_drg_weight,
        TRY_CAST(NULLIF(LTRIM(RTRIM(submitted_charge_usd)), '') AS DECIMAL(12,2)) AS submitted_charge_usd,
        NULLIF(LTRIM(RTRIM(submitted_charge_usd)), '') AS raw_submitted_charge_usd,
        TRY_CAST(NULLIF(LTRIM(RTRIM(allowed_amount_usd)), '') AS DECIMAL(12,2)) AS allowed_amount_usd,
        NULLIF(LTRIM(RTRIM(allowed_amount_usd)), '') AS raw_allowed_amount_usd,
        TRY_CAST(NULLIF(LTRIM(RTRIM(patient_responsibility_usd)), '') AS DECIMAL(12,2)) AS patient_responsibility_usd,
        NULLIF(LTRIM(RTRIM(patient_responsibility_usd)), '') AS raw_patient_responsibility_usd,
        TRY_CAST(NULLIF(LTRIM(RTRIM(fraud_upcoding_flag)), '') AS BIT) AS fraud_upcoding_flag,
        NULLIF(LTRIM(RTRIM(fraud_upcoding_flag)), '') AS raw_fraud_upcoding_flag,
        TRY_CAST(NULLIF(LTRIM(RTRIM(fraud_duplicate_flag)), '') AS BIT) AS fraud_duplicate_flag,
        NULLIF(LTRIM(RTRIM(fraud_duplicate_flag)), '') AS raw_fraud_duplicate_flag,
        TRY_CAST(NULLIF(LTRIM(RTRIM(fraud_unbundling_flag)), '') AS BIT) AS fraud_unbundling_flag,
        NULLIF(LTRIM(RTRIM(fraud_unbundling_flag)), '') AS raw_fraud_unbundling_flag,
        NULLIF(LTRIM(RTRIM(nurse_emp_id)), '') AS nurse_emp_id,
        NULLIF(LTRIM(RTRIM(nurse_role)), '') AS nurse_role,
        NULLIF(LTRIM(RTRIM(nurse_unit)), '') AS nurse_unit,
        TRY_CAST(NULLIF(LTRIM(RTRIM(nurse_tenure_years)), '') AS DECIMAL(5,2)) AS nurse_tenure_years,
        NULLIF(LTRIM(RTRIM(nurse_tenure_years)), '') AS raw_nurse_tenure_years,
        TRY_CAST(NULLIF(LTRIM(RTRIM(nurse_fte)), '') AS DECIMAL(4,2)) AS nurse_fte,
        NULLIF(LTRIM(RTRIM(nurse_fte)), '') AS raw_nurse_fte,
        NULLIF(LTRIM(RTRIM(surgeon_emp_id)), '') AS surgeon_emp_id,
        NULLIF(LTRIM(RTRIM(surgeon_specialty)), '') AS surgeon_specialty,
        TRY_CAST(NULLIF(LTRIM(RTRIM(shift_hours)), '') AS TINYINT) AS shift_hours,
        NULLIF(LTRIM(RTRIM(shift_hours)), '') AS raw_shift_hours,
        TRY_CAST(NULLIF(LTRIM(RTRIM(patients_per_nurse_ratio)), '') AS SMALLINT) AS patients_per_nurse_ratio,
        NULLIF(LTRIM(RTRIM(patients_per_nurse_ratio)), '') AS raw_patients_per_nurse_ratio,
        TRY_CAST(NULLIF(LTRIM(RTRIM(overtime_hours)), '') AS DECIMAL(5,2)) AS overtime_hours,
        NULLIF(LTRIM(RTRIM(overtime_hours)), '') AS raw_overtime_hours,
        TRY_CAST(NULLIF(LTRIM(RTRIM(burnout_exhaustion_mbi)), '') AS DECIMAL(5,2)) AS burnout_exhaustion_mbi,
        NULLIF(LTRIM(RTRIM(burnout_exhaustion_mbi)), '') AS raw_burnout_exhaustion_mbi,
        TRY_CAST(NULLIF(LTRIM(RTRIM(burnout_cynicism_mbi)), '') AS DECIMAL(5,2)) AS burnout_cynicism_mbi,
        NULLIF(LTRIM(RTRIM(burnout_cynicism_mbi)), '') AS raw_burnout_cynicism_mbi,
        TRY_CAST(NULLIF(LTRIM(RTRIM(burnout_personal_accomplishment_mbi)), '') AS DECIMAL(5,2)) AS burnout_personal_accomplishment_mbi,
        NULLIF(LTRIM(RTRIM(burnout_personal_accomplishment_mbi)), '') AS raw_burnout_personal_accomplishment_mbi,
        TRY_CAST(NULLIF(LTRIM(RTRIM(turnover_risk_index)), '') AS DECIMAL(6,3)) AS turnover_risk_index,
        NULLIF(LTRIM(RTRIM(turnover_risk_index)), '') AS raw_turnover_risk_index,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_nurse_communication)), '') AS DECIMAL(4,2)) AS cahps_nurse_communication,
        NULLIF(LTRIM(RTRIM(cahps_nurse_communication)), '') AS raw_cahps_nurse_communication,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_doctor_communication)), '') AS DECIMAL(4,2)) AS cahps_doctor_communication,
        NULLIF(LTRIM(RTRIM(cahps_doctor_communication)), '') AS raw_cahps_doctor_communication,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_responsiveness)), '') AS DECIMAL(4,2)) AS cahps_responsiveness,
        NULLIF(LTRIM(RTRIM(cahps_responsiveness)), '') AS raw_cahps_responsiveness,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_pain_management)), '') AS DECIMAL(4,2)) AS cahps_pain_management,
        NULLIF(LTRIM(RTRIM(cahps_pain_management)), '') AS raw_cahps_pain_management,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_discharge_info)), '') AS DECIMAL(4,2)) AS cahps_discharge_info,
        NULLIF(LTRIM(RTRIM(cahps_discharge_info)), '') AS raw_cahps_discharge_info,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_care_transition)), '') AS DECIMAL(4,2)) AS cahps_care_transition,
        NULLIF(LTRIM(RTRIM(cahps_care_transition)), '') AS raw_cahps_care_transition,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_cleanliness)), '') AS DECIMAL(4,2)) AS cahps_cleanliness,
        NULLIF(LTRIM(RTRIM(cahps_cleanliness)), '') AS raw_cahps_cleanliness,
        TRY_CAST(NULLIF(LTRIM(RTRIM(cahps_quietness)), '') AS DECIMAL(4,2)) AS cahps_quietness,
        NULLIF(LTRIM(RTRIM(cahps_quietness)), '') AS raw_cahps_quietness,
        NULLIF(LTRIM(RTRIM(surgical_kit_id)), '') AS surgical_kit_id,
        NULLIF(LTRIM(RTRIM(kit_name)), '') AS kit_name,
        TRY_CAST(NULLIF(LTRIM(RTRIM(kit_unit_cost_usd)), '') AS DECIMAL(10,2)) AS kit_unit_cost_usd,
        NULLIF(LTRIM(RTRIM(kit_unit_cost_usd)), '') AS raw_kit_unit_cost_usd,
        TRY_CAST(NULLIF(LTRIM(RTRIM(kit_current_stock)), '') AS SMALLINT) AS kit_current_stock,
        NULLIF(LTRIM(RTRIM(kit_current_stock)), '') AS raw_kit_current_stock,
        TRY_CAST(NULLIF(LTRIM(RTRIM(kit_reorder_point)), '') AS SMALLINT) AS kit_reorder_point,
        NULLIF(LTRIM(RTRIM(kit_reorder_point)), '') AS raw_kit_reorder_point,
        TRY_CAST(NULLIF(LTRIM(RTRIM(kit_lead_time_days)), '') AS SMALLINT) AS kit_lead_time_days,
        NULLIF(LTRIM(RTRIM(kit_lead_time_days)), '') AS raw_kit_lead_time_days,
        TRY_CAST(NULLIF(LTRIM(RTRIM(kit_expiration_date)), '') AS DATE) AS kit_expiration_date,
        NULLIF(LTRIM(RTRIM(kit_expiration_date)), '') AS raw_kit_expiration_date,
        TRY_CAST(NULLIF(LTRIM(RTRIM(stockout_risk_flag)), '') AS BIT) AS stockout_risk_flag,
        NULLIF(LTRIM(RTRIM(stockout_risk_flag)), '') AS raw_stockout_risk_flag,
        TRY_CAST(NULLIF(LTRIM(RTRIM(weekly_procedure_volume)), '') AS SMALLINT) AS weekly_procedure_volume,
        NULLIF(LTRIM(RTRIM(weekly_procedure_volume)), '') AS raw_weekly_procedure_volume,
        TRY_CAST(NULLIF(LTRIM(RTRIM(projected_demand_4wk)), '') AS SMALLINT) AS projected_demand_4wk,
        NULLIF(LTRIM(RTRIM(projected_demand_4wk)), '') AS raw_projected_demand_4wk,
        TRY_CAST(NULLIF(LTRIM(RTRIM(days_of_supply)), '') AS DECIMAL(6,2)) AS days_of_supply,
        NULLIF(LTRIM(RTRIM(days_of_supply)), '') AS raw_days_of_supply,
        TRY_CAST(NULLIF(LTRIM(RTRIM(hedis_hba1c_tested)), '') AS BIT) AS hedis_hba1c_tested,
        NULLIF(LTRIM(RTRIM(hedis_hba1c_tested)), '') AS raw_hedis_hba1c_tested,
        TRY_CAST(NULLIF(LTRIM(RTRIM(hedis_hba1c_poor_control)), '') AS BIT) AS hedis_hba1c_poor_control,
        NULLIF(LTRIM(RTRIM(hedis_hba1c_poor_control)), '') AS raw_hedis_hba1c_poor_control,
        NULLIF(LTRIM(RTRIM(pdsa_cycle_id)), '') AS pdsa_cycle_id,
        TRY_CAST(NULLIF(LTRIM(RTRIM(himss_emram_stage)), '') AS TINYINT) AS himss_emram_stage,
        NULLIF(LTRIM(RTRIM(himss_emram_stage)), '') AS raw_himss_emram_stage
    FROM bronze_latest
    WHERE rn = 1
),
iqr_bounds AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY submitted_charge_usd) OVER () AS q1_submitted_charge_usd,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY submitted_charge_usd) OVER () AS q3_submitted_charge_usd,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY allowed_amount_usd) OVER () AS q1_allowed_amount_usd,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY allowed_amount_usd) OVER () AS q3_allowed_amount_usd,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY patient_responsibility_usd) OVER () AS q1_patient_responsibility_usd,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY patient_responsibility_usd) OVER () AS q3_patient_responsibility_usd,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY drg_weight) OVER () AS q1_drg_weight,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY drg_weight) OVER () AS q3_drg_weight,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY kit_unit_cost_usd) OVER () AS q1_kit_unit_cost_usd,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY kit_unit_cost_usd) OVER () AS q3_kit_unit_cost_usd,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY actual_or_minutes) OVER () AS q1_actual_or_minutes,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY actual_or_minutes) OVER () AS q3_actual_or_minutes,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY or_turnover_minutes) OVER () AS q1_or_turnover_minutes,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY or_turnover_minutes) OVER () AS q3_or_turnover_minutes,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY los_days) OVER () AS q1_los_days,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY los_days) OVER () AS q3_los_days,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY overtime_hours) OVER () AS q1_overtime_hours,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY overtime_hours) OVER () AS q3_overtime_hours,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY nt_probnp_pg_ml) OVER () AS q1_nt_probnp_pg_ml,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY nt_probnp_pg_ml) OVER () AS q3_nt_probnp_pg_ml
    FROM cleaned
),
flagged AS (
    SELECT
        c.patient_id,
        c.birth_year,
        c.age,
        c.sex,
        c.race_ethnicity,
        c.state,
        c.encounter_id,
        c.icd10_code,
        c.diagnosis_display,
        c.diagnosis_category,
        c.severity_index,
        c.comorbidity_count,
        c.has_diabetes,
        c.has_hypertension,
        c.has_chf,
        c.sbp_mmhg,
        c.dbp_mmhg,
        c.heart_rate_bpm,
        c.spo2_pct,
        c.temperature_f,
        c.bmi,
        c.respiratory_rate,
        c.hba1c_pct,
        c.glucose_mg_dl,
        c.creatinine_mg_dl,
        c.wbc_10e3_ul,
        c.nt_probnp_pg_ml,
        c.medication_adherence_pdc,
        c.readmission_30d_flag,
        c.triage_timestamp,
        c.admit_timestamp,
        c.bed_request_time,
        c.bed_assign_time,
        c.unit_assigned,
        c.bed_occupancy_pct,
        c.cpt_code,
        c.procedure_display,
        c.or_start,
        c.or_end,
        c.actual_or_minutes,
        c.or_turnover_minutes,
        c.los_days,
        c.discharge_timestamp,
        c.safety_incident_flag,
        c.incident_type,
        c.incident_severity,
        c.claim_id,
        c.payer,
        c.npi_billing,
        c.drg_weight,
        c.submitted_charge_usd,
        c.allowed_amount_usd,
        c.patient_responsibility_usd,
        c.fraud_upcoding_flag,
        c.fraud_duplicate_flag,
        c.fraud_unbundling_flag,
        c.nurse_emp_id,
        c.nurse_role,
        c.nurse_unit,
        c.nurse_tenure_years,
        c.nurse_fte,
        c.surgeon_emp_id,
        c.surgeon_specialty,
        c.shift_hours,
        c.patients_per_nurse_ratio,
        c.overtime_hours,
        c.burnout_exhaustion_mbi,
        c.burnout_cynicism_mbi,
        c.burnout_personal_accomplishment_mbi,
        c.turnover_risk_index,
        c.cahps_nurse_communication,
        c.cahps_doctor_communication,
        c.cahps_responsiveness,
        c.cahps_pain_management,
        c.cahps_discharge_info,
        c.cahps_care_transition,
        c.cahps_cleanliness,
        c.cahps_quietness,
        c.surgical_kit_id,
        c.kit_name,
        c.kit_unit_cost_usd,
        c.kit_current_stock,
        c.kit_reorder_point,
        c.kit_lead_time_days,
        c.kit_expiration_date,
        c.stockout_risk_flag,
        c.weekly_procedure_volume,
        c.projected_demand_4wk,
        c.days_of_supply,
        c.hedis_hba1c_tested,
        c.hedis_hba1c_poor_control,
        c.pdsa_cycle_id,
        c.himss_emram_stage,
        CASE WHEN
            patient_id IS NULL
        OR birth_year IS NULL
        OR age IS NULL
        OR sex IS NULL
        OR admit_timestamp IS NULL
        OR discharge_timestamp IS NULL
        OR sbp_mmhg IS NULL
        OR dbp_mmhg IS NULL
        OR heart_rate_bpm IS NULL
        OR spo2_pct IS NULL
        OR temperature_f IS NULL
        OR claim_id IS NULL
        OR payer IS NULL
        OR submitted_charge_usd IS NULL
        OR drg_weight IS NULL
        OR nurse_emp_id IS NULL
        OR surgeon_emp_id IS NULL
        THEN 1 ELSE 0 END AS has_missing_value,
        CASE WHEN
            raw_birth_year IS NOT NULL AND birth_year IS NULL
        OR raw_age IS NOT NULL AND age IS NULL
        OR raw_severity_index IS NOT NULL AND severity_index IS NULL
        OR raw_comorbidity_count IS NOT NULL AND comorbidity_count IS NULL
        OR raw_has_diabetes IS NOT NULL AND has_diabetes IS NULL
        OR raw_has_hypertension IS NOT NULL AND has_hypertension IS NULL
        OR raw_has_chf IS NOT NULL AND has_chf IS NULL
        OR raw_sbp_mmhg IS NOT NULL AND sbp_mmhg IS NULL
        OR raw_dbp_mmhg IS NOT NULL AND dbp_mmhg IS NULL
        OR raw_heart_rate_bpm IS NOT NULL AND heart_rate_bpm IS NULL
        OR raw_spo2_pct IS NOT NULL AND spo2_pct IS NULL
        OR raw_temperature_f IS NOT NULL AND temperature_f IS NULL
        OR raw_bmi IS NOT NULL AND bmi IS NULL
        OR raw_respiratory_rate IS NOT NULL AND respiratory_rate IS NULL
        OR raw_hba1c_pct IS NOT NULL AND hba1c_pct IS NULL
        OR raw_glucose_mg_dl IS NOT NULL AND glucose_mg_dl IS NULL
        OR raw_creatinine_mg_dl IS NOT NULL AND creatinine_mg_dl IS NULL
        OR raw_wbc_10e3_ul IS NOT NULL AND wbc_10e3_ul IS NULL
        OR raw_nt_probnp_pg_ml IS NOT NULL AND nt_probnp_pg_ml IS NULL
        OR raw_medication_adherence_pdc IS NOT NULL AND medication_adherence_pdc IS NULL
        OR raw_readmission_30d_flag IS NOT NULL AND readmission_30d_flag IS NULL
        OR raw_triage_timestamp IS NOT NULL AND triage_timestamp IS NULL
        OR raw_admit_timestamp IS NOT NULL AND admit_timestamp IS NULL
        OR raw_bed_request_time IS NOT NULL AND bed_request_time IS NULL
        OR raw_bed_assign_time IS NOT NULL AND bed_assign_time IS NULL
        OR raw_bed_occupancy_pct IS NOT NULL AND bed_occupancy_pct IS NULL
        OR raw_or_start IS NOT NULL AND or_start IS NULL
        OR raw_or_end IS NOT NULL AND or_end IS NULL
        OR raw_actual_or_minutes IS NOT NULL AND actual_or_minutes IS NULL
        OR raw_or_turnover_minutes IS NOT NULL AND or_turnover_minutes IS NULL
        OR raw_los_days IS NOT NULL AND los_days IS NULL
        OR raw_discharge_timestamp IS NOT NULL AND discharge_timestamp IS NULL
        OR raw_safety_incident_flag IS NOT NULL AND safety_incident_flag IS NULL
        OR raw_drg_weight IS NOT NULL AND drg_weight IS NULL
        OR raw_submitted_charge_usd IS NOT NULL AND submitted_charge_usd IS NULL
        OR raw_allowed_amount_usd IS NOT NULL AND allowed_amount_usd IS NULL
        OR raw_patient_responsibility_usd IS NOT NULL AND patient_responsibility_usd IS NULL
        OR raw_fraud_upcoding_flag IS NOT NULL AND fraud_upcoding_flag IS NULL
        OR raw_fraud_duplicate_flag IS NOT NULL AND fraud_duplicate_flag IS NULL
        OR raw_fraud_unbundling_flag IS NOT NULL AND fraud_unbundling_flag IS NULL
        OR raw_nurse_tenure_years IS NOT NULL AND nurse_tenure_years IS NULL
        OR raw_nurse_fte IS NOT NULL AND nurse_fte IS NULL
        OR raw_shift_hours IS NOT NULL AND shift_hours IS NULL
        OR raw_patients_per_nurse_ratio IS NOT NULL AND patients_per_nurse_ratio IS NULL
        OR raw_overtime_hours IS NOT NULL AND overtime_hours IS NULL
        OR raw_burnout_exhaustion_mbi IS NOT NULL AND burnout_exhaustion_mbi IS NULL
        OR raw_burnout_cynicism_mbi IS NOT NULL AND burnout_cynicism_mbi IS NULL
        OR raw_burnout_personal_accomplishment_mbi IS NOT NULL AND burnout_personal_accomplishment_mbi IS NULL
        OR raw_turnover_risk_index IS NOT NULL AND turnover_risk_index IS NULL
        OR raw_cahps_nurse_communication IS NOT NULL AND cahps_nurse_communication IS NULL
        OR raw_cahps_doctor_communication IS NOT NULL AND cahps_doctor_communication IS NULL
        OR raw_cahps_responsiveness IS NOT NULL AND cahps_responsiveness IS NULL
        OR raw_cahps_pain_management IS NOT NULL AND cahps_pain_management IS NULL
        OR raw_cahps_discharge_info IS NOT NULL AND cahps_discharge_info IS NULL
        OR raw_cahps_care_transition IS NOT NULL AND cahps_care_transition IS NULL
        OR raw_cahps_cleanliness IS NOT NULL AND cahps_cleanliness IS NULL
        OR raw_cahps_quietness IS NOT NULL AND cahps_quietness IS NULL
        OR raw_kit_unit_cost_usd IS NOT NULL AND kit_unit_cost_usd IS NULL
        OR raw_kit_current_stock IS NOT NULL AND kit_current_stock IS NULL
        OR raw_kit_reorder_point IS NOT NULL AND kit_reorder_point IS NULL
        OR raw_kit_lead_time_days IS NOT NULL AND kit_lead_time_days IS NULL
        OR raw_kit_expiration_date IS NOT NULL AND kit_expiration_date IS NULL
        OR raw_stockout_risk_flag IS NOT NULL AND stockout_risk_flag IS NULL
        OR raw_weekly_procedure_volume IS NOT NULL AND weekly_procedure_volume IS NULL
        OR raw_projected_demand_4wk IS NOT NULL AND projected_demand_4wk IS NULL
        OR raw_days_of_supply IS NOT NULL AND days_of_supply IS NULL
        OR raw_hedis_hba1c_tested IS NOT NULL AND hedis_hba1c_tested IS NULL
        OR raw_hedis_hba1c_poor_control IS NOT NULL AND hedis_hba1c_poor_control IS NULL
        OR raw_himss_emram_stage IS NOT NULL AND himss_emram_stage IS NULL
        OR (age IS NOT NULL AND (age < 0 OR age > 120))
        OR (sbp_mmhg IS NOT NULL AND (sbp_mmhg < 40 OR sbp_mmhg > 300))
        OR (dbp_mmhg IS NOT NULL AND (dbp_mmhg < 20 OR dbp_mmhg > 200))
        OR (heart_rate_bpm IS NOT NULL AND (heart_rate_bpm < 20 OR heart_rate_bpm > 300))
        OR (spo2_pct IS NOT NULL AND (spo2_pct < 0 OR spo2_pct > 100))
        OR (temperature_f IS NOT NULL AND (temperature_f < 80 OR temperature_f > 115))
        OR (bmi IS NOT NULL AND (bmi < 10 OR bmi > 80))
        OR (respiratory_rate IS NOT NULL AND (respiratory_rate < 4 OR respiratory_rate > 60))
        OR (hba1c_pct IS NOT NULL AND (hba1c_pct < 3 OR hba1c_pct > 20))
        OR (glucose_mg_dl IS NOT NULL AND (glucose_mg_dl < 20 OR glucose_mg_dl > 1000))
        OR (creatinine_mg_dl IS NOT NULL AND (creatinine_mg_dl < 0.1 OR creatinine_mg_dl > 20))
        OR (wbc_10e3_ul IS NOT NULL AND (wbc_10e3_ul < 0.1 OR wbc_10e3_ul > 100))
        OR (medication_adherence_pdc IS NOT NULL AND (medication_adherence_pdc < 0 OR medication_adherence_pdc > 1))
        OR (bed_occupancy_pct IS NOT NULL AND (bed_occupancy_pct < 0 OR bed_occupancy_pct > 100))
        OR (himss_emram_stage IS NOT NULL AND (himss_emram_stage < 0 OR himss_emram_stage > 7))
        THEN 1 ELSE 0 END AS has_invalid_value,
        CASE WHEN
            (submitted_charge_usd IS NOT NULL AND (
            submitted_charge_usd < q1_submitted_charge_usd - 1.5 * (q3_submitted_charge_usd - q1_submitted_charge_usd)
            OR submitted_charge_usd > q3_submitted_charge_usd + 1.5 * (q3_submitted_charge_usd - q1_submitted_charge_usd)
        ))
        OR (allowed_amount_usd IS NOT NULL AND (
            allowed_amount_usd < q1_allowed_amount_usd - 1.5 * (q3_allowed_amount_usd - q1_allowed_amount_usd)
            OR allowed_amount_usd > q3_allowed_amount_usd + 1.5 * (q3_allowed_amount_usd - q1_allowed_amount_usd)
        ))
        OR (patient_responsibility_usd IS NOT NULL AND (
            patient_responsibility_usd < q1_patient_responsibility_usd - 1.5 * (q3_patient_responsibility_usd - q1_patient_responsibility_usd)
            OR patient_responsibility_usd > q3_patient_responsibility_usd + 1.5 * (q3_patient_responsibility_usd - q1_patient_responsibility_usd)
        ))
        OR (drg_weight IS NOT NULL AND (
            drg_weight < q1_drg_weight - 1.5 * (q3_drg_weight - q1_drg_weight)
            OR drg_weight > q3_drg_weight + 1.5 * (q3_drg_weight - q1_drg_weight)
        ))
        OR (kit_unit_cost_usd IS NOT NULL AND (
            kit_unit_cost_usd < q1_kit_unit_cost_usd - 1.5 * (q3_kit_unit_cost_usd - q1_kit_unit_cost_usd)
            OR kit_unit_cost_usd > q3_kit_unit_cost_usd + 1.5 * (q3_kit_unit_cost_usd - q1_kit_unit_cost_usd)
        ))
        OR (actual_or_minutes IS NOT NULL AND (
            actual_or_minutes < q1_actual_or_minutes - 1.5 * (q3_actual_or_minutes - q1_actual_or_minutes)
            OR actual_or_minutes > q3_actual_or_minutes + 1.5 * (q3_actual_or_minutes - q1_actual_or_minutes)
        ))
        OR (or_turnover_minutes IS NOT NULL AND (
            or_turnover_minutes < q1_or_turnover_minutes - 1.5 * (q3_or_turnover_minutes - q1_or_turnover_minutes)
            OR or_turnover_minutes > q3_or_turnover_minutes + 1.5 * (q3_or_turnover_minutes - q1_or_turnover_minutes)
        ))
        OR (los_days IS NOT NULL AND (
            los_days < q1_los_days - 1.5 * (q3_los_days - q1_los_days)
            OR los_days > q3_los_days + 1.5 * (q3_los_days - q1_los_days)
        ))
        OR (overtime_hours IS NOT NULL AND (
            overtime_hours < q1_overtime_hours - 1.5 * (q3_overtime_hours - q1_overtime_hours)
            OR overtime_hours > q3_overtime_hours + 1.5 * (q3_overtime_hours - q1_overtime_hours)
        ))
        OR (nt_probnp_pg_ml IS NOT NULL AND (
            nt_probnp_pg_ml < q1_nt_probnp_pg_ml - 1.5 * (q3_nt_probnp_pg_ml - q1_nt_probnp_pg_ml)
            OR nt_probnp_pg_ml > q3_nt_probnp_pg_ml + 1.5 * (q3_nt_probnp_pg_ml - q1_nt_probnp_pg_ml)
        ))
        THEN 1 ELSE 0 END AS has_outlier_value
    FROM cleaned c
    CROSS JOIN iqr_bounds b
)
MERGE silver.encounters AS tgt
USING flagged AS src
ON tgt.encounter_id = src.encounter_id
WHEN MATCHED THEN
    UPDATE SET
    tgt.patient_id = src.patient_id,
    tgt.birth_year = src.birth_year,
    tgt.age = src.age,
    tgt.sex = src.sex,
    tgt.race_ethnicity = src.race_ethnicity,
    tgt.state = src.state,
    tgt.icd10_code = src.icd10_code,
    tgt.diagnosis_display = src.diagnosis_display,
    tgt.diagnosis_category = src.diagnosis_category,
    tgt.severity_index = src.severity_index,
    tgt.comorbidity_count = src.comorbidity_count,
    tgt.has_diabetes = src.has_diabetes,
    tgt.has_hypertension = src.has_hypertension,
    tgt.has_chf = src.has_chf,
    tgt.sbp_mmhg = src.sbp_mmhg,
    tgt.dbp_mmhg = src.dbp_mmhg,
    tgt.heart_rate_bpm = src.heart_rate_bpm,
    tgt.spo2_pct = src.spo2_pct,
    tgt.temperature_f = src.temperature_f,
    tgt.bmi = src.bmi,
    tgt.respiratory_rate = src.respiratory_rate,
    tgt.hba1c_pct = src.hba1c_pct,
    tgt.glucose_mg_dl = src.glucose_mg_dl,
    tgt.creatinine_mg_dl = src.creatinine_mg_dl,
    tgt.wbc_10e3_ul = src.wbc_10e3_ul,
    tgt.nt_probnp_pg_ml = src.nt_probnp_pg_ml,
    tgt.medication_adherence_pdc = src.medication_adherence_pdc,
    tgt.readmission_30d_flag = src.readmission_30d_flag,
    tgt.triage_timestamp = src.triage_timestamp,
    tgt.admit_timestamp = src.admit_timestamp,
    tgt.bed_request_time = src.bed_request_time,
    tgt.bed_assign_time = src.bed_assign_time,
    tgt.unit_assigned = src.unit_assigned,
    tgt.bed_occupancy_pct = src.bed_occupancy_pct,
    tgt.cpt_code = src.cpt_code,
    tgt.procedure_display = src.procedure_display,
    tgt.or_start = src.or_start,
    tgt.or_end = src.or_end,
    tgt.actual_or_minutes = src.actual_or_minutes,
    tgt.or_turnover_minutes = src.or_turnover_minutes,
    tgt.los_days = src.los_days,
    tgt.discharge_timestamp = src.discharge_timestamp,
    tgt.safety_incident_flag = src.safety_incident_flag,
    tgt.incident_type = src.incident_type,
    tgt.incident_severity = src.incident_severity,
    tgt.claim_id = src.claim_id,
    tgt.payer = src.payer,
    tgt.npi_billing = src.npi_billing,
    tgt.drg_weight = src.drg_weight,
    tgt.submitted_charge_usd = src.submitted_charge_usd,
    tgt.allowed_amount_usd = src.allowed_amount_usd,
    tgt.patient_responsibility_usd = src.patient_responsibility_usd,
    tgt.fraud_upcoding_flag = src.fraud_upcoding_flag,
    tgt.fraud_duplicate_flag = src.fraud_duplicate_flag,
    tgt.fraud_unbundling_flag = src.fraud_unbundling_flag,
    tgt.nurse_emp_id = src.nurse_emp_id,
    tgt.nurse_role = src.nurse_role,
    tgt.nurse_unit = src.nurse_unit,
    tgt.nurse_tenure_years = src.nurse_tenure_years,
    tgt.nurse_fte = src.nurse_fte,
    tgt.surgeon_emp_id = src.surgeon_emp_id,
    tgt.surgeon_specialty = src.surgeon_specialty,
    tgt.shift_hours = src.shift_hours,
    tgt.patients_per_nurse_ratio = src.patients_per_nurse_ratio,
    tgt.overtime_hours = src.overtime_hours,
    tgt.burnout_exhaustion_mbi = src.burnout_exhaustion_mbi,
    tgt.burnout_cynicism_mbi = src.burnout_cynicism_mbi,
    tgt.burnout_personal_accomplishment_mbi = src.burnout_personal_accomplishment_mbi,
    tgt.turnover_risk_index = src.turnover_risk_index,
    tgt.cahps_nurse_communication = src.cahps_nurse_communication,
    tgt.cahps_doctor_communication = src.cahps_doctor_communication,
    tgt.cahps_responsiveness = src.cahps_responsiveness,
    tgt.cahps_pain_management = src.cahps_pain_management,
    tgt.cahps_discharge_info = src.cahps_discharge_info,
    tgt.cahps_care_transition = src.cahps_care_transition,
    tgt.cahps_cleanliness = src.cahps_cleanliness,
    tgt.cahps_quietness = src.cahps_quietness,
    tgt.surgical_kit_id = src.surgical_kit_id,
    tgt.kit_name = src.kit_name,
    tgt.kit_unit_cost_usd = src.kit_unit_cost_usd,
    tgt.kit_current_stock = src.kit_current_stock,
    tgt.kit_reorder_point = src.kit_reorder_point,
    tgt.kit_lead_time_days = src.kit_lead_time_days,
    tgt.kit_expiration_date = src.kit_expiration_date,
    tgt.stockout_risk_flag = src.stockout_risk_flag,
    tgt.weekly_procedure_volume = src.weekly_procedure_volume,
    tgt.projected_demand_4wk = src.projected_demand_4wk,
    tgt.days_of_supply = src.days_of_supply,
    tgt.hedis_hba1c_tested = src.hedis_hba1c_tested,
    tgt.hedis_hba1c_poor_control = src.hedis_hba1c_poor_control,
    tgt.pdsa_cycle_id = src.pdsa_cycle_id,
    tgt.himss_emram_stage = src.himss_emram_stage,
    tgt.has_missing_value = src.has_missing_value,
    tgt.has_invalid_value = src.has_invalid_value,
    tgt.has_outlier_value = src.has_outlier_value
WHEN NOT MATCHED THEN
    INSERT (patient_id, birth_year, age, sex, race_ethnicity, state, encounter_id, icd10_code, diagnosis_display, diagnosis_category, severity_index, comorbidity_count, has_diabetes, has_hypertension, has_chf, sbp_mmhg, dbp_mmhg, heart_rate_bpm, spo2_pct, temperature_f, bmi, respiratory_rate, hba1c_pct, glucose_mg_dl, creatinine_mg_dl, wbc_10e3_ul, nt_probnp_pg_ml, medication_adherence_pdc, readmission_30d_flag, triage_timestamp, admit_timestamp, bed_request_time, bed_assign_time, unit_assigned, bed_occupancy_pct, cpt_code, procedure_display, or_start, or_end, actual_or_minutes, or_turnover_minutes, los_days, discharge_timestamp, safety_incident_flag, incident_type, incident_severity, claim_id, payer, npi_billing, drg_weight, submitted_charge_usd, allowed_amount_usd, patient_responsibility_usd, fraud_upcoding_flag, fraud_duplicate_flag, fraud_unbundling_flag, nurse_emp_id, nurse_role, nurse_unit, nurse_tenure_years, nurse_fte, surgeon_emp_id, surgeon_specialty, shift_hours, patients_per_nurse_ratio, overtime_hours, burnout_exhaustion_mbi, burnout_cynicism_mbi, burnout_personal_accomplishment_mbi, turnover_risk_index, cahps_nurse_communication, cahps_doctor_communication, cahps_responsiveness, cahps_pain_management, cahps_discharge_info, cahps_care_transition, cahps_cleanliness, cahps_quietness, surgical_kit_id, kit_name, kit_unit_cost_usd, kit_current_stock, kit_reorder_point, kit_lead_time_days, kit_expiration_date, stockout_risk_flag, weekly_procedure_volume, projected_demand_4wk, days_of_supply, hedis_hba1c_tested, hedis_hba1c_poor_control, pdsa_cycle_id, himss_emram_stage, has_missing_value, has_invalid_value, has_outlier_value)
    VALUES (src.patient_id, src.birth_year, src.age, src.sex, src.race_ethnicity, src.state, src.encounter_id, src.icd10_code, src.diagnosis_display, src.diagnosis_category, src.severity_index, src.comorbidity_count, src.has_diabetes, src.has_hypertension, src.has_chf, src.sbp_mmhg, src.dbp_mmhg, src.heart_rate_bpm, src.spo2_pct, src.temperature_f, src.bmi, src.respiratory_rate, src.hba1c_pct, src.glucose_mg_dl, src.creatinine_mg_dl, src.wbc_10e3_ul, src.nt_probnp_pg_ml, src.medication_adherence_pdc, src.readmission_30d_flag, src.triage_timestamp, src.admit_timestamp, src.bed_request_time, src.bed_assign_time, src.unit_assigned, src.bed_occupancy_pct, src.cpt_code, src.procedure_display, src.or_start, src.or_end, src.actual_or_minutes, src.or_turnover_minutes, src.los_days, src.discharge_timestamp, src.safety_incident_flag, src.incident_type, src.incident_severity, src.claim_id, src.payer, src.npi_billing, src.drg_weight, src.submitted_charge_usd, src.allowed_amount_usd, src.patient_responsibility_usd, src.fraud_upcoding_flag, src.fraud_duplicate_flag, src.fraud_unbundling_flag, src.nurse_emp_id, src.nurse_role, src.nurse_unit, src.nurse_tenure_years, src.nurse_fte, src.surgeon_emp_id, src.surgeon_specialty, src.shift_hours, src.patients_per_nurse_ratio, src.overtime_hours, src.burnout_exhaustion_mbi, src.burnout_cynicism_mbi, src.burnout_personal_accomplishment_mbi, src.turnover_risk_index, src.cahps_nurse_communication, src.cahps_doctor_communication, src.cahps_responsiveness, src.cahps_pain_management, src.cahps_discharge_info, src.cahps_care_transition, src.cahps_cleanliness, src.cahps_quietness, src.surgical_kit_id, src.kit_name, src.kit_unit_cost_usd, src.kit_current_stock, src.kit_reorder_point, src.kit_lead_time_days, src.kit_expiration_date, src.stockout_risk_flag, src.weekly_procedure_volume, src.projected_demand_4wk, src.days_of_supply, src.hedis_hba1c_tested, src.hedis_hba1c_poor_control, src.pdsa_cycle_id, src.himss_emram_stage, src.has_missing_value, src.has_invalid_value, src.has_outlier_value);

select * from silver.encounters;
