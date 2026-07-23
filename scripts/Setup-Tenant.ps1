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
      8. If -FoundryProjectEndpoint was not supplied, creates a brand new Azure AI
         Foundry account + project + model deployment (named after -WorkspaceName)
         in -FoundryResourceGroup/-FoundryRegion. If it WAS supplied, that existing
         project is reused as-is.
      9. Creates an Azure AI Foundry agent in the Foundry project (new or existing).
     10. Writes a working .env file with everything collected above.

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
    [ValidateSet('All', 'Workspace', 'GitSync', 'DataLoad', 'ServicePrincipal', 'DataAgent', 'FoundryProject', 'FoundryAgent', 'WriteEnv')]
    [string]$StartAt = 'All',

    [string]$ConfigFile,

    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$WorkspaceName,
    [string]$CapacityId,
    [string]$FoundryProjectEndpoint,
    [string]$FoundryModelDeployment,

    # Used only when -FoundryProjectEndpoint is NOT supplied (i.e. no Foundry project
    # exists yet and this script should create one).
    [string]$FoundryResourceGroup,
    [string]$FoundryRegion = 'westus3',

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
    param([string]$CliValue, $ConfigObject, [string]$ConfigKey, [string]$Prompt, [string]$Default, [switch]$Optional)
    if (-not [string]::IsNullOrWhiteSpace($CliValue)) { return $CliValue }
    if ($ConfigObject -and $ConfigObject.PSObject.Properties.Name -contains $ConfigKey -and -not [string]::IsNullOrWhiteSpace($ConfigObject.$ConfigKey)) {
        return $ConfigObject.$ConfigKey
    }
    if ($Optional) { return $null }
    $promptText = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $answer = Read-Host $promptText
    if ([string]::IsNullOrWhiteSpace($answer) -and $Default) { return $Default }
    return $answer
}

function Get-Slug([string]$Name) {
    ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

# Ordered phase list used to make -StartAt resume from the named phase THROUGH the
# end of the script, not just run that one phase in isolation (a phase like DataLoad
# or ServicePrincipal must still run when resuming from an earlier phase like GitSync).
$script:PhaseOrder = @('Workspace', 'GitSync', 'DataLoad', 'ServicePrincipal', 'DataAgent', 'FoundryProject', 'FoundryAgent', 'WriteEnv')
function Test-ShouldRunPhase([string]$Phase) {
    if ($StartAt -eq 'All') { return $true }
    return $script:PhaseOrder.IndexOf($Phase) -ge $script:PhaseOrder.IndexOf($StartAt)
}

function Select-FromList {
    param(
        [Parameter(Mandatory)] [array]$Items,
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [scriptblock]$Label
    )
    Write-Host $Prompt
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), (& $Label $Items[$i]))
    }
    do {
        $choice = Read-Host "Select"
        $n = 0
        [void][int]::TryParse($choice, [ref]$n)
    } while (-not ($n -ge 1 -and $n -le $Items.Count))
    return $Items[$n - 1]
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

$WorkspaceName = Get-ConfigValue -CliValue $WorkspaceName -ConfigObject $config -ConfigKey 'WorkspaceName' -Prompt "New Fabric workspace name" -Default "VISA Commercial Spend Analytics"
$FoundryModel = Get-ConfigValue -CliValue $FoundryModelDeployment -ConfigObject $config -ConfigKey 'FoundryModelDeployment' -Prompt "Deployed (or to-be-deployed) Foundry model name" -Default "gpt-5.1"
$slug = Get-Slug $WorkspaceName

# ── Phase: az login + tenant/subscription selection ────────────────────────────
# Tenant/subscription are always confirmed against a live 'az account list', either by
# matching a supplied value or by presenting a picker — never trusted as a blind,
# unverified GUID, so a stale/mistyped value can't silently cause confusion later.

