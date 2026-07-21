# Create minimal Power BI report bound to Commercial_Spend_Analytics semantic model
param(
    [string]$WorkspaceId     = "349db6f1-5df6-4992-ba67-ebc4449fead5",
    [string]$SemanticModelId = "b7bc94fc-a087-4e71-9476-f128ba57cf3a",
    [string]$ReportName      = "Commercial_Spend_Analytics"
)

$ErrorActionPreference = "Stop"

function ConvertTo-B64([string]$json) {
    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

Write-Host "Getting Power BI token..." -ForegroundColor Cyan
$token   = (az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
Write-Host "  Token length: $($token.Length)" -ForegroundColor Green

$pageId = "a1b2c3d4e5f601234567"

# 1. definition.pbir — bind report to semantic model by ID
$pbir = @"
{
  "`$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json",
  "version": "4.0",
  "datasetReference": {
    "byConnection": {
      "connectionString": "semanticmodelid=$SemanticModelId"
    }
  }
}
"@

# 2. definition/version.json
$versionJson = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/report/definition/versionMetadata/1.0.0/schema.json","version":"2.0.0"}'

# 3. definition/report.json — minimal report settings
$reportJson = @'
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/3.1.0/schema.json",
  "themeCollection": {
    "baseTheme": {
      "name": "CY25SU12",
      "reportVersionAtImport": { "visual": "2.5.0", "report": "3.1.0", "page": "2.3.0" },
      "type": "SharedResources"
    }
  },
  "resourcePackages": [
    {
      "name": "SharedResources",
      "type": "SharedResources",
      "items": [
        { "name": "CY25SU12", "path": "BaseThemes/CY25SU12.json", "type": "BaseTheme" }
      ]
    }
  ],
  "settings": {
    "useStylableVisualContainerHeader": true,
    "defaultFilterActionIsDataFilter": true,
    "defaultDrillFilterOtherVisuals": true,
    "allowChangeFilterTypes": true
  }
}
'@

# 4. definition/pages/pages.json
$pagesJson = @"
{
  "`$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.0.0/schema.json",
  "pageOrder": ["$pageId"],
  "activePageName": "$pageId"
}
"@

# 5. definition/pages/{pageId}/page.json
$pageJson = @"
{
  "`$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.1.0/schema.json",
  "name": "$pageId",
  "displayName": "Overview",
  "displayOption": "FitToPage",
  "height": 720,
  "width": 1280
}
"@

$parts = @(
    @{ path = "definition.pbir";                                    payload = ConvertTo-B64 $pbir;       payloadType = "InlineBase64" },
    @{ path = "definition/version.json";                             payload = ConvertTo-B64 $versionJson; payloadType = "InlineBase64" },
    @{ path = "definition/report.json";                              payload = ConvertTo-B64 $reportJson;  payloadType = "InlineBase64" },
    @{ path = "definition/pages/pages.json";                         payload = ConvertTo-B64 $pagesJson;   payloadType = "InlineBase64" },
    @{ path = "definition/pages/$pageId/page.json";                  payload = ConvertTo-B64 $pageJson;    payloadType = "InlineBase64" }
)

$body = @{
    displayName = $ReportName
    type        = "Report"
    definition  = @{ parts = $parts }
} | ConvertTo-Json -Depth 10

Write-Host "Creating report '$ReportName'..." -ForegroundColor Cyan
$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items"

try {
    $resp = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
    Write-Host "SUCCESS" -ForegroundColor Green
    Write-Host "  Report ID : $($resp.id)"
    Write-Host "  Name      : $($resp.displayName)"
    Write-Host "  Type      : $($resp.type)"
    $resp | ConvertTo-Json -Depth 5
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "DETAILS: $($_.ErrorDetails.Message)" -ForegroundColor Yellow }
}
