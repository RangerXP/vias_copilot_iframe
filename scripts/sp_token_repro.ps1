# Reproduce the working sequence: permission touch → credential reset → token test
$appId    = "595278db-8070-426d-85b5-7933db47de2c"
$tenantId = "b7e47691-9726-4f67-a302-e567815f3522"

# Step 1: Touch app via permission add (may warn it already exists — that's ok)
Write-Host "=== Step 1: Permission add (touch app) ===" -ForegroundColor Cyan
az ad app permission add --id $appId --api "00000009-0000-0000-c000-000000000000" --api-permissions "7504609f-c495-4c64-8542-686125a5a36f=Role" 2>&1 | Write-Host

# Step 2: Reset credential IMMEDIATELY after permission touch
Write-Host "`n=== Step 2: Credential reset ===" -ForegroundColor Cyan
$cred = az ad app credential reset --id $appId --display-name "embed-final" --years 1 -o json | ConvertFrom-Json
Write-Host "Hint: $($cred.password.Substring(0,4))..."

# Step 3: Wait 5s (same as configure_sp.ps1 that worked)
Write-Host "Waiting 5s..." ; Start-Sleep 5

# Step 4: Token test using hashtable body (PowerShell native form encoding)
Write-Host "`n=== Step 3: Token test (hashtable body) ===" -ForegroundColor Cyan
$tb = @{
    grant_type    = "client_credentials"
    client_id     = $cred.appId
    client_secret = $cred.password
    scope         = "https://analysis.windows.net/powerbi/api/.default"
}
$tr = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tb -SkipHttpErrorCheck
Write-Host "Status: $($tr.StatusCode)"
if ($tr.StatusCode -eq 200) {
    Write-Host "SUCCESS with 5s+hashtable" -ForegroundColor Green
} else {
    # Try with URL-encoded form body
    Write-Host "Retrying with URL-encoded form..." -ForegroundColor Yellow
    Start-Sleep 30
    $tb2 = "grant_type=client_credentials&client_id=$($cred.appId)&client_secret=$([System.Uri]::EscapeDataString($cred.password))&scope=https%3A%2F%2Fanalysis.windows.net%2Fpowerbi%2Fapi%2F.default"
    $tr2 = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tb2 -ContentType "application/x-www-form-urlencoded" -SkipHttpErrorCheck
    Write-Host "Status (retry): $($tr2.StatusCode)"
    if ($tr2.StatusCode -eq 200) {
        Write-Host "SUCCESS with 35s+encoded" -ForegroundColor Green
        $tr = $tr2
    } else {
        Write-Host $tr2.Content -ForegroundColor Red
    }
}
Write-Host $tr.Content.Substring(0, [Math]::Min(80, $tr.Content.Length))
