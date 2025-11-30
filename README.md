# PostgreSQL Table Partitioning Automation Script

## Overview

`data_partation.sh` is a comprehensive bash automation script designed to migrate PostgreSQL tables from standard structure to a **2-level LIST partitioning** scheme. It implements an intelligent partitioning strategy with automatic bucket management, data migration, and built-in rollback capabilities.

## Table of Contents

- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Usage](#usage)
- [Partitioning Strategy](#partitioning-strategy)
- [Migration Process](#migration-process)
- [Rollback Mechanism](#rollback-mechanism)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)

---

## How It Works

The script automates the transformation of regular PostgreSQL tables into partitioned tables using a **2-level hierarchical partitioning strategy**:

1. **Level 1**: Partitions by a specified key column (e.g., `customer_id`)
2. **Level 2**: Sub-partitions by `bucket_id` to limit partition size

This approach prevents partition bloat and maintains optimal query performance even with millions of rows per key value.

### Example

If you have a table `custom_module_data` with 500,000 rows for `customer_id = 123` and set `BUCKET_LIMIT = 100000`:

```
custom_module_data (parent)
  ├── custom_module_data_customer_id_123 (L1 partition)
  │   ├── custom_module_data_customer_id_123_bucket_id_0 (100,000 rows)
  │   ├── custom_module_data_customer_id_123_bucket_id_1 (100,000 rows)
  │   ├── custom_module_data_customer_id_123_bucket_id_2 (100,000 rows)
  │   ├── custom_module_data_customer_id_123_bucket_id_3 (100,000 rows)
  │   └── custom_module_data_customer_id_123_bucket_id_4 (100,000 rows)
  └── custom_module_data_customer_id_456 (L1 partition)
      └── custom_module_data_customer_id_456_bucket_id_0 (50,000 rows)
```

---

## Architecture

```mermaid
graph TB
    A[Start Migration] --> B[Validate Configuration]
    B --> C[Deploy Infrastructure]
    C --> D[Create Metadata Tables]
    D --> E[Install Trigger Functions]
    E --> F[For Each Target Table]
    
    F --> G[Backup Original Table]
    G --> H[Create Partitioned Parent]
    H --> I[Analyze Data Distribution]
    I --> J[Pre-create Partitions]
    J --> K[Migrate Data by Key]
    K --> L[Rebuild Indexes]
    L --> M[Enable Auto-routing Trigger]
    M --> N[Verify Row Counts]
    
    N --> O{More Tables?}
    O -->|Yes| F
    O -->|No| P[VACUUM ANALYZE]
    P --> Q[Success]
    
    style A fill:#90EE90
    style Q fill:#90EE90
    style G fill:#FFD700
    style N fill:#87CEEB
```

### Infrastructure Components

The script creates the following PostgreSQL objects:

| Object | Type | Purpose |
|--------|------|---------|
| `partition_config` | Table | Stores partitioning configuration per table |
| `partition_tracker` | Table | Tracks current bucket and row count per partition key |
| `func_custom_partition_manager()` | Function | Trigger function for automatic partition routing |
| `proc_provision_batches()` | Procedure | Pre-creates partition hierarchy |
| `trg_partition_manager` | Trigger | Automatically routes new inserts to correct partition |

---

## Detailed System Architecture

### Metadata Tables Relationships

```mermaid
erDiagram
    PARTITION_CONFIG ||--o{ PARTITION_TRACKER : "configured for"
    PARTITION_CONFIG ||--o{ PARTITIONED_TABLE : "defines strategy"
    PARTITION_TRACKER ||--o{ L1_PARTITION : "tracks state"
    PARTITIONED_TABLE ||--o{ L1_PARTITION : "contains"
    L1_PARTITION ||--o{ L2_PARTITION : "contains"
    
    PARTITION_CONFIG {
        text target_table_name PK
        text partition_key_col
        int bucket_limit
        timestamptz created_at
    }
    
    PARTITION_TRACKER {
        text target_table_name PK
        text partition_key_value PK
        int current_bucket_id
        int row_count
        timestamptz last_updated
    }
    
    PARTITIONED_TABLE {
        text partition_key
        int bucket_id
        text other_columns
    }
    
    L1_PARTITION {
        text partition_key "fixed value"
        int bucket_id "variable"
        text other_columns
    }
    
    L2_PARTITION {
        text partition_key "fixed value"
        int bucket_id "fixed value"
        text other_columns "actual data"
    }
```

### Partition Hierarchy Structure

```mermaid
graph TB
    subgraph "Parent Table"
        A[custom_module_data<br/>PARTITIONED BY LIST partition_key]
    end
    
    subgraph "Level 1 Partitions - By customer_id"
        B1[custom_module_data_customer_id_100<br/>FOR VALUES IN '100'<br/>PARTITIONED BY LIST bucket_id]
        B2[custom_module_data_customer_id_200<br/>FOR VALUES IN '200'<br/>PARTITIONED BY LIST bucket_id]
        B3[custom_module_data_customer_id_300<br/>FOR VALUES IN '300'<br/>PARTITIONED BY LIST bucket_id]
    end
    
    subgraph "Level 2 Partitions - By bucket_id customer_id=100"
        C1[..._customer_id_100_bucket_id_0<br/>FOR VALUES IN 0<br/>Rows 1-100,000]
        C2[..._customer_id_100_bucket_id_1<br/>FOR VALUES IN 1<br/>Rows 100,001-200,000]
        C3[..._customer_id_100_bucket_id_2<br/>FOR VALUES IN 2<br/>Rows 200,001-300,000]
    end
    
    subgraph "Level 2 Partitions - By bucket_id customer_id=200"
        D1[..._customer_id_200_bucket_id_0<br/>FOR VALUES IN 0<br/>Rows 1-100,000]
        D2[..._customer_id_200_bucket_id_1<br/>FOR VALUES IN 1<br/>Rows 100,001-200,000]
    end
    
    subgraph "Level 2 Partitions - By bucket_id customer_id=300"
        E1[..._customer_id_300_bucket_id_0<br/>FOR VALUES IN 0<br/>Rows 1-100,000]
    end
    
    A --> B1
    A --> B2
    A --> B3
    
    B1 --> C1
    B1 --> C2
    B1 --> C3
    
    B2 --> D1
    B2 --> D2
    
    B3 --> E1
    
    style A fill:#FF6B6B,color:#fff
    style B1 fill:#4ECDC4,color:#fff
    style B2 fill:#4ECDC4,color:#fff
    style B3 fill:#4ECDC4,color:#fff
    style C1 fill:#95E1D3
    style C2 fill:#95E1D3
    style C3 fill:#95E1D3
    style D1 fill:#95E1D3
    style D2 fill:#95E1D3
    style E1 fill:#95E1D3
```

### Trigger Function Flow - INSERT Operation

```mermaid
sequenceDiagram
    participant App as Application
    participant Tbl as Partitioned Table
    participant Trg as Trigger Function
    participant Cfg as partition_config
    participant Trk as partition_tracker
    participant L1 as L1 Partition
    participant L2 as L2 Partition

    App->>Tbl: INSERT INTO custom_module_data<br/>(customer_id=123, data='...')
    Tbl->>Trg: BEFORE INSERT Trigger Fires
    
    Note over Trg: Check migration mode
    Trg->>Trg: IF migration_mode='on'<br/>RETURN NEW (skip partition logic)
    
    Trg->>Cfg: SELECT partition_key_col, bucket_limit<br/>WHERE target_table_name='custom_module_data'
    Cfg-->>Trg: partition_key='customer_id'<br/>bucket_limit=100000
    
    Trg->>Trg: Extract partition_key value<br/>from NEW row → '123'
    
    Note over Trg: Acquire row lock and get/create tracker
    Trg->>Trk: SELECT current_bucket_id, row_count<br/>WHERE table='custom_module_data'<br/>AND key_value='123'<br/>FOR UPDATE
    
    alt Tracker Exists
        Trk-->>Trg: bucket_id=2, row_count=75000
    else First Insert for key=123
        Trg->>Trk: INSERT (table, key_value)<br/>VALUES ('custom_module_data', '123')
        Trk-->>Trg: bucket_id=0, row_count=0
    end
    
    Note over Trg: Check if bucket is full
    alt row_count >= bucket_limit
        Trg->>Trg: Increment bucket_id<br/>bucket_id = bucket_id + 1
        Trg->>Trk: UPDATE SET<br/>current_bucket_id=3,<br/>row_count=1
    else Bucket has space
        Trg->>Trk: UPDATE SET<br/>row_count = row_count + 1
    end
    
    Trg->>Trg: Set NEW.bucket_id = 2
    
    Note over Trg: Ensure L1 partition exists
    Trg->>Trg: l1_name = 'custom_module_data<br/>_customer_id_123'
    Trg->>Trg: Check if L1 exists
    
    alt L1 Doesn't Exist
        Trg->>Trg: Acquire advisory lock
        Trg->>L1: CREATE TABLE custom_module_data_customer_id_123<br/>PARTITION OF custom_module_data<br/>FOR VALUES IN ('123')<br/>PARTITION BY LIST (bucket_id)
    end
    
    Note over Trg: Ensure L2 partition exists
    Trg->>Trg: l2_name = 'custom_module_data<br/>_customer_id_123_bucket_id_2'
    Trg->>Trg: Check if L2 exists
    
    alt L2 Doesn't Exist
        Trg->>Trg: Acquire advisory lock
        Trg->>L2: CREATE TABLE ..._customer_id_123_bucket_id_2<br/>PARTITION OF ..._customer_id_123<br/>FOR VALUES IN (2)
    end
    
    Trg-->>Tbl: RETURN NEW (with bucket_id=2)
    Tbl->>L2: PostgreSQL automatically routes<br/>to correct L2 partition
    L2-->>App: INSERT successful
```

### Automatic Partition Creation Flow

```mermaid
graph TB
    A[New INSERT arrives] --> B{Migration Mode?}
    B -->|ON| C[Skip trigger logic<br/>RETURN NEW]
    B -->|OFF| D[Get config from<br/>partition_config table]
    
    D --> E[Extract partition key<br/>value from NEW row]
    E --> F{Tracker exists<br/>for this key?}
    
    F -->|NO| G[INSERT INTO partition_tracker<br/>bucket_id=0, row_count=0]
    F -->|YES| H[Get current bucket_id<br/>and row_count]
    
    G --> H
    H --> I{row_count >= bucket_limit?}
    
    I -->|YES| J[Increment bucket_id<br/>Reset row_count=1]
    I -->|NO| K[Increment row_count]
    
    J --> L[Set NEW.bucket_id]
    K --> L
    
    L --> M{L1 partition exists?}
    M -->|NO| N[Acquire Advisory Lock]
    N --> O[CREATE TABLE parent_key_value<br/>PARTITION OF parent<br/>FOR VALUES IN key_value<br/>PARTITION BY LIST bucket_id]
    
    M -->|YES| P{L2 partition exists?}
    O --> P
    
    P -->|NO| Q[Acquire Advisory Lock]
    Q --> R[CREATE TABLE parent_key_value_bucket_id_N<br/>PARTITION OF parent_key_value<br/>FOR VALUES IN bucket_id]
    
    P -->|YES| S[RETURN NEW]
    R --> S
    
    S --> T[PostgreSQL routes INSERT<br/>to correct partition automatically]
    
    style A fill:#90EE90
    style C fill:#FFD700
    style T fill:#87CEEB
    style O fill:#FF6B6B,color:#fff
    style R fill:#FF6B6B,color:#fff
```

### Data Flow During Migration

```mermaid
graph LR
    subgraph "Before Migration"
        A1[custom_module_data<br/>Regular Table<br/>1,000,000 rows]
    end
    
    subgraph "Step 1: Backup"
        B1[custom_module_data_backup<br/>Original table renamed<br/>1,000,000 rows]
    end
    
    subgraph "Step 2: Create Parent"
        C1[custom_module_data<br/>PARTITIONED TABLE<br/>0 rows initially]
    end
    
    subgraph "Step 3: Analyze & Pre-create"
        D1[proc_provision_batches]
        D2[Analyze data distribution]
        D3[Calculate buckets needed]
        D4[Create L1 partitions]
        D5[Create L2 partitions]
    end
    
    subgraph "Step 4: Data Migration"
        E1[For each customer_id<br/>ordered by row count DESC]
        E2[INSERT with bucket_id calculation<br/>FLOOR row_number / bucket_limit]
        E3[Data copied to L2 partitions]
    end
    
    subgraph "Step 5: Enable Auto-routing"
        F1[CREATE TRIGGER<br/>trg_partition_manager]
        F2[Future INSERTs automatically<br/>routed to correct partition]
    end
    
    subgraph "Final State"
        G1[custom_module_data<br/>Parent Table]
        G2[L1: customer_id partitions]
        G3[L2: bucket_id partitions<br/>1,000,000 rows total]
        G4[custom_module_data_backup<br/>Kept for safety]
    end
    
    A1 -->|RENAME TO| B1
    B1 --> C1
    C1 --> D1
    D1 --> D2 --> D3 --> D4 --> D5
    D5 --> E1
    B1 -.->|Read data| E1
    E1 --> E2 --> E3
    E3 --> F1 --> F2
    F2 --> G1
    G1 --> G2 --> G3
    B1 -.->|Preserved| G4
    
    style A1 fill:#FFE5E5
    style B1 fill:#FFD700
    style C1 fill:#E5F5FF
    style G3 fill:#90EE90
    style G4 fill:#FFD700
```

### Rollback Mechanism Flow

```mermaid
graph TB
    A[Error Detected<br/>EXIT/INT/TERM signal] --> B{Migration Success Flag?}
    
    B -->|TRUE| C[Exit normally<br/>No rollback needed]
    B -->|FALSE| D[Initiate Rollback for ALL targets]
    
    D --> E[For each table in<br/>MIGRATION_TARGETS]
    
    E --> F{Backup table exists?}
    F -->|NO| G[Log: No backup exists<br/>Skip this table]
    F -->|YES| H[Incomplete migration detected]
    
    H --> I[DROP TABLE parent_table<br/>CASCADE]
    I --> J[ALTER TABLE backup_table<br/>RENAME TO parent_table]
    
    J --> K{Restore successful?}
    K -->|YES| L[Log: Restore completed<br/>Original table restored]
    K -->|NO| M[Log: Auto restore failed<br/>Backup retained as backup_table]
    
    M --> N[Display manual restore command<br/>for admin intervention]
    
    G --> O[Next table]
    L --> O
    N --> O
    
    O --> P{More tables?}
    P -->|YES| E
    P -->|NO| Q[Exit with error code]
    
    style A fill:#FF6B6B,color:#fff
    style C fill:#90EE90
    style L fill:#90EE90
    style M fill:#FFD700
    style Q fill:#FF6B6B,color:#fff
```

### Multi-Table Coordination

When migrating multiple tables simultaneously:

```mermaid
graph TB
    subgraph "Global Metadata Tables - Shared Across All Partitioned Tables"
        META1[partition_config<br/>Stores config for ALL tables]
        META2[partition_tracker<br/>Tracks state for ALL partition keys]
    end
    
    subgraph "Table 1: custom_module_data"
        T1[custom_module_data<br/>Parent]
        T1L1[L1 Partitions by customer_id]
        T1L2[L2 Partitions by bucket_id]
        T1 --> T1L1 --> T1L2
    end
    
    subgraph "Table 2: custom_module_equipment_map"
        T2[custom_module_equipment_map<br/>Parent]
        T2L1[L1 Partitions by cm_id]
        T2L2[L2 Partitions by bucket_id]
        T2 --> T2L1 --> T2L2
    end
    
    subgraph "Table 3: another_table"
        T3[another_table<br/>Parent]
        T3L1[L1 Partitions by user_id]
        T3L2[L2 Partitions by bucket_id]
        T3 --> T3L1 --> T3L2
    end
    
    META1 -.->|Config for Table 1| T1
    META1 -.->|Config for Table 2| T2
    META1 -.->|Config for Table 3| T3
    
    META2 -.->|Track customer_id keys| T1L1
    META2 -.->|Track cm_id keys| T2L1
    META2 -.->|Track user_id keys| T3L1
    
    style META1 fill:#FF6B6B,color:#fff
    style META2 fill:#FF6B6B,color:#fff
    style T1 fill:#4ECDC4,color:#fff
    style T2 fill:#4ECDC4,color:#fff
    style T3 fill:#4ECDC4,color:#fff
```

#### Metadata Table Content Examples

**partition_config table**:
```sql
target_table_name              | partition_key_col | bucket_limit | created_at
-------------------------------|-------------------|--------------|-------------------------
custom_module_data             | customer_id       | 100000       | 2025-11-30 21:00:00
custom_module_equipment_map    | cm_id             | 100000       | 2025-11-30 21:05:00
another_table                  | user_id           | 50000        | 2025-11-30 21:10:00
```

**partition_tracker table**:
```sql
target_table_name           | partition_key_value | current_bucket_id | row_count | last_updated
----------------------------|---------------------|-------------------|-----------|-------------------------
custom_module_data          | 100                 | 2                 | 45000     | 2025-11-30 21:30:00
custom_module_data          | 200                 | 0                 | 5000      | 2025-11-30 21:29:00
custom_module_data          | 300                 | 5                 | 99999     | 2025-11-30 21:31:00
custom_module_equipment_map | 501                 | 1                 | 50000     | 2025-11-30 21:28:00
custom_module_equipment_map | 502                 | 0                 | 25000     | 2025-11-30 21:27:00
another_table               | user_123            | 0                 | 10000     | 2025-11-30 21:25:00
```

---

## Features

### ✅ Core Capabilities

- **Automated 2-level partitioning** (LIST by key → LIST by bucket_id)
- **Zero-downtime migration** with backup preservation
- **Intelligent bucket sizing** to prevent partition bloat
- **Automatic partition creation** for future inserts via triggers
- **Index replication** with auto-adjustment for partition constraints
- **Comprehensive rollback** on failure
- **Data integrity verification** with row count validation
- **Colored console output** for easy monitoring
- **Idempotent design** - safe to re-run after failures

### 🔐 Safety Features

- Preserves original table as `{table}_backup`
- Automatic rollback on failures (Ctrl+C, errors, crashes)
- Validates configuration before execution
- Transactional operations with proper error handling
- Row count verification after migration

---

## Prerequisites

### System Requirements

- **PostgreSQL**: 10 or higher (partitioning support required)
- **Bash**: 4.0+
- **psql**: PostgreSQL client tools
- **Permissions**: Database user with CREATE, ALTER, DROP, INSERT privileges

### Database Connection

The script requires access to a PostgreSQL database. Ensure you have:

1. Network access to the PostgreSQL server
2. Valid credentials with sufficient privileges
3. Database name and connection details

---

## Configuration

### Database Connection Settings

Edit the configuration section at the top of the script:

```bash
# --- CONFIGURATION ---
DB_HOST="localhost"       # PostgreSQL host
DB_PORT="5432"            # PostgreSQL port
DB_NAME="terotam_local"   # Database name
DB_USER="postgres"        # Database user
DB_PASS="0206"            # Database password

TARGET_SCHEMA="public"    # Schema containing tables
MAIN_LIMIT=100000         # Default bucket size (rows per partition)
```

> **Security Note**: For production, export `DB_PASS` as an environment variable instead of hardcoding:
> ```bash
> export DB_PASS="your_password"
> ./data_partation.sh
> ```

### Table Migration Targets

Define tables to migrate in the `MIGRATION_TARGETS` array:

```bash
declare -a MIGRATION_TARGETS=(
    # Format: "table_name : partition_key_column : bucket_limit"
    "custom_module_data : customer_id : ${MAIN_LIMIT}"
    "custom_module_equipment_map : cm_id : ${MAIN_LIMIT}"
    
    # You can comment out tables to skip them:
    # "other_table : user_id : 50000"
)
```

**Configuration Format**:
- **Table Name**: Name of the table to partition
- **Partition Key**: Column to use for Level 1 partitioning
- **Bucket Limit**: Maximum rows per Level 2 partition

---

## Usage

### Basic Execution

```bash
# Make script executable
chmod +x data_partation.sh

# Run the migration
./data_partation.sh
```

### Using Environment Variables

```bash
# Override database credentials
export DB_HOST="production-db.example.com"
export DB_PORT="5432"
export DB_NAME="production_db"
export DB_USER="migration_user"
export DB_PASS="secure_password"

./data_partation.sh
```

### Dry Run (Recommended First Step)

To understand what will happen without making changes:

1. Comment out all tables in `MIGRATION_TARGETS` except one test table
2. Use a small `BUCKET_LIMIT` value
3. Run on a development/staging database first
4. Review the backup table after migration

---

## Partitioning Strategy

### 2-Level LIST Partitioning

The script implements a hierarchical partitioning strategy:

#### Level 1: Partition by Key Column
Each unique value of the partition key gets its own partition.

```sql
CREATE TABLE custom_module_data_customer_id_123 
  PARTITION OF custom_module_data 
  FOR VALUES IN ('123') 
  PARTITION BY LIST (bucket_id);
```

#### Level 2: Partition by Bucket ID
Each Level 1 partition is further divided into buckets based on row count.

```sql
CREATE TABLE custom_module_data_customer_id_123_bucket_id_0 
  PARTITION OF custom_module_data_customer_id_123 
  FOR VALUES IN (0);
```

### Bucket Calculation

For each partition key value, buckets are created as:

```
bucket_id = FLOOR((row_number - 1) / BUCKET_LIMIT)
```

**Example**: With `BUCKET_LIMIT = 100000`:
- Rows 1-100,000 → `bucket_id = 0`
- Rows 100,001-200,000 → `bucket_id = 1`
- Rows 200,001-300,000 → `bucket_id = 2`

---

## Migration Process

### Phase 1: Infrastructure Deployment

The script creates necessary infrastructure:

1. **Metadata Tables**:
   - `partition_config`: Stores configuration per table
   - `partition_tracker`: Tracks bucket state for each partition key

2. **Trigger Function**: `func_custom_partition_manager()`
   - Automatically calculates correct bucket_id
   - Creates partitions on-the-fly if missing
   - Updates partition tracker metadata

3. **Provisioning Procedure**: `proc_provision_batches()`
   - Analyzes data distribution
   - Pre-creates partition hierarchy
   - Optimizes for bulk operations

### Phase 2: Table Migration

For each table in `MIGRATION_TARGETS`:

#### Step 1: Backup Original Table
```sql
ALTER TABLE custom_module_data RENAME TO custom_module_data_backup;
```

#### Step 2: Create Partitioned Parent
```sql
CREATE TABLE custom_module_data (
    -- All original columns
    bucket_id INT NOT NULL DEFAULT 0,
    PRIMARY KEY (original_pk_columns, bucket_id)
) PARTITION BY LIST (partition_key_column);
```

#### Step 3: Pre-create Partition Hierarchy
Analyzes backup table and creates all required L1 and L2 partitions.

#### Step 4: Migrate Data
```sql
-- For each partition key value (largest first)
INSERT INTO custom_module_data (columns, bucket_id)
SELECT columns, FLOOR((ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1) / bucket_limit)
FROM custom_module_data_backup
WHERE partition_key = 'value';
```

#### Step 5: Enable Auto-routing Trigger
```sql
CREATE TRIGGER trg_partition_manager 
  BEFORE INSERT ON custom_module_data
  FOR EACH ROW 
  EXECUTE FUNCTION func_custom_partition_manager();
```

#### Step 6: Verify Data Integrity
Compares row counts between backup and partitioned tables.

---

## Rollback Mechanism

### Automatic Rollback

The script includes comprehensive error handling that automatically rolls back on:

- Script errors (syntax, runtime)
- Database connection failures
- User interruption (Ctrl+C)
- System signals (SIGTERM, SIGINT)

### Rollback Process

When a failure is detected:

1. **Detection**: Trap catches EXIT, INT, or TERM signals
2. **Evaluation**: Checks if migration completed successfully
3. **Restoration**: For each table with a backup:
   ```bash
   DROP TABLE IF EXISTS table_name CASCADE;
   ALTER TABLE table_name_backup RENAME TO table_name;
   ```
4. **Verification**: Confirms restoration success

### Manual Rollback

If automatic rollback fails, restore manually:

```sql
-- Drop the partially migrated table
DROP TABLE IF EXISTS custom_module_data CASCADE;

-- Restore from backup
ALTER TABLE custom_module_data_backup RENAME TO custom_module_data;
```

---

## Verification

### Automated Verification

The script performs automatic verification:

1. **Row Count Validation**:
   ```sql
   SELECT count(*) FROM original_table;
   SELECT count(*) FROM partitioned_table;
   ```

2. **Partition Structure**:
   ```sql
   SELECT 
       schemaname, tablename, 
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) 
   FROM pg_tables 
   WHERE tablename LIKE 'custom_module_data%'
   ORDER BY tablename;
   ```

### Manual Verification Steps

After migration, verify data integrity:

```sql
-- 1. Check partition structure
SELECT 
    parent.relname AS parent_table,
    child.relname AS partition_name,
    pg_get_expr(child.relpartbound, child.oid) AS partition_bound
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
WHERE parent.relname = 'custom_module_data'
ORDER BY child.relname;

-- 2. Verify data distribution
SELECT 
    tableoid::regclass AS partition,
    count(*) AS row_count
FROM custom_module_data
GROUP BY tableoid
ORDER BY partition;

-- 3. Test insert (should auto-route to correct partition)
INSERT INTO custom_module_data (customer_id, other_columns) 
VALUES (999, ...);

-- 4. Verify the insert went to correct partition
SELECT tableoid::regclass, * 
FROM custom_module_data 
WHERE customer_id = 999;
```

---

## Troubleshooting

### Common Issues

#### 1. Connection Refused

**Error**: `Cannot connect to PostgreSQL`

**Solution**:
- Verify `DB_HOST`, `DB_PORT`, `DB_NAME` are correct
- Check PostgreSQL is running: `sudo systemctl status postgresql`
- Verify firewall rules allow connection
- Test connection: `psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME`

#### 2. Permission Denied

**Error**: `ERROR: permission denied for schema public`

**Solution**:
- Ensure user has required privileges:
  ```sql
  GRANT CREATE, USAGE ON SCHEMA public TO your_user;
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO your_user;
  ```

#### 3. Partition Key Cannot Be NULL

**Error**: `Partition Key cannot be NULL`

**Solution**:
- Ensure partition key column has `NOT NULL` constraint
- Clean data before migration:
  ```sql
  UPDATE table_name SET partition_key = 'default_value' 
  WHERE partition_key IS NULL;
  ```

#### 4. Row Count Mismatch

**Warning**: `Row count mismatch detected!`

**Solution**:
- Check for failed partition migrations in logs
- Verify no concurrent writes occurred during migration
- Manually compare data:
  ```sql
  SELECT * FROM original_backup 
  EXCEPT 
  SELECT column1, column2, ... FROM partitioned_table;
  ```

#### 5. Unique Index Conflicts

**Warning**: `must include all partitioning columns`

**Solution**:
- Script automatically converts conflicting UNIQUE indexes to regular indexes
- For critical UNIQUE constraints, include partition key in the index manually after migration

### Debugging

Enable verbose output:

```bash
# Add to script after shebang
set -x  # Print each command before execution
```

Check PostgreSQL logs:

```bash
# Find PostgreSQL log location
sudo -u postgres psql -c "SHOW log_directory;"
sudo -u postgres psql -c "SHOW log_filename;"

# View logs
tail -f /var/log/postgresql/postgresql-XX-main.log
```

---

## Performance Considerations

### Optimal Bucket Sizing

Choose `BUCKET_LIMIT` based on your use case:

| Use Case | Recommended Bucket Size | Rationale |
|----------|------------------------|-----------|
| High insert rate | 50,000 - 100,000 | Smaller buckets reduce contention |
| Read-heavy workloads | 100,000 - 500,000 | Larger buckets reduce partition count |
| Mixed workload | 100,000 | Balanced approach |
| Very large datasets | 200,000 - 500,000 | Fewer partitions to manage |

### Migration Time Estimates

Approximate migration time (depends on hardware):

- **100K rows**: 1-2 minutes
- **1M rows**: 5-10 minutes
- **10M rows**: 30-60 minutes
- **100M rows**: 3-5 hours

**Optimization Tips**:
- Run during low-traffic periods
- Increase `work_mem` temporarily: `SET work_mem = '256MB';`
- Disable autovacuum during migration
- Consider parallel migration of different tables

---

## Post-Migration Tasks

### 1. Remove Backup Tables (After Verification)

```sql
-- Only after thorough verification!
DROP TABLE custom_module_data_backup;
```

### 2. Update Application Code

Ensure your application:
- Includes `bucket_id` in PRIMARY KEY operations
- Handles composite primary keys correctly
- Updates any queries that reference table structure

### 3. Monitor Performance

```sql
-- Monitor partition sizes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE tablename LIKE 'custom_module_data%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Check partition pruning is working
EXPLAIN (ANALYZE, BUFFERS) 
SELECT * FROM custom_module_data WHERE customer_id = '123';
```

### 4. Schedule Maintenance

```sql
-- Regular ANALYZE for query planner
ANALYZE custom_module_data;

-- Periodic VACUUM for space reclamation
VACUUM ANALYZE custom_module_data;
```

---

## Advanced Configuration

### Custom Partition Key Expressions

For complex partitioning needs, modify the trigger function to support expressions:

```sql
-- Example: Partition by year from timestamp
v_key_val := EXTRACT(YEAR FROM (to_jsonb(NEW) ->> v_conf.partition_key_col)::timestamp);
```

### Multi-Tenant Optimization

For multi-tenant applications, use tenant ID as partition key:

```bash
MIGRATION_TARGETS=(
    "transactions : tenant_id : 100000"
    "users : organization_id : 50000"
)
```

Benefits:
- Tenant isolation at storage level
- Easy tenant deletion (drop partition)
- Improved query performance with partition pruning
