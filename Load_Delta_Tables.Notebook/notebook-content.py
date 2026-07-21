# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "language_info": {
# META     "name": "python"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "1aa73044-f85f-4843-b3e5-588cab4c0499",
# META       "default_lakehouse_name": "Commercial_Spend_Analytics",
# META       "default_lakehouse_workspace_id": "349db6f1-5df6-4992-ba67-ebc4449fead5"
# META     }
# META   }
# META }

# CELL ********************

# =============================================================================
# VISA Commercial Spend Analytics — Delta Table Loader
# Lakehouse : Commercial_Spend_Analytics (schema-enabled, dbo)
# Workspace : VISA PBIE Context Injection
# Source    : Files/<TableName>.csv (root of Files/ area)
# Output    : dbo.<TableName> Delta tables
# =============================================================================

from pyspark.sql.utils import AnalysisException

SOURCE_FOLDER = "Files"
SCHEMA = "dbo"

TABLES = [
    "Dim_Date",
    "Dim_Country",
    "Dim_Segment",
    "Dim_Product",
    "Dim_ApprovalStatus",
    "Dim_MCC",
    "Dim_Client",
    "Dim_Merchant",
    "Fact_CommercialSpend",
    "Fact_FilterSession",
]

# CELL ********************

# Load each CSV into a managed Delta table in the dbo schema
for table in TABLES:
    path = f"{SOURCE_FOLDER}/{table}.csv"
    qualified = f"{SCHEMA}.{table}"
    print(f"Loading {qualified} from {path}...")
    try:
        df = (
            spark.read
            .option("header", True)
            .option("inferSchema", True)
            .option("multiLine", True)
            .option("escape", '"')
            .csv(path)
        )
        row_count = df.count()
        df.write.format("delta").mode("overwrite").saveAsTable(qualified)
        print(f"  OK  {qualified}: {row_count:,} rows")
    except AnalysisException as e:
        print(f"  ERR {qualified}: FAILED — {e}")

# CELL ********************

# Optimize fact tables for Direct Lake query performance
spark.sql(f"OPTIMIZE {SCHEMA}.Fact_CommercialSpend")
print(f"  OK  {SCHEMA}.Fact_CommercialSpend optimized")

spark.sql(f"OPTIMIZE {SCHEMA}.Fact_FilterSession")
print(f"  OK  {SCHEMA}.Fact_FilterSession optimized")

# CELL ********************

# Verify — print row counts for all tables
print("\n--- Table summary ---")
for table in TABLES:
    qualified = f"{SCHEMA}.{table}"
    try:
        count = spark.sql(f"SELECT COUNT(*) AS cnt FROM {qualified}").collect()[0]["cnt"]
        print(f"  {qualified}: {count:,} rows")
    except Exception as e:
        print(f"  {qualified}: ERROR — {e}")

print("\nDone. Next: create Direct Lake semantic model over dbo.* tables.")
