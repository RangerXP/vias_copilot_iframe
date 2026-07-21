# Add SP to Fabric workspace + attempt to enable PBI tenant setting
param(
    [string]$WorkspaceId = "349db6f1-5df6-4992-ba67-ebc4449fead5",
    [string]$SpObjectId  = "9ee7391e-9fac-4bc5-ac1b-79e083aa76bd",   # Enterprise App object ID
    [string]$SpAppId     = "595278db-8070-426d-85b5-7933db47de2c"    # Client ID
)

# --- 1. Try Fabric role assignment ---
Write-Host "`n=== Fabric roleAssignments ===" -ForegroundColor Cyan
$ft = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
$fh = @{Authorization="Bearer $ft"; "Content-Type"="application/json"}
$fbody = @{ principal = @{ id = $SpObjectId; type = "ServicePrincipal" }; role = "Admin" } | ConvertTo-Json -Depth 5
$fr = Invoke-WebRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/roleAssignments" -Method POST -Headers $fh -Body $fbody -SkipHttpErrorCheck
Write-Host "Status : $($fr.StatusCode)"
Write-Host "Body   : $($fr.Content)"

# --- 2. Try enabling SP tenant setting via PBI Admin API ---
Write-Host "`n=== PBI Admin: enable ServicePrincipalTenantSetting ===" -ForegroundColor Cyan
$pt = (az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv)
$ph = @{Authorization="Bearer $pt"; "Content-Type"="application/json"}
$sbody = @{
    tenantSettings = @(
        @{
            settingName = "ServicePrincipalsCanAccessPowerBIApis"
            enabled = $true
            canSpecifySecurityGroups = $false
        }
    )
} | ConvertTo-Json -Depth 5

$sr = Invoke-WebRequest -Uri "https://api.powerbi.com/v1.0/myorg/admin/tenantSettings" -Method PATCH -Headers $ph -Body $sbody -SkipHttpErrorCheck
Write-Host "Status : $($sr.StatusCode)"
Write-Host "Body   : $($sr.Content)"

# --- 3. Retry PBI workspace user add ---
Write-Host "`n=== PBI workspace user add (retry) ===" -ForegroundColor Cyan
Start-Sleep -Seconds 3
$ub = @{identifier=$SpAppId; groupUserAccessRight="Admin"; principalType="App"} | ConvertTo-Json
$ur = Invoke-WebRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/users" -Method POST -Headers $ph -Body $ub -SkipHttpErrorCheck
Write-Host "Status : $($ur.StatusCode)"
Write-Host "Body   : $($ur.Content)"