Write-Step "Azure sign-in"
$TenantId = Get-ConfigValue -CliValue $TenantId -ConfigObject $config -ConfigKey 'TenantId' -Optional
$SubscriptionId = Get-ConfigValue -CliValue $SubscriptionId -ConfigObject $config -ConfigKey 'SubscriptionId' -Optional

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Info "Not signed in to Azure CLI — signing in..."
    az login | Out-Null
}

$subs = az account list --all -o json | ConvertFrom-Json
if ($SubscriptionId) {
    $match = $subs | Where-Object { $_.id -eq $SubscriptionId } | Select-Object -First 1
    if (-not $match) { throw "Subscription '$SubscriptionId' was not found via 'az account list' for the signed-in account. Verify the ID and your access, or omit -SubscriptionId to pick from a list." }
    if ($TenantId -and $match.tenantId -ne $TenantId) { throw "Subscription '$SubscriptionId' belongs to tenant '$($match.tenantId)', not the supplied -TenantId '$TenantId'. Fix one or the other." }
    $TenantId = $match.tenantId
}
else {
    $picked = Select-FromList -Items $subs -Prompt "Which subscription should this be provisioned into?" -Label { param($s) "$($s.name)  (subscriptionId: $($s.id), tenantId: $($s.tenantId))" }
    $SubscriptionId = $picked.id
    $TenantId = $picked.tenantId
}

if ((az account show | ConvertFrom-Json).tenantId -ne $TenantId) {
    Write-Info "Switching sign-in to tenant $TenantId..."
    az login --tenant $TenantId | Out-Null
}
az account set --subscription $SubscriptionId
Write-Ok "Tenant:       $TenantId"
Write-Ok "Subscription: $SubscriptionId ($((az account show | ConvertFrom-Json).name))"

# ── Phase: Fabric capacity selection ────────────────────────────────────────────
# Same principle as above: a supplied CapacityId is validated (exists + Active) against
# 'GET /v1/capacities' rather than trusted blindly, and the picker shows state/region/sku
# so an inactive or wrong capacity can't be picked/typed by mistake.

Write-Step "Select Fabric capacity"
$CapacityId = Get-ConfigValue -CliValue $CapacityId -ConfigObject $config -ConfigKey 'CapacityId' -Optional
$fabricToken = Get-FabricToken
$capacities = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/capacities" -Headers @{ Authorization = "Bearer $fabricToken" }).value

if ($CapacityId) {
    $match = $capacities | Where-Object { $_.id -eq $CapacityId } | Select-Object -First 1
    if (-not $match) { throw "Capacity ID '$CapacityId' was not found via https://api.fabric.microsoft.com/v1/capacities for this account. Double-check the GUID in the Fabric Admin Portal -> Capacity settings, or omit -CapacityId to pick from a list." }
    if ($match.state -ne 'Active') { throw "Capacity '$($match.displayName)' ($CapacityId) is in state '$($match.state)', not Active. Resume/reactivate it (Fabric Admin Portal or Azure Portal), then re-run." }
    Write-Ok "Capacity: $($match.displayName) [$CapacityId] — $($match.sku), $($match.region), $($match.state)"
}
else {
    $active = @($capacities | Where-Object { $_.state -eq 'Active' })
    if ($active.Count -eq 0) { throw "No Active Fabric capacities were found for this account. Create/assign/resume one in the Fabric Admin Portal, or pass -CapacityId explicitly." }
    $picked = Select-FromList -Items $active -Prompt "Choose the Fabric capacity to assign the new workspace to:" -Label { param($c) "$($c.displayName)  ($($c.sku), $($c.region), $($c.state))  [id: $($c.id)]" }
    $CapacityId = $picked.id
    Write-Ok "Capacity: $($picked.displayName) [$CapacityId]"
}

# ── Phase: Foundry project selection ────────────────────────────────────────────
# Discovers existing Azure AI Foundry (Cognitive Services kind=AIServices) accounts +
# projects in the current subscription and lets the user pick one, or explicitly pick
# "create a new project" — instead of hand-typing/pre-filling an endpoint URL.

