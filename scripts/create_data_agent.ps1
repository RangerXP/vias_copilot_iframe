# Create (or update) a Fabric Data Agent against a Commercial_Spend_Analytics semantic model.
# Pass -ItemId to update an EXISTING Data Agent's datasource (e.g. one created by a
# Fabric Git Integration sync) instead of creating a brand new item.
param(
    [string]$WorkspaceId  = "349db6f1-5df6-4992-ba67-ebc4449fead5",
    [string]$SemanticModelId = "b7bc94fc-a087-4e71-9476-f128ba57cf3a",
    [string]$AgentName    = "Commercial_Spend_Agent",
    [string]$ItemId
)

$ErrorActionPreference = "Stop"

function ConvertTo-B64([string]$json) {
    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

Write-Host "Getting Fabric token..." -ForegroundColor Cyan
$token = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
Write-Host "  Token length: $($token.Length)" -ForegroundColor Green

# --- Build each config file ------------------------------------------------

$dataAgentJson = @'
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/dataAgent/2.1.0/schema.json"
}
'@

$stageConfigJson = @'
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/stageConfiguration/1.0.0/schema.json",
  "aiInstructions": "You are a VISA commercial spend analytics assistant with access to the Commercial_Spend_Analytics Direct Lake semantic model. This model contains 250,000 synthetic commercial card transactions across 8 dimension tables.\n\nAlways use DAX measures for aggregations:\n- [Total Spend USD] - sum of SpendAmountUSD\n- [Transaction Count] - sum of TransactionCount\n- [Average Ticket USD] - spend divided by count\n- [Interchange Revenue USD] - sum of interchange\n- [Fraud Exposure Score] - average FraudScore\n- [High Fraud Transactions] - count where FraudScore >= 70\n- [Approval Rate] - % Approved transactions\n- [Decline Rate] - % Declined transactions\n- [Spend YoY %] - year-over-year spend change\n\nFilter context: the fact_filtersession table captures the host application current filter state (active year, quarter, country, client, segment, product, MCC, merchant). Reference it to ground your answers to what the user is currently viewing in the embedded report."
}
'@

$datasourceJson = "{
  `"`$schema`": `"1.0.0`",
  `"artifactId`": `"$SemanticModelId`",
  `"workspaceId`": `"$WorkspaceId`",
  `"displayName`": `"Commercial_Spend_Analytics`",
  `"type`": `"semantic_model`",
  `"userDescription`": `"VISA Commercial Spend Analytics — Direct Lake semantic model with 250k commercial card transactions, 8 dimension tables, and 9 DAX measures.`",
  `"dataSourceInstructions`": `"Use DAX measures for all aggregations. Available dimensions: dim_date, dim_client, dim_country, dim_merchant, dim_mcc, dim_product, dim_segment, dim_approvalstatus. The fact_filtersession table contains host-app filter context transitions that reflect what the user is currently filtering in the embedded Power BI report.`"
}"

$fewshotsJson = @'
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/fewShots/1.0.0/schema.json",
  "fewShots": []
}
'@

# --- Assemble definition parts ---------------------------------------------

$parts = @(
    @{ path = "Files/Config/data_agent.json";                                                    payload = ConvertTo-B64 $dataAgentJson;    payloadType = "InlineBase64" },
    @{ path = "Files/Config/draft/stage_config.json";                                             payload = ConvertTo-B64 $stageConfigJson;  payloadType = "InlineBase64" },
    @{ path = "Files/Config/draft/semanticmodel-Commercial_Spend_Analytics/datasource.json";       payload = ConvertTo-B64 $datasourceJson;   payloadType = "InlineBase64" },
    @{ path = "Files/Config/draft/semanticmodel-Commercial_Spend_Analytics/fewshots.json";         payload = ConvertTo-B64 $fewshotsJson;     payloadType = "InlineBase64" }
)

$requestBody = @{
    displayName = $AgentName
    type        = "DataAgent"
    definition  = @{ parts = $parts }
} | ConvertTo-Json -Depth 10

# --- POST (create) or updateDefinition (existing item) ---------------------

if ($ItemId) {
    Write-Host "Updating Data Agent '$AgentName' ($ItemId) datasource..." -ForegroundColor Cyan
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$ItemId/updateDefinition"
    $updateBody = @{ definition = @{ parts = $parts } } | ConvertTo-Json -Depth 10
    try {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $updateBody | Out-Null
        Write-Host "SUCCESS — datasource re-pointed to workspace $WorkspaceId / model $SemanticModelId" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host "DETAILS: $($_.ErrorDetails.Message)" -ForegroundColor Yellow }
    }
} else {
    Write-Host "Creating Data Agent '$AgentName'..." -ForegroundColor Cyan
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $requestBody
        Write-Host "SUCCESS" -ForegroundColor Green
        Write-Host "  Agent ID  : $($response.id)"
        Write-Host "  Name      : $($response.displayName)"
        Write-Host "  Type      : $($response.type)"
        Write-Host "  Workspace : $($response.workspaceId)"
        $response | ConvertTo-Json -Depth 5
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host "DETAILS: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
        }
    }
}
