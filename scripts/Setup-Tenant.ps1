<#
.SYNOPSIS
    Setup orchestrator — provisions the VISA Commercial Spend Analytics demo stack
    (Fabric workspace + Lakehouse + semantic model + report + data agent, a Microsoft
    Entra service principal, and an Azure AI Foundry agent) into YOUR OWN tenant.
    Does not read or write anything in the original author's tenant.

.DESCRIPTION
    Run this after completing docs/prerequisites.md. The script:
      1. Confirms Azure CLI login context (tenant/subscription).
      2. Creates a new Fabric workspace and assigns it to your capacity.
      3. Walks you through connecting that workspace to this repo via Fabric Git
         Integration and syncing items (Lakehouse, semantic model, report, notebook,
         data agent). This one step requires a signed-in user with a registered Git
         credential — Fabric's git/connect and updateFromGit APIs are not callable by
         a service principal, so it cannot be scripted end-to-end (see
         docs/design_notes.md).
      4. Uploads the synthetic CSVs in data/ into the new Lakehouse's Files/ area.
      5. Runs Load_Delta_Tables.Notebook to populate the Delta tables.
      6. Registers a new Entra ID App Registration + Service Principal, grants it
         Power BI service permissions, and assigns it an Admin role on the new
         workspace.
      7. Re-points the synced Data Agent's semantic-model datasource at the new
         workspace/model IDs (the git-synced definition still references the
         original tables' logical shape but needs the live GUIDs).
      8. Creates an Azure AI Foundry agent in your existing Foundry project.
      9. Writes a working .env file with everything collected above.

    All tenant-specific configuration (Tenant ID, Subscription ID, workspace name,
    Fabric capacity ID, Foundry project endpoint/model) can be supplied as parameters
    or via -ConfigFile, so this script can be run non-interactively. Any value not
    supplied either way falls back to an interactive prompt.

.PARAMETER ConfigFile
    Path to a JSON file with keys: TenantId, SubscriptionId, WorkspaceName,
    CapacityId, FoundryProjectEndpoint, FoundryModelDeployment.
    See scripts/tenant.config.example.json for the expected shape.

.EXAMPLE
    ./scripts/Setup-Tenant.ps1 -ConfigFile ./scripts/tenant.config.json

.EXAMPLE
    ./scripts/Setup-Tenant.ps1 -TenantId <guid> -SubscriptionId <guid> `
        -WorkspaceName "VISA Demo" -CapacityId <guid> `
        -FoundryProjectEndpoint https://<resource>.services.ai.azure.com/api/projects/<project>

.NOTES
    Idempotent-ish: safe to re-run individual phases via -StartAt. Requires PowerShell 7+,
    Azure CLI (az), and the SqlServer module is NOT required by this script (only by
    scripts/export_source_csvs.ps1 / scripts/query_xmla.ps1).
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'Workspace', 'GitSync', 'DataLoad', 'ServicePrincipal', 'DataAgent', 'FoundryAgent', 'WriteEnv')]
    [string]$StartAt = 'All',

    [string]$ConfigFile,

    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$WorkspaceName,
    [string]$CapacityId,
    [string]$FoundryProjectEndpoint,
    [string]$FoundryModelDeployment,

    # Existing workspace ID to continue with when -StartAt is not 'All'/'Workspace'.
    [string]$ExistingWorkspaceId
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot '.env'

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host $msg -ForegroundColor Gray }
function Write-Ok($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }

function Get-FabricToken {
    (az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv)
}
function Get-PowerBiToken {
    (az account get-access-token --resource "https://analysis.windows.net/powerbi/api" --query accessToken -o tsv)
}
function Get-StorageToken {
    (az account get-access-token --resource "https://storage.azure.com" --query accessToken -o tsv)
}

function Get-ConfigValue {
    param([string]$CliValue, $ConfigObject, [string]$ConfigKey, [string]$Prompt, [string]$Default)
    if (-not [string]::IsNullOrWhiteSpace($CliValue)) { return $CliValue }
    if ($ConfigObject -and $ConfigObject.PSObject.Properties.Name -contains $ConfigKey -and -not [string]::IsNullOrWhiteSpace($ConfigObject.$ConfigKey)) {
        return $ConfigObject.$ConfigKey
    }
    $promptText = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $answer = Read-Host $promptText
    if ([string]::IsNullOrWhiteSpace($answer) -and $Default) { return $Default }
    return $answer
}

