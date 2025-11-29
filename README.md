# 🚀 PostgreSQL Partitioning Automation
# 1. 📘 Introduction

The **PostgreSQL Partitioning Automation Suite** is a complete solution for converting large,
single-table datasets into a **2-level LIST → LIST partitioning architecture**.

This solution is built for:

- Multi-tenant SaaS platforms  
- IOT / device-driven datasets  
- High-ingest logging tables  
- Historical archiving systems  
- Systems suffering from table bloat or slow queries  

The script ensures:

- 🔐 **Zero data loss**  
- ⚙️ **Automatic schema cloning**  
- 🏎 **High-speed migrations**  
- 🛡 **Full rollback safety**  
- 🧩 **Multi-table batch support**

# 2. ⚙️ Key Features

### ✔ Zero Data Loss
- Uses atomic SQL transactions
- Performs final row-count verification
- Backup tables are preserved until migration completes

### ✔ Two-Level Partitioning
```
Level 1 → LIST(customer_id)
Level 2 → LIST(bucket_id)
```

### ✔ Automatic Bucket Splitting
- Each bucket stores up to *N* rows (example: 100,000)
- Prevents oversized partitions
- Ensures efficient VACUUM, ANALYZE, and indexing

### ✔ Schema & Index Replication
- Exact schema cloning using pg_catalog introspection
- Auto-patching unique indexes to include partition keys
- Recreates GIN/B-Tree indexes safely on parent

### ✔ Global Rollback System
- Any failure triggers a **global restoration**
- Drops partially-created parent tables
- Renames backup tables back to original names

### ✔ Performance-First Design
- Disables statement timeout  
- Bulk migration uses window functions for optimal bucket calculation  
- Pre-creates partitions to avoid runtime locking

# 3. 📐 System Architecture (ASCII Diagram)

```
Original Table
      │
      ▼
┌───────────────────────────┐
│   original_table_backup   │◀─── (Preserved for rollback)
└───────────────────────────┘
             │
             ▼
┌───────────────────────────┐
│   Partitioned Parent      │
│   (same name as original) │
└───────────────────────────┘
             │
             ├─────────────────────────────────────────────────┐
             ▼                                                 ▼
┌───────────────────────────────┐         ┌───────────────────────────────┐
│ L1 Partition: KEY = 708       │         │ L1 Partition: KEY = 999       │
└───────┬───────────────────────┘         └───────┬───────────────────────┘
        │                                          │
        ▼                                          ▼
┌────────────────────────────────┐   ┌────────────────────────────────┐
│ L2 Partition: bucket_id = 0    │   │ L2 Partition: bucket_id = 0    │
└────────────────────────────────┘   └────────────────────────────────┘
┌────────────────────────────────┐
│ L2 Partition: bucket_id = 1    │
└────────────────────────────────┘
```

# 4. 🔑 Primary Key Strategy (Triple-Key Model)

| Column        | Purpose                                    |
|---------------|--------------------------------------------|
| `cmd_id`      | Original unique identifier                 |
| `customer_id` | Required for Level 1 partition routing     |
| `bucket_id`   | Required for Level 2 bucket distribution   |

> PostgreSQL requires **all partitioning columns** to be included in the PK.

# 5. 🛠️ Setup & Configuration

### 5.1 Database Configuration
```
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="0830tero_archive"
DB_USER="postgres"
DB_PASS="0206"
```

### 5.2 Migration Targets
```
declare -a MIGRATION_TARGETS=(
    "custom_module_data : customer_id : 100000"
    "custom_module_equipment_map : cm_id : 10000"
)
```

| Parameter         | Meaning                                                   |
|------------------|-----------------------------------------------------------|
| Table Name       | The target table to be partitioned                        |
| Partition Column | Used for Level 1 LIST partitioning                        |
| Row Limit        | Max rows per bucket (Level 2)                              |


# 6. 🧭 Execution Workflow

### 6.1 Run the Script
```
bash data_partation.sh
```

### 6.2 Detailed Step Flow

```
Step 1 → Validate configuration
Step 2 → Create infrastructure (trigger, tracker)
Step 3 → Backup original table
Step 4 → Create partitioned parent table
Step 5 → Pre-create partitions (L1 & L2)
Step 6 → Clone indexes
Step 7 → Bulk data migration (per customer_id)
Step 8 → Enable routing trigger
Step 9 → Row count verification
Step 10 → VACUUM ANALYZE
```

# 7. 🧪 Real-Time Audit Logging (Sample Output)

```
[SQL] >>> STEP: Copying Data...
[SQL] + PROGRESS: Key 708 | Rows Copied: 100000 | bucket_id: 0 
[SQL] + PROGRESS: Key 708 | Rows Copied: 20000  | bucket_id: 1 
[SQL] + PROGRESS: Key 999 | Rows Copied: 5000   | bucket_id: 0 
```

Logs rotate per partition key and show:

- Row count  
- Assigned bucket
  
# 8. 🔄 Rollback System

### Trigger Conditions:
- Script interruption  
- SQL exception  
- Permission issues  
- Any non-zero exit code  

### Rollback Flow (ASCII Diagram)

```
Error Occurs
     │
     ▼
Rollback Triggered
     │
     ▼
Drop partitioned parent table
     │
     ▼
Rename table_backup → original_name
     │
     ▼
Backup preserved even if rename fails
```

> Every table in `MIGRATION_TARGETS` is restored automatically.

# 9. 🔍 Post‑Migration Verification Steps

### 9.1 Check structure
```
\d+ custom_module_data
```

### 9.2 Validate row counts
```
SELECT count(*) FROM custom_module_data;
SELECT count(*) FROM custom_module_data_backup;
```

### 9.3 Check bucket partitions
```
SELECT relname 
FROM pg_class 
WHERE relname LIKE 'custom_module_data_%_bucket_id_%';
```

# 10. 📌 Best Practices

- Run during low-traffic window  
- Ensure partition key is NOT NULL  
- Keep backup tables for 7+ days  
- Validate row count carefully  
- Monitor disk usage  
- Test on staging before production  

# 11. 🎯 Conclusion

This tool provides:

- Safe migration  
- Zero-downtime capability  
- High-performance bucket splitting  
- Full rollback  
- Multi-table batching  
- Trigger-based routing  

It is suitable for **enterprise workloads**, **SaaS platforms**, and **massive datasets**.
