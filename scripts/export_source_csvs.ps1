<#
.SYNOPSIS
  Reconstructs the 10 original demo CSVs by querying the live semantic model
  via XMLA and exporting each table's rows to data/<Name>.csv.

.DESCRIPTION
  The original source CSVs (data/README.txt) were consumed by
  Load_Delta_Tables.Notebook and are no longer retained in the Lakehouse
  Files/ area. This script pulls the same data back out of the live
  Direct Lake semantic model (EVALUATE <table>) so the demo dataset can be
  packaged into the repo for a self-contained install. Uses the same SP
  client-credentials + XMLA auth pattern as scripts/query_xmla.ps1.

  Requires .env with XMLA_ENDPOINT, DATASET_NAME, CLIENT_ID, CLIENT_SECRET,
  TENANT_ID (same values used by server/services/fabricAgent.js).
  Requires the SqlServer PowerShell module (Invoke-ASCmd):
    Install-Module SqlServer -Scope CurrentUser

.PARAMETER OutDir
  Local folder to write CSVs into. Defaults to data/ at the repo root.
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\data')
)

$ErrorActionPreference = 'Stop'

# --- Load .env (simple KEY=VALUE parser, no external dependency) -----------
$envPath = Join-Path $PSScriptRoot '..\.env'
if (-not (Test-Path $envPath)) {
    Write-Error ".env not found at $envPath"
    exit 1
}
Get-Content $envPath | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$' -and $_ -notmatch '^\s*#') {
        $name = $Matches[1]
        $value = $Matches[2].Trim('"')
        [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

$XmlaEndpoint = $env:XMLA_ENDPOINT
$Database     = $env:DATASET_NAME
if (-not $Database) { $Database = 'Commercial_Spend_Analytics' }
$ClientId     = $env:CLIENT_ID
$ClientSecret = $env:CLIENT_SECRET
$TenantId     = $env:TENANT_ID

if (-not $XmlaEndpoint -or -not $ClientId -or -not $ClientSecret -or -not $TenantId) {
    Write-Error "XMLA_ENDPOINT/CLIENT_ID/CLIENT_SECRET/TENANT_ID must be set in .env"
    exit 1
}

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Error "SqlServer PowerShell module not found. Install it with: Install-Module SqlServer -Scope CurrentUser"
    exit 1
}
Import-Module SqlServer -ErrorAction Stop

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

# Model table name (lowercase, per TMDL) -> original CSV filename (PascalCase,
# matches Load_Delta_Tables.Notebook's TABLES list and data/README.txt).
$TableMap = [ordered]@{
    'dim_date'           = 'Dim_Date'
    'dim_country'        = 'Dim_Country'
    'dim_segment'        = 'Dim_Segment'
    'dim_product'        = 'Dim_Product'
    'dim_approvalstatus' = 'Dim_ApprovalStatus'
    'dim_mcc'            = 'Dim_MCC'
    'dim_client'         = 'Dim_Client'
    'dim_merchant'       = 'Dim_Merchant'
    'fact_commercialspend' = 'Fact_CommercialSpend'
    'fact_filtersession' = 'Fact_FilterSession'
}

$connStringParts = @(
    'Provider=MSOLAP',
    "Data Source=$XmlaEndpoint",
    "Initial Catalog=$Database",
    "User ID=app:$ClientId@$TenantId",
    "Password=$ClientSecret",
    'Persist Security Info=True',
    'Impersonation Level=Impersonate'
)
$connectionString = ($connStringParts -join ';')

foreach ($modelTable in $TableMap.Keys) {
    $csvName = $TableMap[$modelTable]
    $query = "EVALUATE $modelTable"
    Write-Host "Exporting $modelTable -> data/$csvName.csv ..." -ForegroundColor Cyan

    try {
        # Long timeout — Fact_CommercialSpend has ~250k rows.
        $rawXml = Invoke-ASCmd -ConnectionString $connectionString -Query $query -QueryTimeout 600
    } catch {
        Write-Host "  ERROR querying $modelTable`: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    [xml]$doc = $rawXml
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('ra', 'urn:schemas-microsoft-com:xml-analysis:rowset')
    $ns.AddNamespace('xsd', 'http://www.w3.org/2001/XMLSchema')

    $colMap = @{}
    $schemaElements = $doc.SelectNodes("//xsd:complexType[@name='row']/xsd:sequence/xsd:element", $ns)
    foreach ($el in $schemaElements) {
        $genericName = $el.GetAttribute('name')
        $fieldAttr = $el.GetAttribute('field', 'urn:schemas-microsoft-com:xml-sql')
        if ($genericName -and $fieldAttr) {
            $bracketMatches = [regex]::Matches($fieldAttr, '\[([^\]]+)\]')
            if ($bracketMatches.Count -gt 0) {
                $colMap[$genericName] = $bracketMatches[$bracketMatches.Count - 1].Groups[1].Value
            } else {
                $colMap[$genericName] = $fieldAttr
            }
        }
    }

    $rowNodes = $doc.SelectNodes('//ra:row', $ns)
    if (-not $rowNodes -or $rowNodes.Count -eq 0) {
        $rowNodes = $doc.GetElementsByTagName('row')
    }

    $results = @()
    foreach ($row in $rowNodes) {
        $obj = [ordered]@{}
        foreach ($child in $row.ChildNodes) {
            if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            $key = $colMap[$child.LocalName]
            if (-not $key) { $key = $child.LocalName }
            $obj[$key] = $child.InnerText
        }
        $results += [pscustomobject]$obj
    }

    if ($results.Count -eq 0) {
        Write-Host "  WARNING: 0 rows returned for $modelTable" -ForegroundColor Yellow
        continue
    }

    $outPath = Join-Path $OutDir "$csvName.csv"
    $results | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Wrote $($results.Count) rows -> $outPath" -ForegroundColor Green
}

Write-Host "`nDone. Review data/*.csv before committing." -ForegroundColor Cyan
