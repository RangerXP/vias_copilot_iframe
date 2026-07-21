# Configure SP: add Power BI API permissions, grant admin consent, test token
$appId = "595278db-8070-426d-85b5-7933db47de2c"

# Power BI Service app = 00000009-0000-0000-c000-000000000000
# Application permissions needed for App-Owns-Data embed:
#   Tenant.Read.All  = 7504609f-c495-4c64-8542-686125a5a36f
#   Tenant.ReadWrite.All = 4ae1bf56-f562-4747-b7bc-2fa0874ed46f

Write-Host "=== Adding Power BI API permissions ===" -ForegroundColor Cyan
az ad app permission add --id $appId `
    --api "00000009-0000-0000-c000-000000000000" `
    --api-permissions "7504609f-c495-4c64-8542-686125a5a36f=Role" 2>&1 | Write-Host

Write-Host "`n=== Granting admin consent ===" -ForegroundColor Cyan
az ad app permission admin-consent --id $appId 2>&1 | Write-Host

Write-Host "`n=== Current permissions ===" -ForegroundColor Cyan
az ad app permission list --id $appId -o table 2>&1

# Try login as SP
Write-Host "`n=== Creating fresh secret + token test ===" -ForegroundColor Cyan
$cred = az ad app credential reset --id $appId --display-name "embed-v2" --years 1 -o json | ConvertFrom-Json
Write-Host "Secret hint: $($cred.password.Substring(0,4))..."

Start-Sleep -Seconds 5

$tb = "grant_type=client_credentials&client_id=$appId&client_secret=$([System.Uri]::EscapeDataString($cred.password))&scope=https%3A%2F%2Fanalysis.windows.net%2Fpowerbi%2Fapi%2F.default"
$tr = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$($cred.tenant)/oauth2/v2.0/token" -Method POST -Body $tb -ContentType "application/x-www-form-urlencoded" -SkipHttpErrorCheck
Write-Host "Token status: $($tr.StatusCode)"
Write-Host $tr.Content
