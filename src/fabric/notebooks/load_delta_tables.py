# =============================================================================
# VISA Commercial Spend Analytics — Fabric Lakehouse Delta Table Loader
# =============================================================================
# Lakehouse: Commercial_Spend_Analytics (schema-enabled)
# Workspace: VISA PBIE Context Injection (349db6f1-5df6-4992-ba67-ebc4449fead5)
# Lakehouse ID: 1aa73044-f85f-4843-b3e5-588cab4c0499
#
# CSV files are in the root of Files/ (no subfolder):
#   Files/Dim_Date.csv, Files/Fact_CommercialSpend.csv, etc.
#
# This is a schema-enabled Lakehouse. Tables are created in the dbo schema.
# Attach this notebook to the Commercial_Spend_Analytics Lakehouse before running.
# =============================================================================

from pyspark.sql.utils import AnalysisException

# Files are in the root of the Files/ area (no subfolder)
SOURCE_FOLDER = "Files"

# Schema prefix for schema-enabled Lakehouse
SCHEMA = "dbo"

# Dimensions loaded before facts so foreign key relationships are valid
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

# ---------------------------------------------------------------------------
# Load each CSV into a managed Delta table in the dbo schema
# ---------------------------------------------------------------------------
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
        print(f"  OK  {qualified}: {row_count:,} rows written")
    except AnalysisException as e:
        print(f"  ERR {qualified}: FAILED — {e}")

# ---------------------------------------------------------------------------
# Optimize fact tables for Direct Lake query performance
# ---------------------------------------------------------------------------
print("\nRunning OPTIMIZE on fact tables...")
spark.sql(f"OPTIMIZE {SCHEMA}.Fact_CommercialSpend")
print(f"  OK  {SCHEMA}.Fact_CommercialSpend optimized")

spark.sql(f"OPTIMIZE {SCHEMA}.Fact_FilterSession")
print(f"  OK  {SCHEMA}.Fact_FilterSession optimized")

# ---------------------------------------------------------------------------
# Verify: print row counts for all tables
# ---------------------------------------------------------------------------
print("\n--- Table summary ---")
for table in TABLES:
    qualified = f"{SCHEMA}.{table}"
    try:
        count = spark.sql(f"SELECT COUNT(*) AS cnt FROM {qualified}").collect()[0]["cnt"]
        print(f"  {qualified}: {count:,} rows")
    except Exception as e:
        print(f"  {qualified}: ERROR — {e}")

print("\nDelta table load complete. Next: create Direct Lake semantic model over these tables.")
