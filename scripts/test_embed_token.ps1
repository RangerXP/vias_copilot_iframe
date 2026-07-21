# Test embed token generation using SP client credentials
# Reads CLIENT_ID/CLIENT_SECRET from .env

$envPath = "c:\Users\seankelley\OneDrive - Microsoft\Documents\VISA\PBI - Embedded\.env"
$env = @{}
Get-Content $envPath | Where-Object { $_ -match "^\s*[^#].*=.+" } | ForEach-Object {
    $parts = $_ -split "=", 2
    $env[$parts[0].Trim()] = $parts[1].Trim()
}

$tenantId   = $env["TENANT_ID"]
$clientId   = $env["CLIENT_ID"]
$clientSec  = $env["CLIENT_SECRET"]
$workspaceId = $env["WORKSPACE_ID"]
$reportId    = $env["REPORT_ID"]
$datasetId   = $env["DATASET_ID"]

Write-Host "CLIENT_ID   : $clientId"
Write-Host "TENANT_ID   : $tenantId"
Write-Host "SECRET set  : $($clientSec.Length -gt 0)"

# --- Get token via client_credentials ---
Write-Host "`n=== Acquiring SP token ===" -ForegroundColor Cyan
$tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSec
    scope         = "https://analysis.windows.net/powerbi/api/.default"
}
$tokenResp = Invoke-RestMethod -Uri $tokenUri -Method POST -Body $tokenBody
$spToken = $tokenResp.access_token
Write-Host "Token acquired (len=$($spToken.Length), expires_in=$($tokenResp.expires_in)s)"

# --- Generate embed token for report ---
Write-Host "`n=== GenerateToken (report scope) ===" -ForegroundColor Cyan
$spHeaders = @{Authorization="Bearer $spToken"; "Content-Type"="application/json"}
$genBody = @{
    reports = @(@{ id = $reportId })
    datasets = @(@{ id = $datasetId })
    targetWorkspaces = @(@{ id = $workspaceId })
} | ConvertTo-Json -Depth 4

$genResp = Invoke-WebRequest `
    -Uri "https://api.powerbi.com/v1.0/myorg/GenerateToken" `
    -Method POST -Headers $spHeaders -Body $genBody -SkipHttpErrorCheck

Write-Host "Status      : $($genResp.StatusCode)"
if ($genResp.StatusCode -eq 200) {
    $result = $genResp.Content | ConvertFrom-Json
    Write-Host "Embed token : $($result.token.Substring(0, 20))..." -ForegroundColor Green
    Write-Host "Expiry      : $($result.expiration)" -ForegroundColor Green
    Write-Host "`nSUCCESS — embed token flow is working." -ForegroundColor Green
} else {
    Write-Host "Body        : $($genResp.Content)" -ForegroundColor Red
}
