<#
.SYNOPSIS
  Compares three XMLA RLS-enforcement mechanisms against the live semantic model:
  static Roles=, entitlement-based CUSTOMDATA(), and (documented, not executed)
  EffectiveUserName.

.DESCRIPTION
  Part of docs/design_notes.md Section 16 (entitlement-based dynamic RLS prototype).
  Validates that the new dynamic role `Role_Entitlement` (dim_client[HomeRegion] =
  CUSTOMDATA()) produces IDENTICAL row sets to the original static roles
  (`Role_RegionA` / `Role_RegionB`) it replaces, for both test entitlement values.

  EffectiveUserName is NOT executed here — it requires a real Microsoft Entra ID
  identity with Read+Build permission on the model, which our synthetic test UPNs
  are not (confirmed via MS Learn connection-string-properties docs and prior
  empirical testing this project — see docs/design_notes.md Section 15c/16). It is
  included in the printed comparison table for completeness/documentation only.

  Reads CLIENT_ID/CLIENT_SECRET/TENANT_ID/XMLA_ENDPOINT/DATASET_NAME from .env,
  same pattern as scripts/test_embed_token.ps1.

.OUTPUTS
  Console PASS/FAIL summary for each (static role) vs (entitlement) comparison,
  plus the raw row sets for inspection.
#>

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot '.env'
$env = @{}
Get-Content $envPath | Where-Object { $_ -match "^\s*[^#].*=.+" } | ForEach-Object {
    $parts = $_ -split "=", 2
    $env[$parts[0].Trim()] = $parts[1].Trim()
}

$xmlaEndpoint = $env['XMLA_ENDPOINT']
$database     = $env['DATASET_NAME']
$clientId     = $env['CLIENT_ID']
$clientSecret = $env['CLIENT_SECRET']
$tenantId     = $env['TENANT_ID']

$queryScript = Join-Path $PSScriptRoot 'query_xmla.ps1'

$daxQuery = @'
EVALUATE
SUMMARIZECOLUMNS(
  dim_client[HomeRegion],
  "Total Spend USD", [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY dim_client[HomeRegion] ASC
'@

function Invoke-XmlaCompare {
    param(
        [string]$Label,
        [string]$Roles,
        [string]$CustomData
    )
    $params = @{
        XmlaEndpoint = $xmlaEndpoint
        Database     = $database
        Query        = $daxQuery
        ClientId     = $clientId
        ClientSecret = $clientSecret
        TenantId     = $tenantId
    }
    if ($Roles) { $params['Roles'] = $Roles }
    if ($CustomData) { $params['CustomData'] = $CustomData }

    Write-Host "`n--- $Label ---" -ForegroundColor Cyan
    Write-Host "Roles=$Roles  CustomData=$CustomData"
    $json = & $queryScript @params
    $rows = $json | ConvertFrom-Json
    $rows | Format-Table -AutoSize | Out-String | Write-Host
    return $rows
}

function Compare-RowSets {
    param($A, $B, [string]$LabelA, [string]$LabelB)
    $normA = ($A | ForEach-Object { "$($_.HomeRegion)|$($_.'Total Spend USD')|$($_.'Transaction Count')" }) -join "`n"
    $normB = ($B | ForEach-Object { "$($_.HomeRegion)|$($_.'Total Spend USD')|$($_.'Transaction Count')" }) -join "`n"
    if ($normA -eq $normB) {
        Write-Host "PASS: $LabelA row set == $LabelB row set (identical)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "FAIL: $LabelA row set != $LabelB row set" -ForegroundColor Red
        Write-Host "  ${LabelA}: $normA"
        Write-Host "  ${LabelB}: $normB"
        return $false
    }
}

Write-Host "=== RLS mechanism comparison: Static Roles= vs. CUSTOMDATA()-based dynamic RLS ===" -ForegroundColor Yellow

$baseline = Invoke-XmlaCompare -Label 'No RLS (baseline, all regions)' -Roles $null -CustomData $null

$staticA = Invoke-XmlaCompare -Label 'Static Role_RegionA (Roles=Role_RegionA)' -Roles 'Role_RegionA' -CustomData $null
$dynA    = Invoke-XmlaCompare -Label 'Dynamic Role_Entitlement (Roles=Role_Entitlement;CustomData=North America)' -Roles 'Role_Entitlement' -CustomData 'North America'
$resultA = Compare-RowSets -A $staticA -B $dynA -LabelA 'Role_RegionA (static)' -LabelB 'Role_Entitlement + CustomData=North America (dynamic)'

$staticB = Invoke-XmlaCompare -Label 'Static Role_RegionB (Roles=Role_RegionB)' -Roles 'Role_RegionB' -CustomData $null
$dynB    = Invoke-XmlaCompare -Label 'Dynamic Role_Entitlement (Roles=Role_Entitlement;CustomData=Europe)' -Roles 'Role_Entitlement' -CustomData 'Europe'
$resultB = Compare-RowSets -A $staticB -B $dynB -LabelA 'Role_RegionB (static)' -LabelB 'Role_Entitlement + CustomData=Europe (dynamic)'

Write-Host "`n=== Summary ===" -ForegroundColor Yellow
Write-Host "Baseline (no RLS) row count       : $($baseline.Count) (expected 5 regions)"
Write-Host "RegionA static vs dynamic parity   : $(if ($resultA) {'PASS'} else {'FAIL'})" -ForegroundColor ($(if ($resultA) {'Green'} else {'Red'}))
Write-Host "RegionB static vs dynamic parity   : $(if ($resultB) {'PASS'} else {'FAIL'})" -ForegroundColor ($(if ($resultB) {'Green'} else {'Red'}))
Write-Host "`nEffectiveUserName: NOT executed (requires a real Microsoft Entra ID identity with"
Write-Host "Read+Build permission on the model; synthetic test UPNs do not qualify — see"
Write-Host "docs/design_notes.md Section 16 for the full 3-way comparison table)."

if (-not ($resultA -and $resultB)) { exit 1 }
