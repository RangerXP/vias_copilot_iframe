$envLines = Get-Content .env | Where-Object { $_ -match '^[A-Z_]+=' }
$envMap = @{}
foreach ($line in $envLines) { $k,$v = $line -split '=',2; $envMap[$k.Trim()] = $v.Trim() }
$tenantId = $envMap['TENANT_ID']; $clientId = $envMap['CLIENT_ID']; $clientSecret = $envMap['CLIENT_SECRET']
$workspaceId = $envMap['WORKSPACE_ID']; $datasetId = $envMap['DATASET_ID']

$tokenBody = @{ grant_type='client_credentials'; client_id=$clientId; client_secret=$clientSecret; scope='https://analysis.windows.net/powerbi/api/.default' }
$tokenResp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'
$pbiToken = $tokenResp.access_token
$headers = @{ Authorization = "Bearer $pbiToken"; 'Content-Type' = 'application/json' }

Write-Host "--- Triggering dataset refresh ---"
try {
    $refreshResp = Invoke-WebRequest -Method Post -Uri "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$datasetId/refreshes" -Headers $headers -Body '{}' -SkipHttpErrorCheck
    Write-Host "Status: $($refreshResp.StatusCode)"
} catch { Write-Host "FAILED: $($_.Exception.Message)" }

Start-Sleep -Seconds 5
Write-Host "--- Refresh history ---"
$refreshes = Invoke-RestMethod -Method Get -Uri "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$datasetId/refreshes?`$top=3" -Headers $headers
$refreshes.value | Select-Object status, startTime, endTime, serviceExceptionJson | Format-Table -AutoSize