Write-Step "Select Azure AI Foundry project"
$FoundryEndpoint = Get-ConfigValue -CliValue $FoundryProjectEndpoint -ConfigObject $config -ConfigKey 'FoundryProjectEndpoint' -Optional
$FoundryResourceGroup = Get-ConfigValue -CliValue $FoundryResourceGroup -ConfigObject $config -ConfigKey 'FoundryResourceGroup' -Optional

if ($FoundryEndpoint) {
    Write-Ok "Using existing Foundry project endpoint: $FoundryEndpoint"
}
else {
    Write-Info "Looking for existing Azure AI Foundry accounts in subscription $SubscriptionId..."
    $accounts = @(az cognitiveservices account list --query "[?kind=='AIServices']" -o json 2>$null | ConvertFrom-Json)
    $foundryOptions = @()
    foreach ($acct in $accounts) {
        $projects = @(az resource list --resource-group $acct.resourceGroup --resource-type "Microsoft.CognitiveServices/accounts/projects" --query "[?starts_with(name, '$($acct.name)/')]" -o json 2>$null | ConvertFrom-Json)
        foreach ($proj in $projects) {
            $projName = $proj.name.Split('/')[-1]
            $foundryOptions += [pscustomobject]@{
                AccountName   = $acct.name
                ProjectName   = $projName
                ResourceGroup = $acct.resourceGroup
                Endpoint      = "https://$($acct.properties.customSubDomainName).services.ai.azure.com/api/projects/$projName"
            }
        }
    }
    $foundryOptions += [pscustomobject]@{ AccountName = '(create a NEW Foundry account + project)'; ProjectName = ''; ResourceGroup = ''; Endpoint = $null }

    $picked = Select-FromList -Items $foundryOptions -Prompt "Choose an Azure AI Foundry project to reuse, or create a new one:" -Label {
        param($f) if ($f.Endpoint) { "$($f.AccountName) / $($f.ProjectName)  (rg: $($f.ResourceGroup))" } else { $f.AccountName }
    }

    if ($picked.Endpoint) {
        $FoundryEndpoint = $picked.Endpoint
        Write-Ok "Reusing Foundry project: $FoundryEndpoint"
    }
    else {
        if (-not $FoundryResourceGroup) { $FoundryResourceGroup = "$slug-foundry-rg" }
        Write-Info "A new Foundry account/project will be created in resource group '$FoundryResourceGroup' ($FoundryRegion)."
    }
}

# ── Phase: Workspace ────────────────────────────────────────────────────────────