# ── Collect inputs ─────────────────────────────────────────────────────────────

Write-Step "VISA Commercial Spend Analytics — tenant setup"
Write-Info "This provisions a fresh copy of the demo into your own Microsoft Fabric / Azure tenant."
Write-Info "See docs/prerequisites.md before continuing.`n"

$config = $null
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) { throw "-ConfigFile '$ConfigFile' not found. See scripts/tenant.config.example.json." }
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Write-Info "Loaded config from $ConfigFile"
}

$TenantId = Get-ConfigValue -CliValue $TenantId -ConfigObject $config -ConfigKey 'TenantId' -Prompt "Microsoft Entra Tenant ID"
$SubscriptionId = Get-ConfigValue -CliValue $SubscriptionId -ConfigObject $config -ConfigKey 'SubscriptionId' -Prompt "Azure Subscription ID (used for the app registration / az calls)"
$WorkspaceName = Get-ConfigValue -CliValue $WorkspaceName -ConfigObject $config -ConfigKey 'WorkspaceName' -Prompt "New Fabric workspace name" -Default "VISA Commercial Spend Analytics"
$CapacityId = Get-ConfigValue -CliValue $CapacityId -ConfigObject $config -ConfigKey 'CapacityId' -Prompt "Fabric capacity ID to assign the new workspace to (GUID, from Fabric Admin Portal -> Capacity settings)"
$FoundryEndpoint = Get-ConfigValue -CliValue $FoundryProjectEndpoint -ConfigObject $config -ConfigKey 'FoundryProjectEndpoint' -Prompt "Existing Azure AI Foundry project endpoint (e.g. https://<resource>.services.ai.azure.com/api/projects/<project>)"
$FoundryModel = Get-ConfigValue -CliValue $FoundryModelDeployment -ConfigObject $config -ConfigKey 'FoundryModelDeployment' -Prompt "Deployed Foundry model name" -Default "gpt-5.1"

# ── Phase: az login / context ──────────────────────────────────────────────────

Write-Step "Azure CLI context"
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account -or $account.tenantId -ne $TenantId) {
    Write-Info "Logging in to tenant $TenantId..."
    az login --tenant $TenantId | Out-Null
}
az account set --subscription $SubscriptionId
Write-Ok "Signed in as $((az account show | ConvertFrom-Json).user.name) on subscription $SubscriptionId"

# ── Phase: Workspace ────────────────────────────────────────────────────────────

$WorkspaceId = $null
if ($StartAt -in 'All', 'Workspace') {
    Write-Step "Creating Fabric workspace '$WorkspaceName'"
    $fabricToken = Get-FabricToken
    $headers = @{ Authorization = "Bearer $fabricToken"; 'Content-Type' = 'application/json' }

    $body = @{ displayName = $WorkspaceName; capacityId = $CapacityId } | ConvertTo-Json
    $ws = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Method Post -Headers $headers -Body $body
    $WorkspaceId = $ws.id
    Write-Ok "Workspace created: $WorkspaceId"
}
else {
    $WorkspaceId = Get-ConfigValue -CliValue $ExistingWorkspaceId -ConfigObject $config -ConfigKey 'ExistingWorkspaceId' -Prompt "Existing Workspace ID to continue with"
}

# ── Phase: Git Integration (manual-assisted) ───────────────────────────────────

if ($StartAt -in 'All', 'GitSync') {
    Write-Step "Connect workspace to Git (manual step required)"
    Write-Warn2 "Fabric's git/connect and updateFromGit REST APIs require a user-delegated Git credential registered under 'My Git Credentials' in the Fabric portal. Service principals cannot call them, so this step is done via the portal:"
    Write-Host @"

  1. Open https://app.fabric.microsoft.com/groups/$WorkspaceId
  2. Settings (gear icon) -> Git integration -> Connect
  3. Provider: GitHub. Repo: this repository. Branch: the branch you are deploying from.
  4. Git folder: leave at repo root (this project keeps Fabric items at the root).
  5. Click Connect, then Source control -> Update all to sync
     Commercial_Spend_Analytics.Lakehouse, Commercial_Spend_Analytics.SemanticModel,
     Commercial_Spend_Analytics.Report, Load_Delta_Tables.Notebook, and
     Commercial_Spend_Agent.DataAgent into this workspace.

"@
    Read-Host "Press Enter once 'Update all' has finished and all 5 items show up in the workspace"
}

