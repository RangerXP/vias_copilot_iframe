# Fabric Workspace Discovery Script
# Run this after registering a native service principal in the mngenvmcap253522 tenant
# OR run interactively with device code flow using a native tenant account

# =============================================================================
# CONFIG — fill these in before running
# =============================================================================
$tenantId    = "mngenvmcap253522.onmicrosoft.com"
$clientId    = ""   # leave blank to use device code flow (interactive)
$clientSecret = "" # leave blank to use device code flow (interactive)
$subscriptionId = "7bfa54e8-38b2-49dc-9f48-98729405ecc9"

# =============================================================================
# AUTH
# =============================================================================
if ($clientId -and $clientSecret) {
    # Service principal (client credentials)
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = "https://analysis.windows.net/powerbi/api/.default"
    }
    $tokenResp = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $body
    $token = $tokenResp.access_token
} else {
    # Interactive device code flow
    $token = az account get-access-token `
        --resource https://analysis.windows.net/powerbi/api `
        --tenant $tenantId --query accessToken -o tsv
}

$h = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# =============================================================================
# WORKSPACES
# =============================================================================
Write-Host "`n=== WORKSPACES ===" -ForegroundColor Cyan
$workspaces = (Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups?`$top=100" -Headers $h).value
$workspaces | Format-Table id, name, isOnDedicatedCapacity, capacityId -AutoSize

# =============================================================================
# FOR EACH WORKSPACE: LIST DATASETS (SEMANTIC MODELS) AND REPORTS
# =============================================================================
foreach ($ws in $workspaces) {
    Write-Host "`n=== Workspace: $($ws.name) ($($ws.id)) ===" -ForegroundColor Yellow

    # Semantic Models
    try {
        $datasets = (Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($ws.id)/datasets" -Headers $h).value
        if ($datasets.Count -gt 0) {
            Write-Host "  Semantic Models:" -ForegroundColor Green
            $datasets | ForEach-Object {
                Write-Host "    ID:   $($_.id)"
                Write-Host "    Name: $($_.name)"
                Write-Host "    Mode: $($_.storageMode)"
                Write-Host ""
            }
        }
    } catch { Write-Host "  Could not list datasets: $_" -ForegroundColor Red }

    # Reports
    try {
        $reports = (Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($ws.id)/reports" -Headers $h).value
        if ($reports.Count -gt 0) {
            Write-Host "  Reports:" -ForegroundColor Green
            $reports | ForEach-Object {
                Write-Host "    ID:         $($_.id)"
                Write-Host "    Name:       $($_.name)"
                Write-Host "    Dataset ID: $($_.datasetId)"
                Write-Host "    Embed URL:  $($_.embedUrl)"
                Write-Host ""
            }
        }
    } catch { Write-Host "  Could not list reports: $_" -ForegroundColor Red }
}

# =============================================================================
# OUTPUT ENV FILE SNIPPET
# =============================================================================
Write-Host "`n=== .env TEMPLATE ===" -ForegroundColor Cyan
Write-Host "Copy the IDs above into this template:"
Write-Host @"
TENANT_ID=mngenvmcap253522.onmicrosoft.com
CLIENT_ID=$clientId
CLIENT_SECRET=<your-secret>
WORKSPACE_ID=<paste-workspace-id>
REPORT_ID=<paste-report-id>
DATASET_ID=<paste-dataset-id>
"@