$WorkspaceId = $null
if (Test-ShouldRunPhase 'Workspace') {
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

if (Test-ShouldRunPhase 'GitSync') {
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

if ((Test-ShouldRunPhase 'DataLoad') -and $lakehouse) {
    Write-Step "Uploading synthetic CSVs to Lakehouse Files/"
    $storageToken = Get-StorageToken
    $dfsHeaders = @{ Authorization = "Bearer $storageToken" }
    $csvFiles = Get-ChildItem (Join-Path $repoRoot 'data') -Filter '*.csv'

    foreach ($csv in $csvFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($csv.FullName)
        $baseUri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$($lakehouse.id)/Files/$($csv.Name)"

        Invoke-RestMethod -Uri "${baseUri}?resource=file" -Method Put -Headers $dfsHeaders | Out-Null
        Invoke-RestMethod -Uri "${baseUri}?action=append&position=0" -Method Patch -Headers $dfsHeaders -Body $bytes -ContentType 'application/octet-stream' | Out-Null
        Invoke-RestMethod -Uri "${baseUri}?action=flush&position=$($bytes.Length)" -Method Patch -Headers $dfsHeaders | Out-Null
        Write-Ok "Uploaded $($csv.Name) ($([math]::Round($bytes.Length / 1KB, 1)) KB)"
    }

    if ($notebook) {
        # Fabric Git sync does NOT rebind a notebook's "default lakehouse" metadata to the
        # new workspace/lakehouse — the git-synced copy still points at the ORIGINAL template
        # workspace/lakehouse GUIDs. Running it as-is fails fast with
        # 'System_Cancelled_Session_Statements_Failed' because Spark can't attach to a
        # lakehouse in a different (usually inaccessible) workspace. Rebind it first.
        Write-Step "Re-binding notebook's default Lakehouse to this workspace"
        $fabricToken = Get-FabricToken
        $headers = @{ Authorization = "Bearer $fabricToken"; 'Content-Type' = 'application/json' }

        $getDefUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$($notebook.id)/getDefinition"
        $getResp = Invoke-WebRequest -Uri $getDefUri -Method Post -Headers $headers -Body '{}' -SkipHttpErrorCheck
        if ($getResp.StatusCode -eq 202) {
            $opLoc = $getResp.Headers.Location
            if ($opLoc -is [array]) { $opLoc = $opLoc[0] }
            do {
                Start-Sleep -Seconds 3
                $op = Invoke-RestMethod -Uri $opLoc -Headers $headers
            } while ($op.status -in 'Running', 'NotStarted')
            $definition = (Invoke-RestMethod -Uri "$opLoc/result" -Headers $headers).definition
        } else {
            $definition = ($getResp.Content | ConvertFrom-Json).definition
        }

        $rebound = $false
        foreach ($part in $definition.parts) {
            if ($part.path -like '*notebook-content*') {
                $bytes = [System.Convert]::FromBase64String($part.payload)
                $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                $text = $text -replace '"default_lakehouse":\s*"[0-9a-fA-F-]+"', "`"default_lakehouse`": `"$($lakehouse.id)`""
                $text = $text -replace '"default_lakehouse_name":\s*"[^"]*"', "`"default_lakehouse_name`": `"$($lakehouse.displayName)`""
                $text = $text -replace '"default_lakehouse_workspace_id":\s*"[0-9a-fA-F-]+"', "`"default_lakehouse_workspace_id`": `"$WorkspaceId`""
                $newBytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                $part.payload = [System.Convert]::ToBase64String($newBytes)
                $rebound = $true
            }
        }

        if ($rebound) {
            $updateUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$($notebook.id)/updateDefinition"
            $updateBody = @{ definition = $definition } | ConvertTo-Json -Depth 20
            $updResp = Invoke-WebRequest -Uri $updateUri -Method Post -Headers $headers -Body $updateBody -SkipHttpErrorCheck
            if ($updResp.StatusCode -eq 202) {
                $opLoc2 = $updResp.Headers.Location
                if ($opLoc2 -is [array]) { $opLoc2 = $opLoc2[0] }
                do {
                    Start-Sleep -Seconds 3
                    $op2 = Invoke-RestMethod -Uri $opLoc2 -Headers $headers
                } while ($op2.status -in 'Running', 'NotStarted')
            }
            Write-Ok "Notebook default Lakehouse re-bound to this workspace"
        } else {
            Write-Warn2 "Could not find notebook-content part to re-bind default Lakehouse — notebook run may fail"
        }

        Write-Step "Running Load_Delta_Tables.Notebook"
        $runUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$($notebook.id)/jobs/instances?jobType=RunNotebook"
        $resp = Invoke-WebRequest -Uri $runUri -Method Post -Headers $headers -Body '{}' -SkipHttpErrorCheck
        $location = $resp.Headers.Location
        if ($location -is [array]) { $location = $location[0] }
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
if (Test-ShouldRunPhase 'ServicePrincipal') {
    Write-Step "Creating Entra ID app registration + service principal"
    $app = az ad app create --display-name "$WorkspaceName-embed-sp" -o json | ConvertFrom-Json
    $ClientId = $app.appId
    az ad sp create --id $ClientId | Out-Null

    # Power BI Service API — Tenant.Read.All application permission (App-Owns-Data embed).
    # The app role ID is resolved live (not hardcoded) since it is a tenant-specific GUID —
    # a stale/wrong hardcoded value fails admin-consent with an "Entitlement ... can not be
    # found on resourceApp" error that looks unrelated to the real cause.
    $pbiServiceAppId = "00000009-0000-0000-c000-000000000000"
    $tenantReadAllRoleId = az ad sp show --id $pbiServiceAppId --query "appRoles[?value=='Tenant.Read.All'].id | [0]" -o tsv
    if ([string]::IsNullOrWhiteSpace($tenantReadAllRoleId)) { throw "Could not resolve the 'Tenant.Read.All' app role on the Power BI Service principal ($pbiServiceAppId) in this tenant." }
    az ad app permission add --id $ClientId `
        --api $pbiServiceAppId `
        --api-permissions "$tenantReadAllRoleId=Role" | Out-Null

    # Admin consent requires the signed-in user to be a Global Admin / Privileged Role Admin
    # in this tenant. This is an environment/permission limitation, not a script bug — if it
    # fails, keep going (the SP and workspace role assignment still succeed) but warn loudly,
    # since the embed app won't be able to call tenant-admin-scoped Power BI APIs until a
    # tenant admin grants consent manually (Entra portal > App registrations > API permissions
    # > Grant admin consent, or `az ad app permission admin-consent --id $ClientId` run by an admin).
    az ad app permission admin-consent --id $ClientId 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "Admin consent for Tenant.Read.All could not be granted automatically — this account is not a tenant admin. Ask a Global Admin/Privileged Role Admin to run: az ad app permission admin-consent --id $ClientId (or grant it in the Entra portal), otherwise the embed service principal may not be able to call tenant-scoped Power BI APIs."
    }

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

if ((Test-ShouldRunPhase 'DataAgent') -and $dataAgent -and $semanticModel) {
    Write-Step "Re-pointing Data Agent datasource at the new workspace/semantic model"
    & (Join-Path $PSScriptRoot 'create_data_agent.ps1') `
        -WorkspaceId $WorkspaceId `
        -SemanticModelId $semanticModel.id `
        -AgentName $dataAgent.displayName `
        -ItemId $dataAgent.id
    Write-Ok "Data Agent datasource updated"
}

# ── Phase: Foundry project (only when no existing endpoint was supplied) ──────

if ((Test-ShouldRunPhase 'FoundryProject') -and [string]::IsNullOrWhiteSpace($FoundryEndpoint)) {
    Write-Step "Creating Azure AI Foundry account + project '$slug'"
    az account set --subscription $SubscriptionId
    az group create --name $FoundryResourceGroup --location $FoundryRegion | Out-Null

    # The Microsoft.CognitiveServices resource provider isn't registered by default on every
    # subscription (e.g. fresh/test subscriptions) — account/project creation fails with
    # (MissingSubscriptionRegistration) if it isn't. Register it proactively and wait.
    $rpState = az provider show --namespace Microsoft.CognitiveServices --query registrationState -o tsv
    if ($rpState -ne 'Registered') {
        Write-Warn2 "Resource provider 'Microsoft.CognitiveServices' is not registered on this subscription (state: $rpState) — registering now (can take up to a minute)..."
        az provider register --namespace Microsoft.CognitiveServices | Out-Null
        do {
            Start-Sleep -Seconds 5
            $rpState = az provider show --namespace Microsoft.CognitiveServices --query registrationState -o tsv
        } while ($rpState -ne 'Registered')
        Write-Ok "Resource provider 'Microsoft.CognitiveServices' registered"
    }

    $accountName = "$slug-ai"
    $projectName = $slug
    $apiVersion = "2026-05-15-preview"

    $accountBody = @{
        location = $FoundryRegion
        kind     = "AIServices"
        sku      = @{ name = "S0" }
        identity = @{ type = "SystemAssigned" }
        properties = @{
            customSubDomainName    = $accountName
            allowProjectManagement = $true
            publicNetworkAccess    = "Enabled"
        }
    } | ConvertTo-Json -Depth 10 -Compress

    # az CLI on Windows/PowerShell mangles multi-line/quoted JSON passed inline as an argument
    # ("ERROR: Error parsing JSON... Expecting property name enclosed in double quotes"),
    # which silently fails resource creation without stopping the script. Writing the JSON to
    # a temp file and passing it via --properties @file avoids this shell-quoting corruption.
    $accountJsonFile = Join-Path ([System.IO.Path]::GetTempPath()) "foundry-account-$([guid]::NewGuid()).json"
    Set-Content -Path $accountJsonFile -Value $accountBody -NoNewline -Encoding utf8
    try {
        az resource create `
            --resource-group $FoundryResourceGroup `
            --name $accountName `
            --resource-type "Microsoft.CognitiveServices/accounts" `
            --api-version $apiVersion `
            --is-full-object `
            --properties "@$accountJsonFile" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "az resource create (account) exited with code $LASTEXITCODE" }
    }
    finally {
        Remove-Item $accountJsonFile -ErrorAction SilentlyContinue
    }
    Write-Ok "Foundry account created: $accountName"

    # NOTE on two az CLI/ARM quirks discovered live, both required for this to succeed:
    #  1. Passing a slash-joined --name (e.g. "$accountName/$projectName") together with a
    #     multi-segment --resource-type builds a malformed request URL (double slash, and the
    #     name gets URL-encoded as a single "%2F"-joined segment instead of two path segments),
    #     causing ARM to reject it with (InvalidResourceTypeNameFormat). Fix: use the older
    #     --namespace/--parent/--resource-type/--name syntax instead, which builds the URL
    #     correctly.
    #  2. The project sub-resource needs its OWN "identity": { "type": "SystemAssigned" } block
    #     in its request body — having identity only on the parent account is not enough. Omitting
    #     it fails with (BadRequest) "Unsupported configuration. To create projects, you must
    #     enable a managed identity on your resource." even though the account clearly already
    #     has a managed identity.
    $projectBody = @{ location = $FoundryRegion; identity = @{ type = "SystemAssigned" }; properties = @{} } | ConvertTo-Json -Depth 10 -Compress
    $projectJsonFile = Join-Path ([System.IO.Path]::GetTempPath()) "foundry-project-$([guid]::NewGuid()).json"
    Set-Content -Path $projectJsonFile -Value $projectBody -NoNewline -Encoding utf8
    try {
        az resource create `
            --resource-group $FoundryResourceGroup `
            --namespace Microsoft.CognitiveServices `
            --parent "accounts/$accountName" `
            --resource-type "projects" `
            --name $projectName `
            --api-version $apiVersion `
            --is-full-object `
            --properties "@$projectJsonFile" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "az resource create (project) exited with code $LASTEXITCODE" }
    }
    finally {
        Remove-Item $projectJsonFile -ErrorAction SilentlyContinue
    }
    Write-Ok "Foundry project created: $projectName"

    $FoundryEndpoint = "https://$accountName.services.ai.azure.com/api/projects/$projectName"

    # Creating the account/project only grants ARM control-plane access — calling the Foundry
    # data-plane API (e.g. creating agents) additionally requires a data-plane RBAC role.
    # Without it, agent creation fails with (403) "lacks the required data action
    # Microsoft.CognitiveServices/accounts/AIServices/agents/write". Grant the signed-in user
    # the built-in 'Foundry User' role (covers Microsoft.CognitiveServices/* data actions) on
    # the project, since that's the identity provision-foundry-agent.js will run as.
    try {
        $signedInUserId = az ad signed-in-user show --query id -o tsv
        $projectResourceId = az resource show `
            --resource-group $FoundryResourceGroup `
            --namespace Microsoft.CognitiveServices `
            --parent "accounts/$accountName" `
            --resource-type "projects" `
            --name $projectName `
            --api-version $apiVersion `
            --query id -o tsv
        az role assignment create --assignee-object-id $signedInUserId --assignee-principal-type User --role "Foundry User" --scope $projectResourceId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "az role assignment create exited with code $LASTEXITCODE" }
        Write-Ok "Granted 'Foundry User' role to signed-in user on the project (RBAC can take ~30-60s to propagate)"
    }
    catch {
        Write-Warn2 "Could not grant the 'Foundry User' data-plane role automatically — you (or a tenant admin) may need to assign it manually in the Foundry project's Access control (IAM) blade before agent creation will succeed."
    }

    try {
        # The model version is tenant/region/catalog-specific and changes over time (e.g. gpt-5.1
        # is version "2025-11-13", not "1") — hardcoding a version fails with
        # (DeploymentModelNotSupported). Resolve the current default version live instead.
        $modelInfo = az cognitiveservices account list-models `
            --name $accountName `
            --resource-group $FoundryResourceGroup `
            --query "[?name=='$FoundryModel'] | [0]" -o json | ConvertFrom-Json
        if (-not $modelInfo) { throw "Model '$FoundryModel' was not found in this account's model catalog (region: $FoundryRegion)." }
        $modelVersion = $modelInfo.version
        $sku = if ($modelInfo.skus.name -contains 'GlobalStandard') { 'GlobalStandard' } else { $modelInfo.skus[0].name }

        az cognitiveservices account deployment create `
            --name $accountName `
            --resource-group $FoundryResourceGroup `
            --deployment-name $FoundryModel `
            --model-name $FoundryModel `
            --model-version $modelVersion `
            --model-format OpenAI `
            --sku-name $sku `
            --sku-capacity 1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "az cognitiveservices account deployment create exited with code $LASTEXITCODE" }
        Write-Ok "Model '$FoundryModel' (v$modelVersion, sku $sku) deployed"
    }
    catch {
        Write-Warn2 "Automatic model deployment for '$FoundryModel' failed (model/version/quota may need to be picked manually). Deploy it in the Foundry portal for account '$accountName', then re-run: ./scripts/Setup-Tenant.ps1 -StartAt FoundryAgent -FoundryProjectEndpoint $FoundryEndpoint -FoundryModelDeployment $FoundryModel [other params]"
    }
}

# ── Phase: Foundry agent ────────────────────────────────────────────────────────

$FoundryAgentId = $null
if (Test-ShouldRunPhase 'FoundryAgent') {
    Write-Step "Creating Azure AI Foundry agent"
    $env:FOUNDRY_PROJECT_ENDPOINT = $FoundryEndpoint
    $env:FOUNDRY_MODEL_DEPLOYMENT = $FoundryModel
    Push-Location $repoRoot
    try {
        # Data-plane RBAC (e.g. the 'Foundry User' role granted above) can take several minutes
        # to actually take effect for Cognitive Services data-plane calls — much longer than
        # typical ARM control-plane propagation. Retry with backoff instead of failing once.
        $maxAttempts = 6
        $delaySeconds = 30
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $out = node scripts/provision-foundry-agent.js 2>&1
            Write-Host $out
            $match = $out | Select-String 'FOUNDRY_AGENT_ID=(\S+)'
            if ($match) {
                $FoundryAgentId = $match.Matches[0].Groups[1].Value
                Write-Ok "Foundry agent created: $FoundryAgentId"
                break
            }
            $isPermissionError = $out -match 'does not have access|lacks the required data action|Authorization'
            if ($attempt -lt $maxAttempts -and $isPermissionError) {
                Write-Warn2 "Agent creation failed (attempt $attempt/$maxAttempts) — likely RBAC propagation delay. Retrying in ${delaySeconds}s..."
                Start-Sleep -Seconds $delaySeconds
                $delaySeconds = [Math]::Min($delaySeconds * 2, 120)
            }
            else {
                Write-Warn2 "Could not determine a Foundry agent ID from provision-foundry-agent.js output after $attempt attempt(s) — the Foundry project/model deployment or RBAC role may not be ready yet. Re-run: ./scripts/Setup-Tenant.ps1 -StartAt FoundryAgent -FoundryProjectEndpoint $FoundryEndpoint -FoundryModelDeployment $FoundryModel [other params]"
                break
            }
        }
    }
    finally { Pop-Location }
}

# ── Phase: Write .env ────────────────────────────────────────────────────────────

if (Test-ShouldRunPhase 'WriteEnv') {
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