# ── Phase: Discover item IDs ────────────────────────────────────────────────────

Write-Step "Discovering synced item IDs"
$fabricToken = Get-FabricToken
$headers = @{ Authorization = "Bearer $fabricToken" }
$items = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items" -Headers $headers).value

$lakehouse = $items | Where-Object { $_.type -eq 'Lakehouse' } | Select-Object -First 1
$semanticModel = $items | Where-Object { $_.type -eq 'SemanticModel' } | Select-Object -First 1
$report = $items | Where-Object { $_.type -eq 'Report' } | Select-Object -First 1
$notebook = $items | Where-Object { $_.type -eq 'Notebook' } | Select-Object -First 1
$dataAgent = $items | Where-Object { $_.type -eq 'DataAgent' } | Select-Object -First 1

foreach ($pair in @(
        @{ Name = 'Lakehouse'; Item = $lakehouse },
        @{ Name = 'SemanticModel'; Item = $semanticModel },
        @{ Name = 'Report'; Item = $report },
        @{ Name = 'Notebook'; Item = $notebook },
        @{ Name = 'DataAgent'; Item = $dataAgent }
    )) {
    if (-not $pair.Item) { Write-Warn2 "$($pair.Name) not found in workspace yet — re-run 'Update all' in Fabric Source control and re-run this script with -StartAt DataLoad" }
    else { Write-Ok "$($pair.Name): $($pair.Item.id)" }
}

# ── Phase: Upload CSVs + load Delta tables ─────────────────────────────────────

if ($StartAt -in 'All', 'DataLoad' -and $lakehouse) {
    Write-Step "Uploading synthetic CSVs to Lakehouse Files/"
    $storageToken = Get-StorageToken
    $dfsHeaders = @{ Authorization = "Bearer $storageToken" }
    $csvFiles = Get-ChildItem (Join-Path $repoRoot 'data') -Filter '*.csv'

    foreach ($csv in $csvFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($csv.FullName)
        $baseUri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$($lakehouse.id)/Files/$($csv.Name)"

        Invoke-RestMethod -Uri "$baseUri?resource=file" -Method Put -Headers $dfsHeaders | Out-Null
        Invoke-RestMethod -Uri "$baseUri?action=append&position=0" -Method Patch -Headers $dfsHeaders -Body $bytes -ContentType 'application/octet-stream' | Out-Null
        Invoke-RestMethod -Uri "$baseUri?action=flush&position=$($bytes.Length)" -Method Patch -Headers $dfsHeaders | Out-Null
        Write-Ok "Uploaded $($csv.Name) ($([math]::Round($bytes.Length / 1KB, 1)) KB)"
    }

    if ($notebook) {
        Write-Step "Running Load_Delta_Tables.Notebook"
        $fabricToken = Get-FabricToken
        $headers = @{ Authorization = "Bearer $fabricToken"; 'Content-Type' = 'application/json' }
        $runUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$($notebook.id)/jobs/instances?jobType=RunNotebook"
        $resp = Invoke-WebRequest -Uri $runUri -Method Post -Headers $headers -Body '{}' -SkipHttpErrorCheck
        $location = $resp.Headers.Location
        Write-Info "Notebook job started. Polling for completion..."

        do {
            Start-Sleep -Seconds 10
            $job = Invoke-RestMethod -Uri $location -Headers $headers
            Write-Info "  status: $($job.status)"
        } while ($job.status -in 'NotStarted', 'InProgress')

        if ($job.status -eq 'Completed') { Write-Ok "Delta tables loaded" }
        else { Write-Warn2 "Notebook run ended with status '$($job.status)' — check the run in the Fabric portal before continuing" }
    }
}

# ── Phase: Service principal ────────────────────────────────────────────────────

