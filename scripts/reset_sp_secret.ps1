# Safe SP credential reset — writes secret to .env without regex corruption
# Uses string interpolation instead of -replace to avoid special char issues

$envPath = "c:\Users\seankelley\OneDrive - Microsoft\Documents\VISA\PBI - Embedded\.env"

Write-Host "Resetting SP credential..." -ForegroundColor Cyan
$s = az ad app credential reset --id "595278db-8070-426d-85b5-7933db47de2c" `
       --display-name "pbie-embed-2026" --years 1 -o json | ConvertFrom-Json

$clientId  = $s.appId
$clientSec = $s.password

# Build .env content line by line — no regex, no interpolation risk
$lines = Get-Content $envPath
$newLines = $lines | ForEach-Object {
    if ($_ -match "^#?\s*CLIENT_ID=") { "CLIENT_ID=$clientId" }
    elseif ($_ -match "^#?\s*CLIENT_SECRET=") { "CLIENT_SECRET=$clientSec" }
    else { $_ }
}
[System.IO.File]::WriteAllLines($envPath, $newLines, [System.Text.Encoding]::UTF8)

Write-Host "CLIENT_ID   : $clientId"
Write-Host "SECRET len  : $($clientSec.Length)"

# Quick verify round-trip read
$readBack = @{}
Get-Content $envPath | Where-Object { $_ -match "^CLIENT_" } | ForEach-Object {
    $p = $_ -split "=", 2; $readBack[$p[0]] = $p[1]
}
Write-Host "Readback CLIENT_ID     : $($readBack['CLIENT_ID'])"
Write-Host "Readback SECRET length : $($readBack['CLIENT_SECRET'].Length)"
Write-Host "Readback SECRET match  : $($readBack['CLIENT_SECRET'] -ceq $clientSec)"
