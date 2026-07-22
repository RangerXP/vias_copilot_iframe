<#
.SYNOPSIS
  Executes a DAX query against a Power BI semantic model via the XMLA endpoint.

.DESCRIPTION
  Part of the executeQueries -> XMLA migration (docs/design_notes.md Section 15).
  server/services/fabricAgent.js shells out to this script per query when
  USE_XMLA=true, instead of calling the Power BI executeQueries REST API.

  Auth: uses the existing service principal's client-credentials (ClientId/
  ClientSecret/TenantId) directly in the MSOLAP connection string via the
  documented "app:<ClientId>@<TenantId>" User ID syntax. Confirmed working
  2026-07-22 against the live Commercial_Spend_Analytics model — this is a
  DIFFERENT tenant permission than the one that blocked SP client-credentials
  for the executeQueries REST API (see project_plan.md Sprint 3 notes), so
  SPN auth is viable here even though it wasn't for executeQueries.

  RLS role activation: since this project's App-Owns-Data pattern uses synthetic
  usernames (not real Microsoft Entra ID accounts) for embed-token effectiveIdentity,
  we activate RLS roles the same way for XMLA queries — via the connection string
  "Roles" property (test-as-role), NOT "EffectiveUserName". EffectiveUserName
  requires the account to be a real Microsoft Entra ID identity with Read+Build
  permission on the model (see docs/design_notes.md Section 15), which synthetic
  demo/test usernames are not. The connecting SP is a workspace Admin, so it can
  activate any Roles value without needing role membership itself.

  Requires the SqlServer PowerShell module (Invoke-ASCmd):
    Install-Module SqlServer -Scope CurrentUser

.PARAMETER XmlaEndpoint
  Workspace XMLA endpoint, e.g. powerbi://api.powerbi.com/v1.0/myorg/<WorkspaceName>

.PARAMETER Database
  Dataset (semantic model) name (Initial Catalog) — the model display name, not its GUID.

.PARAMETER Query
  DAX query text (e.g. "EVALUATE ...").

.PARAMETER ClientId
  Service principal application (client) ID.

.PARAMETER ClientSecret
  Service principal client secret.

.PARAMETER TenantId
  Microsoft Entra tenant ID.

.PARAMETER Roles
  Optional comma-separated list of model role names to activate for this query
  (RLS enforcement) — e.g. "Role_RegionA".

.OUTPUTS
  JSON array of row objects, written to stdout.
#>
param(
    [Parameter(Mandatory = $true)][string]$XmlaEndpoint,
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Query,
    [Parameter(Mandatory = $true)][string]$ClientId,
    [Parameter(Mandatory = $true)][string]$ClientSecret,
    [Parameter(Mandatory = $true)][string]$TenantId,
    [string]$Roles
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Error "SqlServer PowerShell module not found. Install it with: Install-Module SqlServer -Scope CurrentUser"
    exit 1
}
Import-Module SqlServer -ErrorAction Stop

$connStringParts = @(
    'Provider=MSOLAP',
    "Data Source=$XmlaEndpoint",
    "Initial Catalog=$Database",
    "User ID=app:$ClientId@$TenantId",
    "Password=$ClientSecret",
    'Persist Security Info=True',
    'Impersonation Level=Impersonate'
)
if ($Roles) {
    $connStringParts += "Roles=$Roles"
}
$connectionString = ($connStringParts -join ';')

try {
    $rawXml = Invoke-ASCmd -ConnectionString $connectionString -Query $Query -QueryTimeout 60
}
catch {
    Write-Error "Invoke-ASCmd failed: $($_.Exception.Message)"
    exit 1
}

# --- Parse the XMLA rowset response into a plain JSON array ---
#
# The rowset schema embedded in the response maps generic per-row element names
# (C0, C1, ...) to the real DAX column names via the schema's sql:field
# attribute (e.g. <xsd:element sql:field="[Total Spend USD]" name="C0" .../>).
# Row data elements themselves are just <C0>value</C0>, so we must build this
# id -> real-name map from the schema before reading row data.
[xml]$doc = $rawXml
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('ra', 'urn:schemas-microsoft-com:xml-analysis:rowset')
$ns.AddNamespace('xsd', 'http://www.w3.org/2001/XMLSchema')

$colMap = @{}
$schemaElements = $doc.SelectNodes("//xsd:complexType[@name='row']/xsd:sequence/xsd:element", $ns)
foreach ($el in $schemaElements) {
    $genericName = $el.GetAttribute('name')
    $fieldAttr = $el.GetAttribute('field', 'urn:schemas-microsoft-com:xml-sql')
    if ($genericName -and $fieldAttr) {
        # sql:field looks like "[Table].[Column]" or just "[Column]" — take the
        # last bracketed segment as the friendly column name.
        $bracketMatches = [regex]::Matches($fieldAttr, '\[([^\]]+)\]')
        if ($bracketMatches.Count -gt 0) {
            $colMap[$genericName] = $bracketMatches[$bracketMatches.Count - 1].Groups[1].Value
        } else {
            $colMap[$genericName] = $fieldAttr
        }
    }
}

$rowNodes = $doc.SelectNodes('//ra:row', $ns)
if (-not $rowNodes -or $rowNodes.Count -eq 0) {
    # Fallback for responses that don't use the rowset namespace prefix on <row>.
    $rowNodes = $doc.GetElementsByTagName('row')
}

$results = @()
foreach ($row in $rowNodes) {
    $obj = [ordered]@{}
    foreach ($child in $row.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $key = $colMap[$child.LocalName]
        if (-not $key) { $key = $child.LocalName }
        $obj[$key] = $child.InnerText
    }
    $results += [pscustomobject]$obj
}

$results | ConvertTo-Json -Depth 5 -Compress