$ClientId = $null; $ClientSecret = $null
if ($StartAt -in 'All', 'ServicePrincipal') {
    Write-Step "Creating Entra ID app registration + service principal"
    $app = az ad app create --display-name "$WorkspaceName-embed-sp" -o json | ConvertFrom-Json
    $ClientId = $app.appId
    az ad sp create --id $ClientId | Out-Null

    # Power BI Service API — Tenant.Read.All application permission (App-Owns-Data embed)
    az ad app permission add --id $ClientId `
        --api "00000009-0000-0000-c000-000000000000" `
        --api-permissions "7504609f-c495-4c64-8542-686125a5a36f=Role" | Out-Null
    az ad app permission admin-consent --id $ClientId | Out-Null

    $cred = az ad app credential reset --id $ClientId --display-name "embed-setup" --years 1 -o json | ConvertFrom-Json
    $ClientSecret = $cred.password
    Write-Ok "Service principal created: $ClientId"

    Write-Step "Granting workspace Admin role to service principal"
    $spObjectId = (az ad sp show --id $ClientId --query id -o tsv)
    $fabricToken = Get-FabricToken
    $headers = @{ Authorization = "Bearer $fabricToken"; 'Content-Type' = 'application/json' }
    $roleBody = @{ principal = @{ id = $spObjectId; type = 'ServicePrincipal' }; role = 'Admin' } | ConvertTo-Json
    Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/roleAssignments" -Method Post -Headers $headers -Body $roleBody | Out-Null
    Write-Ok "Service principal granted Admin on workspace"

    Write-Warn2 "Tenant setting 'Service principals can use Fabric APIs' must be enabled for this identity/security group in the Fabric Admin Portal — this cannot be set via API and must be confirmed by a Fabric/Power BI admin."
}

# ── Phase: Fix up Data Agent datasource ────────────────────────────────────────

if ($StartAt -in 'All', 'DataAgent' -and $dataAgent -and $semanticModel) {
    Write-Step "Re-pointing Data Agent datasource at the new workspace/semantic model"
    & (Join-Path $PSScriptRoot 'create_data_agent.ps1') `
        -WorkspaceId $WorkspaceId `
        -SemanticModelId $semanticModel.id `
        -AgentName $dataAgent.displayName `
        -ItemId $dataAgent.id
    Write-Ok "Data Agent datasource updated"
}

# ── Phase: Foundry agent ────────────────────────────────────────────────────────

$FoundryAgentId = $null
if ($StartAt -in 'All', 'FoundryAgent') {
    Write-Step "Creating Azure AI Foundry agent"
    $env:FOUNDRY_PROJECT_ENDPOINT = $FoundryEndpoint
    $env:FOUNDRY_MODEL_DEPLOYMENT = $FoundryModel
    Push-Location $repoRoot
    try {
        $out = node scripts/provision-foundry-agent.js 2>&1
        Write-Host $out
        $match = $out | Select-String 'FOUNDRY_AGENT_ID=(\S+)'
        if ($match) { $FoundryAgentId = $match.Matches[0].Groups[1].Value }
    }
    finally { Pop-Location }
}

# ── Phase: Write .env ────────────────────────────────────────────────────────────

if ($StartAt -in 'All', 'WriteEnv') {
    Write-Step "Writing .env"
    $lines = @(
        "TENANT_ID=$TenantId",
        "CLIENT_ID=$ClientId",
        "CLIENT_SECRET=$ClientSecret",
        "WORKSPACE_ID=$WorkspaceId",
        "REPORT_ID=$($report.id)",
        "DATASET_ID=$($semanticModel.id)",
        "LAKEHOUSE_ID=$($lakehouse.id)",
        "AGENT_ID=$($dataAgent.id)",
        "FOUNDRY_PROJECT_ENDPOINT=$FoundryEndpoint",
        "FOUNDRY_MODEL_DEPLOYMENT=$FoundryModel",
        "FOUNDRY_AGENT_ID=$FoundryAgentId",
        "PORT=3000"
    )
    Set-Content -Path $envPath -Value $lines -Encoding UTF8
    Write-Ok ".env written to $envPath"
}

Write-Step "Setup complete"
Write-Info "Remaining manual step (no supported API): open the semantic model in the Fabric portal and confirm its Direct Lake connection uses a fixed identity (not sign-in credentials) so the embed service principal can query it without per-user SSO."
Write-Info "Then run: npm install && npm start"
