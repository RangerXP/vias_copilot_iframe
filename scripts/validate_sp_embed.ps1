# Full SP validation: credential reset → 40s propagation → SP token → embed token → write .env
$appId       = "595278db-8070-426d-85b5-7933db47de2c"
$tenantId    = "b7e47691-9726-4f67-a302-e567815f3522"
$workspaceId = "349db6f1-5df6-4992-ba67-ebc4449fead5"
$reportId    = "e833a03b-2cf9-42d2-a1ee-a40f847fd75d"
$datasetId   = "b7bc94fc-a087-4e71-9476-f128ba57cf3a"
$envPath     = "c:\Users\seankelley\OneDrive - Microsoft\Documents\VISA\PBI - Embedded\.env"

# Touch app (required to unblock credential validation)
az ad app permission add --id $appId --api "00000009-0000-0000-c000-000000000000" --api-permissions "7504609f-c495-4c64-8542-686125a5a36f=Role" 2>&1 | Out-Null

# Fresh credential
Write-Host "=== Creating SP credential ===" -ForegroundColor Cyan
$cred = az ad app credential reset --id $appId --display-name "embed-prod" --years 1 -o json | ConvertFrom-Json
$clientSecret = $cred.password
Write-Host "Hint: $($clientSecret.Substring(0,4))..."
Write-Host "Waiting 40s for AAD propagation..."
$i=40; while($i -gt 0){Write-Host -NoNewline "$i "; Start-Sleep 5; $i-=5}; Write-Host ""

# Acquire token (URL-encoded form body)
Write-Host "`n=== Acquiring SP token ===" -ForegroundColor Cyan
$tb = "grant_type=client_credentials&client_id=$appId&client_secret=$([System.Uri]::EscapeDataString($clientSecret))&scope=https%3A%2F%2Fanalysis.windows.net%2Fpowerbi%2Fapi%2F.default"
$tr = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tb -ContentType "application/x-www-form-urlencoded" -SkipHttpErrorCheck
Write-Host "Token status: $($tr.StatusCode)"
if ($tr.StatusCode -ne 200) { Write-Host $tr.Content -ForegroundColor Red; exit 1 }
$tok = ($tr.Content | ConvertFrom-Json).access_token
Write-Host "SP token acquired (len=$($tok.Length))" -ForegroundColor Green

# Embed token
Write-Host "`n=== GenerateToken ===" -ForegroundColor Cyan
$ph = @{Authorization="Bearer $tok"; "Content-Type"="application/json"}
$gb = @{
    reports          = @(@{id=$reportId})
    datasets         = @(@{id=$datasetId})
    targetWorkspaces = @(@{id=$workspaceId})
} | ConvertTo-Json -Depth 4
$gr = Invoke-WebRequest -Uri "https://api.powerbi.com/v1.0/myorg/GenerateToken" -Method POST -Headers $ph -Body $gb -SkipHttpErrorCheck
Write-Host "Embed status: $($gr.StatusCode)"

if ($gr.StatusCode -eq 200) {
    $et = ($gr.Content | ConvertFrom-Json)
    Write-Host "Embed token : $($et.token.Substring(0,25))..." -ForegroundColor Green
    Write-Host "Expiry      : $($et.expiration)" -ForegroundColor Green
}
else { Write-Host "Embed error: $($gr.Content)" -ForegroundColor Red }

# Write to .env
Write-Host "`n=== Writing .env ===" -ForegroundColor Cyan
$lines = Get-Content $envPath
$newLines = $lines | ForEach-Object {
    if ($_ -match "^#?\s*CLIENT_ID=")         { "CLIENT_ID=$appId" }
    elseif ($_ -match "^#?\s*CLIENT_SECRET=") { "CLIENT_SECRET=$clientSecret" }
    else { $_ }
}
[System.IO.File]::WriteAllLines($envPath, $newLines, [System.Text.Encoding]::UTF8)
$rb = @{}; Get-Content $envPath | Where-Object { $_ -match "^CLIENT_" } | ForEach-Object { $p=$_ -split "=",2; $rb[$p[0]]=$p[1] }
Write-Host "CLIENT_ID   : $($rb['CLIENT_ID'])"
Write-Host "SECRET ok   : $($rb['CLIENT_SECRET'] -ceq $clientSecret) (len=$($rb['CLIENT_SECRET'].Length))"

