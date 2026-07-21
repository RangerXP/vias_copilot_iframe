# Inline token test — no .env dependency, URL-encodes secret
$fresh = az ad app credential reset --id "595278db-8070-426d-85b5-7933db47de2c" --display-name "pbie-embed-2026" --years 1 -o json | ConvertFrom-Json
Write-Host "appId  : $($fresh.appId)"
Write-Host "tenant : $($fresh.tenant)"
Write-Host "hint   : $($fresh.password.Substring(0,4))..."

$encodedSecret = [System.Uri]::EscapeDataString($fresh.password)
$tb = "grant_type=client_credentials&client_id=$($fresh.appId)&client_secret=$encodedSecret&scope=https%3A%2F%2Fanalysis.windows.net%2Fpowerbi%2Fapi%2F.default"
$tr = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$($fresh.tenant)/oauth2/v2.0/token" -Method POST -Body $tb -ContentType "application/x-www-form-urlencoded" -SkipHttpErrorCheck
Write-Host "Token status: $($tr.StatusCode)"
if ($tr.StatusCode -eq 200) {
    $tok = ($tr.Content | ConvertFrom-Json).access_token
    Write-Host "Token acquired (len=$($tok.Length))" -ForegroundColor Green

    # Test embed token
    Write-Host "`n=== GenerateToken ===" -ForegroundColor Cyan
    $ph = @{Authorization="Bearer $tok"; "Content-Type"="application/json"}
    $gb = @{ reports=@(@{id="e833a03b-2cf9-42d2-a1ee-a40f847fd75d"}); datasets=@(@{id="b7bc94fc-a087-4e71-9476-f128ba57cf3a"}); targetWorkspaces=@(@{id="349db6f1-5df6-4992-ba67-ebc4449fead5"}) } | ConvertTo-Json -Depth 4
    $gr = Invoke-WebRequest -Uri "https://api.powerbi.com/v1.0/myorg/GenerateToken" -Method POST -Headers $ph -Body $gb -SkipHttpErrorCheck
    Write-Host "Embed status: $($gr.StatusCode)"
    if ($gr.StatusCode -eq 200) { $et = ($gr.Content | ConvertFrom-Json); Write-Host "Embed token : $($et.token.Substring(0,20))..." -ForegroundColor Green; Write-Host "Expiry      : $($et.expiration)" -ForegroundColor Green } else { Write-Host $gr.Content -ForegroundColor Red }

    # Write the working secret back to .env safely
    Write-Host "`nUpdating .env..." -ForegroundColor Cyan
    $envPath = "c:\Users\seankelley\OneDrive - Microsoft\Documents\VISA\PBI - Embedded\.env"
    $lines = Get-Content $envPath
    $newLines = $lines | ForEach-Object {
        if ($_ -match "^#?\s*CLIENT_ID=")     { "CLIENT_ID=$($fresh.appId)" }
        elseif ($_ -match "^#?\s*CLIENT_SECRET=") { "CLIENT_SECRET=$($fresh.password)" }
        else { $_ }
    }
    [System.IO.File]::WriteAllLines($envPath, $newLines, [System.Text.Encoding]::UTF8)
    Write-Host ".env updated"
} else {
    Write-Host $tr.Content -ForegroundColor Red
}
