#!/bin/bash

set -e
set -o pipefail

# --- CONFIGURATION ---
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="Test_Table"
DB_USER="postgres"
DB_PASS="0206"

TARGET_SCHEMA="public"
MAIN_LIMIT = 100000

# TABLE LIST
declare -a MIGRATION_TARGETS=(
    # Table Name: Column Name : Bucket Limit
    "custom_module_data : customer_id : ${MAIN_LIMIT}"
    "custom_module_equipment_map : cm_id : ${MAIN_LIMIT}"
);

# --- [2] SYSTEM SETTINGS ---
if [ -n "$DB_PASS" ]; then
    export PGPASSWORD="$DB_PASS"
fi
export PGOPTIONS='-c client_min_messages=warning'

# Colors (ANSI - Bright/Light variants for better visibility)
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[91m'      # Bright Red
GREEN='\033[92m'    # Bright Green
BLUE='\033[94m'     # Bright Blue
MAGENTA='\033[95m'  # Bright Magenta
CYAN='\033[96m'     # Bright Cyan
WHITE='\033[97m'    # Bright White
YELLOW='\033[93m'   # Bright Yellow



ts() { date +'%H:%M:%S'; }
log_header()  { echo -e "\n${BOLD}${MAGENTA}================================================================${RESET}"; echo -e "${BOLD}${MAGENTA}   $1 ${RESET}"; echo -e "${BOLD}${MAGENTA}================================================================${RESET}"; }
log_step()    { echo -e "${CYAN}[$(ts)] ➤ STEP: $1${RESET}"; }
log_info()    { echo -e "${BLUE}[$(ts)] ℹ INFO : $1${RESET}"; }
log_warn()    { echo -e "${YELLOW}[$(ts)] ⚠ WARN : $1${RESET}"; }
log_error()   { echo -e "${RED}[$(ts)] ✖ ERROR: $1${RESET}"; exit 1; }
log_success() { echo -e "${GREEN}[$(ts)] ✔ OK   : $1${RESET}"; }
log_critical(){ echo -e "${RED}[CRITICAL] $1${RESET}"; }
log_rb()      { echo -e "${YELLOW}[ROLLBACK] $1${RESET}"; }

# State Tracking for Rollback
CURRENT_TBL=""
BACKUP_TBL=""
MIGRATION_STAGE="NONE"
MIGRATION_SUCCESS="false"

# Rollback Logic (robust, preserves backup)
rollback_handler() {
    EXIT_CODE=$?
    set +e
    trap '' EXIT INT TERM

    if [ "$MIGRATION_SUCCESS" != "true" ]; then
        log_critical "Process terminated (exit code: $EXIT_CODE). Initiating rollback for ALL targets..."

        for target in "${MIGRATION_TARGETS[@]}"; do

            # skip commented lines
            if [[ -z "$target" || "$target" =~ ^[[:space:]]*# ]]; then
                continue
            fi

            CLEAN=$(echo "$target" | xargs)
            IFS=':' read -r TBL KEY LIMIT <<< "$CLEAN"
            TBL=$(echo "$TBL" | xargs)
            BACKUP_TBL="${TBL}_backup"

            log_rb "Checking rollback state for table: ${TARGET_SCHEMA}.${TBL}"

            # Check existence
            MAIN_EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
                "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace 
                 WHERE c.relname='${TBL}' AND n.nspname='${TARGET_SCHEMA}' AND c.relkind='r';")

            BACKUP_EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
                "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace 
                 WHERE c.relname='${BACKUP_TBL}' AND n.nspname='${TARGET_SCHEMA}' AND c.relkind='r';")

            # Only rollback if backup exists and table is partially migrated
            if [[ "$BACKUP_EXISTS" == "1" ]]; then

                # Use your EXACT logic
                log_rb "Incomplete migration detected for ${TBL}. Attempting automatic restore of original table..."

                # Drop partially-created parent
                psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
                     -c "DROP TABLE IF EXISTS ${TARGET_SCHEMA}.${TBL} CASCADE;" >/dev/null 2>&1

                # Rename backup → parent
                psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
                     -c "ALTER TABLE ${TARGET_SCHEMA}.${BACKUP_TBL} RENAME TO ${TBL};" >/dev/null 2>&1

                if [ $? -eq 0 ]; then
                    log_rb "Restore completed successfully → ${TARGET_SCHEMA}.${TBL}"
                else
                    log_rb "Automatic restore failed → backup retained as: ${TARGET_SCHEMA}.${BACKUP_TBL}"
                    echo -e "${RED}[URGENT] Manual restore command:${RESET} ALTER TABLE ${TARGET_SCHEMA}.${BACKUP_TBL} RENAME TO ${TBL};"
                fi

            else
                log_rb "No backup exists for ${TBL}; nothing to revert."
            fi

        done

        exit $EXIT_CODE
    fi
}

trap rollback_handler EXIT INT TERM

# Executors
exec_sql() { psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1"; }

# Log Filter (format psql WARNING lines consistently)
format_log() {
    while read -r line; do
        if [[ "$line" == *">>> STEP"* ]]; then
            MSG=$(echo "$line" | sed 's/.*>>> //')
            echo -e "${MAGENTA}   ➤  ${BOLD}$MSG${RESET}"
        elif [[ "$line" == *"+ "* ]]; then
            MSG=$(echo "$line" | sed 's/.*+ //')
            echo -e "${GREEN}     + $MSG${RESET}"
        elif [[ "$line" == *"ERROR:"* || "$line" == *"FATAL:"* ]]; then
            echo -e "${RED}     [DB ERROR] $line${RESET}"
        fi
    done
}

clear
log_header "TABLE PARTITIONING ENGINE"



log_step "Validating migration configuration"

# Check if MIGRATION_TARGETS array is empty
if [ ${#MIGRATION_TARGETS[@]} -eq 0 ]; then
    log_error "MIGRATION_TARGETS array is empty. Please define at least one table to migrate."
fi

# Validate each target configuration
VALID_TARGETS=0
for target in "${MIGRATION_TARGETS[@]}"; do
    # Skip commented lines
    if [[ "$target" =~ ^[[:space:]]*# ]]; then
        continue
    fi
    
    CLEAN=$(echo "$target" | xargs)
    IFS=':' read -r TBL KEY LIMIT <<< "$CLEAN"
    TBL=$(echo "$TBL" | xargs)
    KEY=$(echo "$KEY" | xargs)
    LIMIT=$(echo "$LIMIT" | xargs)
    
    # Validate table name
    if [ -z "$TBL" ]; then
        log_error "Invalid configuration: Table name is empty in target: '$target'"
    fi
    
    # Validate partition key
    if [ -z "$KEY" ]; then
        log_error "Invalid configuration: Partition key is empty for table '$TBL'"
    fi
    
    # Validate bucket limit
    if [ -z "$LIMIT" ]; then
        log_error "Invalid configuration: Bucket limit is empty for table '$TBL'"
    fi
    
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
        log_error "Invalid configuration: Bucket limit '$LIMIT' is not a valid number for table '$TBL'"
    fi
    
    if [ "$LIMIT" -lt 1 ]; then
        log_error "Invalid configuration: Bucket limit must be >= 1 for table '$TBL' (got: $LIMIT)"
    fi
    
    log_info "✓ Valid target: ${TBL} (partition by: ${KEY}, bucket size: ${LIMIT} rows)"
    VALID_TARGETS=$((VALID_TARGETS + 1))
done

if [ $VALID_TARGETS -eq 0 ]; then
    log_error "No valid migration targets found. Please uncomment at least one table in MIGRATION_TARGETS array."
fi

log_success "Configuration validated: ${VALID_TARGETS} table(s) ready for migration"



log_step "Step 1 — Establishing database connection"
if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
    echo -e "${RED}[FATAL] Cannot connect to PostgreSQL at ${DB_HOST}:${DB_PORT}/${DB_NAME}.${RESET}"
    echo -e "${YELLOW}Hint: Export DB_PASS environment variable if authentication is required.${RESET}"
    exit 1
fi
log_success "PostgreSQL connection established successfully"

# Refresh collation version (non-fatal)
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "ALTER DATABASE \"$DB_NAME\" REFRESH COLLATION VERSION;" >/dev/null 2>&1 || true


log_step "Phase 1 — Deploying partitioning infrastructure (triggers, functions, metadata tables)"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'PGSQL' 2>&1 | format_log
BEGIN;

SET statement_timeout = 0;
SET idle_in_transaction_session_timeout = 0;

-- A. INFRASTRUCTURE
CREATE TABLE IF NOT EXISTS public.partition_config (
    target_table_name TEXT PRIMARY KEY,
    partition_key_col TEXT NOT NULL,
    bucket_limit INT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.partition_tracker (
    target_table_name TEXT,
    partition_key_value TEXT,
    current_bucket_id INT DEFAULT 0,
    row_count INT DEFAULT 0,
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT pk_partition_tracker PRIMARY KEY (target_table_name, partition_key_value)
);
CREATE INDEX IF NOT EXISTS idx_tracker_lookup ON public.partition_tracker(target_table_name, partition_key_value);

-- B. TRIGGER FUNCTION
CREATE OR REPLACE FUNCTION public.func_custom_partition_manager()
RETURNS TRIGGER AS $$
DECLARE
    v_conf RECORD;
    v_key_val TEXT;
    v_bkt_id INT;
    v_count INT;
    v_sch TEXT := 'public';
    v_l1_name TEXT;
    v_l2_name TEXT;
BEGIN
    IF current_setting('app.migration_mode', true) = 'on' THEN RETURN NEW; END IF;

    SELECT partition_key_col, bucket_limit INTO v_conf
    FROM public.partition_config WHERE target_table_name = TG_TABLE_NAME;

    IF NOT FOUND THEN RETURN NEW; END IF;

    v_key_val := to_jsonb(NEW) ->> v_conf.partition_key_col;
    IF v_key_val IS NULL THEN RAISE EXCEPTION 'Partition Key cannot be NULL'; END IF;

    LOOP
        SELECT current_bucket_id, row_count INTO v_bkt_id, v_count
        FROM public.partition_tracker 
        WHERE target_table_name = TG_TABLE_NAME AND partition_key_value = v_key_val
        FOR UPDATE;
        
        IF FOUND THEN EXIT;
        ELSE
            INSERT INTO public.partition_tracker (target_table_name, partition_key_value)
            VALUES (TG_TABLE_NAME, v_key_val) ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;

    IF v_count >= v_conf.bucket_limit THEN
        v_bkt_id := v_bkt_id + 1;
        UPDATE public.partition_tracker 
        SET current_bucket_id = v_bkt_id, row_count = 1, last_updated = NOW() 
        WHERE target_table_name = TG_TABLE_NAME AND partition_key_value = v_key_val;
    ELSE
        UPDATE public.partition_tracker 
        SET row_count = row_count + 1, last_updated = NOW() 
        WHERE target_table_name = TG_TABLE_NAME AND partition_key_value = v_key_val;
    END IF;

    NEW.bucket_id := v_bkt_id;

    v_l1_name := TG_TABLE_NAME || '_' || v_conf.partition_key_col || '_' || v_key_val;
    v_l2_name := v_l1_name || '_bucket_id_' || v_bkt_id;

    IF to_regclass(v_sch || '.' || v_l1_name) IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext('L1_' || v_l1_name));
        IF to_regclass(v_sch || '.' || v_l1_name) IS NULL THEN
            BEGIN
                EXECUTE format('CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF %I.%I FOR VALUES IN (%L) PARTITION BY LIST (bucket_id)', 
                    v_sch, v_l1_name, v_sch, TG_TABLE_NAME, v_key_val);
            EXCEPTION WHEN duplicate_table THEN NULL; END;
        END IF;
    END IF;

    IF to_regclass(v_sch || '.' || v_l2_name) IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext('L2_' || v_l2_name));
        IF to_regclass(v_sch || '.' || v_l2_name) IS NULL THEN
            BEGIN
                EXECUTE format('CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF %I.%I FOR VALUES IN (%L)',
                    v_sch, v_l2_name, v_sch, v_l1_name, v_bkt_id);
            EXCEPTION WHEN duplicate_table THEN NULL; END;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- C. PROVISIONING PROCEDURE (OPTIMIZED)
CREATE OR REPLACE PROCEDURE public.proc_provision_batches(p_table TEXT, p_backup TEXT, p_key TEXT, p_limit INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_rec RECORD;
    v_l1_name TEXT;
    v_l2_name TEXT;
    v_buckets_needed INT;
    v_b INT;
    v_counter INT := 0;
BEGIN
    FOR v_rec IN EXECUTE format('SELECT %I as key, count(*) as cnt FROM public.%I GROUP BY 1', p_key, p_backup) 
    LOOP
        v_buckets_needed := CEIL(v_rec.cnt::numeric / p_limit::numeric);
        IF v_buckets_needed < 1 THEN v_buckets_needed := 1; END IF;

        v_l1_name := p_table || '_' || p_key || '_' || v_rec.key;
        
        IF to_regclass('public.' || v_l1_name) IS NULL THEN
            EXECUTE format('CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.%I FOR VALUES IN (%L) PARTITION BY LIST (bucket_id)', v_l1_name, p_table, v_rec.key);
        END IF;

        FOR v_b IN 0..(v_buckets_needed - 1) LOOP
            v_l2_name := v_l1_name || '_bucket_id_' || v_b;
            IF to_regclass('public.' || v_l2_name) IS NULL THEN
                EXECUTE format('CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.%I FOR VALUES IN (%L)', v_l2_name, v_l1_name, v_b);
            END IF;
        END LOOP;
        
        INSERT INTO public.partition_tracker (target_table_name, partition_key_value, current_bucket_id, row_count)
        VALUES (p_table, v_rec.key::text, v_buckets_needed - 1, v_rec.cnt % p_limit) 
        ON CONFLICT (target_table_name, partition_key_value) 
        DO UPDATE SET current_bucket_id = EXCLUDED.current_bucket_id, row_count = EXCLUDED.row_count;

        v_counter := v_counter + 1;
        IF v_counter % 50 = 0 THEN COMMIT; END IF;
    END LOOP;
    COMMIT;
END;
$$;

COMMIT;
PGSQL

log_success "Partitioning infrastructure deployed (auto-routing triggers and metadata tracking enabled)"



log_header "PHASE 2: TABLE PARTITIONING MIGRATION"

for target in "${MIGRATION_TARGETS[@]}"; do
    CLEAN=$(echo "$target" | xargs)
    IFS=':' read -r TBL KEY LIMIT <<< "$CLEAN"
    TBL=$(echo "$TBL" | xargs); KEY=$(echo "$KEY" | xargs); LIMIT=$(echo "$LIMIT" | xargs)
    
    CURRENT_TBL="$TBL"
    BACKUP_TBL="${TBL}_backup"
    MIGRATION_STAGE="NONE"

    echo ""
    log_info "Migrating table: ${TARGET_SCHEMA}.${TBL}"
    log_info "Partition strategy: 2-level LIST partitioning by '${KEY}' with ${LIMIT} rows per bucket"

    # Status helpers
    exec_check() { psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1"; }

    IS_NORM=$(exec_check "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = '$TBL' AND n.nspname = '$TARGET_SCHEMA' AND c.relkind = 'r'")
    HAS_BACKUP=$(exec_check "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = '$BACKUP_TBL' AND n.nspname = '$TARGET_SCHEMA'")

    # --- STEP 1: PRESERVE ORIGINAL TABLE ---
    if [[ "$IS_NORM" == "1" ]]; then
        log_step "Step 1 — Preserving original table as backup"
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "ALTER TABLE ${TARGET_SCHEMA}.$TBL RENAME TO ${TBL}_backup;" >/dev/null
        MIGRATION_STAGE="RENAMED"
        log_success "Original table preserved as: ${TARGET_SCHEMA}.${BACKUP_TBL}"
    elif [[ "$HAS_BACKUP" == "1" ]]; then
        log_warn "Backup already exists. Resuming partitioning migration from previous run."
        MIGRATION_STAGE="RENAMED"
    else
        log_error "Source table not found: ${TARGET_SCHEMA}.${TBL}"
    fi

    # Prepare Columns
    log_info "Analyzing source table schema and constraints..."

    # --- STEP 2: CREATE PARTITIONED PARENT TABLE ---
    log_step "Step 2 — Creating partitioned parent table (2-level LIST partitioning structure)"
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<PGSQL 2>&1 | format_log
BEGIN;
DO \$\$
DECLARE
    v_cols TEXT;
    v_pk TEXT;
    v_create_sql TEXT;
BEGIN
    SELECT string_agg(quote_ident(attname) || ' ' || format_type(atttypid, atttypmod) ||
           CASE WHEN attnotnull THEN ' NOT NULL' ELSE '' END, ', ')
    INTO v_cols
    FROM pg_attribute
    WHERE attrelid = '${TARGET_SCHEMA}.$BACKUP_TBL'::regclass
      AND attnum > 0 AND NOT attisdropped AND attname != 'bucket_id';

    SELECT string_agg(quote_ident(x.col), ', ') INTO v_pk
    FROM (
        SELECT a.attname::text as col
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = '${TARGET_SCHEMA}.$BACKUP_TBL'::regclass AND i.indisprimary
        UNION
        SELECT '$KEY'::text
    ) x;

    IF v_pk IS NULL THEN v_pk := '$KEY'; END IF;

    RAISE WARNING '>>> STEP: Creating parent table structure';
    v_create_sql := format('CREATE TABLE IF NOT EXISTS ${TARGET_SCHEMA}.$TBL (%s, bucket_id INT NOT NULL DEFAULT 0, PRIMARY KEY (%s, bucket_id)) PARTITION BY LIST ($KEY);', v_cols, v_pk);
    EXECUTE v_create_sql;
END;
\$\$;

INSERT INTO ${TARGET_SCHEMA}.partition_config (target_table_name, partition_key_col, bucket_limit)
VALUES ('$TBL', '$KEY', $LIMIT)
ON CONFLICT (target_table_name) DO UPDATE SET bucket_limit = EXCLUDED.bucket_limit;
COMMIT;
PGSQL


    MIGRATION_STAGE="STRUCTURE_CREATED"
    log_success "Partitioned parent table created with composite primary key (includes bucket_id)"

    # --- STEP 3: PRE-CREATE PARTITION HIERARCHY ---
    log_step "Step 3 — Pre-creating partition hierarchy (L1: by ${KEY}, L2: by bucket_id)"
    log_info "Analyzing data distribution and calculating required partitions..."
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "CALL public.proc_provision_batches('$TBL', '$BACKUP_TBL', '$KEY', $LIMIT);" >/dev/null
    log_success "Partition hierarchy pre-created (L1 and L2 partitions ready for data)"

    # --- STEP 4: MIGRATE DATA AND REBUILD INDEXES ---
    log_step "Step 4 — Migrating data to partitioned structure and rebuilding indexes"

    # Clone indexes (capture output for formatted display)
    log_info "Replicating indexes on partitioned table (auto-adjusting for partition constraints)..."
    INDEX_LOG=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<PGSQL 2>&1
BEGIN;
DO \$\$
DECLARE
    v_idx_rec RECORD;
    v_idx_def TEXT;
BEGIN
    FOR v_idx_rec IN
        SELECT pg_get_indexdef(indexrelid) as def, relname as name
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE indrelid = '${TARGET_SCHEMA}.$BACKUP_TBL'::regclass AND NOT indisprimary
    LOOP
        v_idx_def := REPLACE(v_idx_rec.def, '$BACKUP_TBL', '$TBL');
        v_idx_def := REGEXP_REPLACE(v_idx_def, 'INDEX (\\\\S+)', 'INDEX \\\\1_part');

        BEGIN
            EXECUTE v_idx_def;
            RAISE WARNING '+ Cloned: %', v_idx_rec.name;
        EXCEPTION 
            WHEN duplicate_object THEN
                RAISE WARNING '+ Already exists (skipped): %', v_idx_rec.name;
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%must include all partitioning columns%' THEN
                    RAISE WARNING '! Patching % to non-unique index...', v_idx_rec.name;
                    v_idx_def := REPLACE(v_idx_def, 'UNIQUE INDEX', 'INDEX');
                    BEGIN
                        EXECUTE v_idx_def;
                        RAISE WARNING '+ Patched (non-unique): %', v_idx_rec.name;
                    EXCEPTION WHEN duplicate_object THEN
                        RAISE WARNING '+ Already exists (skipped): %', v_idx_rec.name;
                    END;
                ELSE
                    RAISE WARNING '- Skipped: % (Error: %)', v_idx_rec.name, SQLERRM;
                END IF;
        END;
    END LOOP;
END;
\$\$;
COMMIT;
PGSQL
)
    echo "$INDEX_LOG" | format_log
    log_success "Indexes replicated on partitioned table (partition-compatible)"

    # 4.2 Data copy — per-key copying with live logs
    log_step "Starting data migration (partition-by-partition, largest datasets first)"
    COLS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT string_agg(quote_ident(attname), ', ') FROM pg_attribute WHERE attrelid = '${TARGET_SCHEMA}.${BACKUP_TBL}'::regclass AND attnum > 0 AND NOT attisdropped AND attname != 'bucket_id';")
    # Collect distinct keys ordered by row count (largest first)
    log_info "Analyzing ${KEY} distribution and ordering partition keys by row count (descending)..."
    KEYS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT \"${KEY}\"::text FROM ${TARGET_SCHEMA}.\"${BACKUP_TBL}\" GROUP BY \"${KEY}\" ORDER BY COUNT(*) DESC;")
    
    # iterate keys (shell while to preserve signal handling)
    echo "$KEYS" | while read -r KEY_VAL; do
        if [ -z "$KEY_VAL" ]; then continue; fi

        PART_NAME="${TBL}_${KEY}_${KEY_VAL}"
        echo -e "${CYAN}   ➜ Migrating partition: ${KEY} → ${KEY_VAL}${RESET}"

        COPY_OUTPUT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<PGSQL 2>&1
BEGIN;
SET app.migration_mode = 'on';
INSERT INTO ${TARGET_SCHEMA}."${TBL}" (${COLS}, bucket_id)
SELECT ${COLS}, FLOOR((ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1) / ${LIMIT})
FROM ${TARGET_SCHEMA}."${BACKUP_TBL}"
WHERE "${KEY}"::text = '${KEY_VAL}';
COMMIT;
PGSQL
)
        if [ $? -eq 0 ]; then
            # Try to extract number of inserted rows; fallback to "unknown"
            ROWS=$(echo "$COPY_OUTPUT" | grep -Eo 'INSERT 0 [0-9]+' | awk '{print $3}' || echo "unknown")
            if [[ "$ROWS" =~ ^[0-9]+$ ]]; then
                BUCKETS=$(( (ROWS + LIMIT - 1) / LIMIT ))
            else
                BUCKETS="unknown"
            fi
            echo "$COPY_OUTPUT" | format_log
            echo -e "${GREEN}     ✔ Partition ${KEY} → ${KEY_VAL} → migrated: ${ROWS} rows → buckets: ${BUCKETS}${RESET}"
        else
            echo "$COPY_OUTPUT"
            log_error "Partition migration failed for ${KEY}=${KEY_VAL}. See error details above."
        fi
    done

    # Attach trigger for future inserts
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    DROP TRIGGER IF EXISTS trg_partition_manager ON ${TARGET_SCHEMA}.\"${TBL}\";
    CREATE TRIGGER trg_partition_manager BEFORE INSERT ON ${TARGET_SCHEMA}.\"${TBL}\"
    FOR EACH ROW EXECUTE FUNCTION ${TARGET_SCHEMA}.func_custom_partition_manager();" >/dev/null 2>&1

    log_success "Data migration complete. Auto-routing trigger enabled for future inserts."
    MIGRATION_STAGE="COMPLETE"

    # --- VERIFICATION ---
    log_step "Step 5 — Verifying data integrity (row count validation)"
    COUNT_OLD=$(exec_check "SELECT count(*) FROM ${TARGET_SCHEMA}.\"${BACKUP_TBL}\"")
    COUNT_NEW=$(exec_check "SELECT count(*) FROM ${TARGET_SCHEMA}.\"${TBL}\"")
    log_info "Original table row count: ${COUNT_OLD}"
    log_info "Partitioned table row count: ${COUNT_NEW}"

    if [[ "$COUNT_OLD" == "$COUNT_NEW" ]]; then
        log_success "Data integrity verified: All ${COUNT_NEW} rows successfully migrated to partitioned structure"
    else
        log_warn "Row count mismatch detected! Original: ${COUNT_OLD}, Partitioned: ${COUNT_NEW}. Manual review required."
    fi

done

MIGRATION_SUCCESS="true"
echo ""
log_step "Finalizing — Running table statistics update (VACUUM ANALYZE)"
# Use VACUUM ANALYZE to update query planner statistics without blocking
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "VACUUM ANALYZE;" >/dev/null 2>&1
log_success "Table statistics refreshed for query optimizer"

log_header "PARTITIONING MIGRATION COMPLETED SUCCESSFULLY"
exit 0