# 1. Fresh credential
Write-Host "=== Creating fresh SP credential ===" -ForegroundColor Cyan
$cred = az ad app credential reset --id $appId --display-name "embed-prod" --years 1 -o json | ConvertFrom-Json
$clientSecret = $cred.password
Write-Host "Credential hint: $($clientSecret.Substring(0,4))..."

# 2. Acquire token (with brief wait for AAD propagation)
Write-Host "`n=== Acquiring token (waiting 10s for AAD propagation) ===" -ForegroundColor Cyan
Start-Sleep -Seconds 10
$tb = "grant_type=client_credentials&client_id=$appId&client_secret=$([System.Uri]::EscapeDataString($clientSecret))&scope=https%3A%2F%2Fanalysis.windows.net%2Fpowerbi%2Fapi%2F.default"
$tr = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tb -ContentType "application/x-www-form-urlencoded" -SkipHttpErrorCheck
Write-Host "Token status: $($tr.StatusCode)"

if ($tr.StatusCode -ne 200) {
    Write-Host "FAILED: $($tr.Content)" -ForegroundColor Red
    exit 1
}
$tok = ($tr.Content | ConvertFrom-Json).access_token
Write-Host "Token acquired (len=$($tok.Length))" -ForegroundColor Green

# 3. Test embed token
Write-Host "`n=== GenerateToken ===" -ForegroundColor Cyan
$ph = @{Authorization="Bearer $tok"; "Content-Type"="application/json"}
$gb = @{
    reports          = @(@{id=$reportId})
    datasets         = @(@{id=$datasetId})
    targetWorkspaces = @(@{id=$workspaceId})
} | ConvertTo-Json -Depth 4
$gr = Invoke-WebRequest -Uri "https://api.powerbi.com/v1.0/myorg/GenerateToken" -Method POST -Headers $ph -Body $gb -SkipHttpErrorCheck
Write-Host "Embed status: $($gr.StatusCode)"

if ($gr.StatusCode -eq 200) {
    $et = ($gr.Content | ConvertFrom-Json)
    Write-Host "Embed token : $($et.token.Substring(0,20))..." -ForegroundColor Green
    Write-Host "Expiry      : $($et.expiration)" -ForegroundColor Green
    $embedSuccess = $true
} else {
    Write-Host "Embed error : $($gr.Content)" -ForegroundColor Red
    $embedSuccess = $false
}

# 4. Write to .env regardless of embed result (SP token works)
Write-Host "`n=== Writing credentials to .env ===" -ForegroundColor Cyan
$lines = Get-Content $envPath
$newLines = $lines | ForEach-Object {
    if ($_ -match "^#?\s*CLIENT_ID=")         { "CLIENT_ID=$appId" }
    elseif ($_ -match "^#?\s*CLIENT_SECRET=") { "CLIENT_SECRET=$clientSecret" }
    else { $_ }
}
[System.IO.File]::WriteAllLines($envPath, $newLines, [System.Text.Encoding]::UTF8)

# Verify round-trip
$rb = @{}; Get-Content $envPath | Where-Object { $_ -match "^CLIENT_" } | ForEach-Object { $p=$_ -split "=",2; $rb[$p[0]]=$p[1] }
Write-Host "Readback CLIENT_ID     : $($rb['CLIENT_ID'])"
Write-Host "Readback SECRET match  : $($rb['CLIENT_SECRET'] -ceq $clientSecret)"
Write-Host "Readback SECRET length : $($rb['CLIENT_SECRET'].Length)"

if ($embedSuccess) {
    Write-Host "`n✅ FULL EMBED FLOW WORKING — SP credentials in .env" -ForegroundColor Green
} else {
    Write-Host "`n⚠  SP token works but embed token blocked — check PBI tenant setting 'Allow service principals to use Power BI APIs'" -ForegroundColor Yellow
    Write-Host "   SP credentials still written to .env" -ForegroundColor Yellow
}
