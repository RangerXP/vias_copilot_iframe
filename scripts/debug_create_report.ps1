# Debug report creation - capture full HTTP response
$wsId    = "349db6f1-5df6-4992-ba67-ebc4449fead5"
$modelId = "b7bc94fc-a087-4e71-9476-f128ba57cf3a"
$token   = (az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

function b64([string]$s) { [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s)) }

$pbir = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json","version":"4.0","datasetReference":{"byConnection":{"connectionString":"semanticmodelid=' + $modelId + '"}}}'
$ver  = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/report/definition/versionMetadata/1.0.0/schema.json","version":"2.0.0"}'
$rpt  = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/3.1.0/schema.json","themeCollection":{"baseTheme":{"name":"CY25SU12","reportVersionAtImport":{"visual":"2.5.0","report":"3.1.0","page":"2.3.0"},"type":"SharedResources"}},"resourcePackages":[],"settings":{"useStylableVisualContainerHeader":true}}'
$pg   = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.0.0/schema.json","pageOrder":["a1b2c3d4e5f601234567"],"activePageName":"a1b2c3d4e5f601234567"}'
$p    = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.1.0/schema.json","name":"a1b2c3d4e5f601234567","displayName":"Overview","displayOption":"FitToPage","height":720,"width":1280}'

$parts = @(
    @{ path = "definition.pbir";                                        payload = b64 $pbir; payloadType = "InlineBase64" },
    @{ path = "definition/version.json";                                 payload = b64 $ver;  payloadType = "InlineBase64" },
    @{ path = "definition/report.json";                                  payload = b64 $rpt;  payloadType = "InlineBase64" },
    @{ path = "definition/pages/pages.json";                             payload = b64 $pg;   payloadType = "InlineBase64" },
    @{ path = "definition/pages/a1b2c3d4e5f601234567/page.json";         payload = b64 $p;    payloadType = "InlineBase64" }
)

$body = @{ displayName = "Commercial_Spend_Report"; type = "Report"; definition = @{ parts = $parts } } | ConvertTo-Json -Depth 10

Write-Host "Posting report creation..."
$resp = Invoke-WebRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/items" -Method POST -Headers $headers -Body $body -SkipHttpErrorCheck
Write-Host "Status       : $($resp.StatusCode) $($resp.StatusDescription)"
Write-Host "Location     : $($resp.Headers['Location'])"
Write-Host "Operation-Id : $($resp.Headers['x-ms-operation-id'])"
Write-Host "Retry-After  : $($resp.Headers['Retry-After'])"
Write-Host "Body         : $($resp.Content)"

# If 202, poll the operation to get the item ID
if ($resp.StatusCode -eq 202) {
    $opId = $resp.Headers['x-ms-operation-id']
    if ($opId) {
        Write-Host "`nPolling operation $opId..." -ForegroundColor Cyan
        Start-Sleep -Seconds 5
        $opToken = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
        $opHeaders = @{ Authorization = "Bearer $opToken" }
        $opResult = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/operations/$opId" -Headers $opHeaders
        Write-Host "Operation result:" -ForegroundColor Green
        $opResult | ConvertTo-Json -Depth 5
    }
}
