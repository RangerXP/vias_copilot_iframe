# data/

This folder contains the 10 synthetic CSV files used to seed the
Commercial_Spend_Analytics Lakehouse (via Load_Delta_Tables.Notebook or an
equivalent load step). All data is fully synthetic — no real client names,
merchants, card numbers, or transactions.

Files included:
  Dim_Date.csv           (1,096 rows)
  Dim_Client.csv         (500 rows)
  Dim_Country.csv        (30 rows)
  Dim_Product.csv        (8 rows)
  Dim_Segment.csv        (10 rows)
  Dim_Merchant.csv       (1,000 rows)
  Dim_MCC.csv            (15 rows)
  Dim_ApprovalStatus.csv (4 rows)
  Fact_CommercialSpend.csv (250,000 rows)
  Fact_FilterSession.csv   (5,000 rows)

These files are committed to git — see .gitignore, which blocks all other
data/*.csv files by default but explicitly allows these 10 filenames. Do not
add real transaction data or any other CSVs to this folder.

Regenerating from source: scripts/export_source_csvs.ps1 re-exports these
same 10 tables from a live Commercial_Spend_Analytics semantic model via
XMLA (useful if the data model changes and these files need refreshing).
