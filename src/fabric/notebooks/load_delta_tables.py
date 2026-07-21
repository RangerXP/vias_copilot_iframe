# =============================================================================
# VISA Commercial Spend Analytics — Fabric Lakehouse Delta Table Loader
# =============================================================================
# Attach this notebook to the VISA PBIE Context Injection Fabric Lakehouse
# before running. Upload CSV files to:
#   Files/visa_commercial_spend_context_injection/
#
# Prerequisites:
#   - Fabric Lakehouse created in the VISA PBIE Context Injection workspace
#   - All 10 CSV files uploaded under Files/visa_commercial_spend_context_injection/
#   - Notebook attached to the Lakehouse (set as default Lakehouse in notebook settings)
#
# Tables created (in load order — dimensions first):
#   Dim_Date, Dim_Country, Dim_Segment, Dim_Product, Dim_ApprovalStatus,
#   Dim_MCC, Dim_Client, Dim_Merchant, Fact_CommercialSpend, Fact_FilterSession
# =============================================================================

from pyspark.sql.utils import AnalysisException

SOURCE_FOLDER = "Files/visa_commercial_spend_context_injection"

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
# Load each CSV into a managed Delta table in the attached Lakehouse
# ---------------------------------------------------------------------------
for table in TABLES:
    path = f"{SOURCE_FOLDER}/{table}.csv"
    print(f"Loading {table} from {path}...")
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
        df.write.format("delta").mode("overwrite").saveAsTable(table)
        print(f"  OK  {table}: {row_count:,} rows written")
    except AnalysisException as e:
        print(f"  ERR {table}: FAILED — {e}")

# ---------------------------------------------------------------------------
# Optimize fact tables for Direct Lake query performance
# ---------------------------------------------------------------------------
print("\nRunning OPTIMIZE on fact tables...")
spark.sql("OPTIMIZE Fact_CommercialSpend")
print("  OK  Fact_CommercialSpend optimized")

spark.sql("OPTIMIZE Fact_FilterSession")
print("  OK  Fact_FilterSession optimized")

# ---------------------------------------------------------------------------
# Verify: print row counts for all tables
# ---------------------------------------------------------------------------
print("\n--- Table summary ---")
for table in TABLES:
    try:
        count = spark.sql(f"SELECT COUNT(*) AS cnt FROM {table}").collect()[0]["cnt"]
        print(f"  {table}: {count:,} rows")
    except Exception as e:
        print(f"  {table}: ERROR — {e}")

print("\nDelta table load complete. Next: create Direct Lake semantic model over these tables.")
