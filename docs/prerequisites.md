# Prerequisites — Deploying This Demo Into Your Own Tenant

This project is self-contained: the repo includes the full Fabric semantic
model (TMDL), report (PBIR), data agent definition, synthetic dataset
(`data/*.csv`), and a setup script that provisions everything into **your
own** Microsoft Fabric / Azure tenant. It does **not** point at, or require
access to, the original author's tenant, workspace, or credentials.

Before running the setup script, make sure you have the following already
in place in your tenant.

## 1. Microsoft Fabric

| Requirement | Notes |
|---|---|
| Fabric capacity (trial or paid) | F2+ or a Power BI Premium/Fabric trial capacity assigned to your tenant. The setup script creates a **new workspace** and assigns it to this capacity — it does not provision capacity itself. |
| Permission to create a Fabric workspace | Your account (or the identity running setup) needs rights to create a workspace and assign it to the capacity above. |
| Fabric Git integration enabled | Tenant admin setting "Users can synchronize workspace items with Git repositories" must be ON (Fabric Admin Portal → Tenant settings). |
| A Git credential (PAT or GitHub OAuth) you can register in "My Git Credentials" | Fabric's Git-sync REST endpoints (`git/connect`, `updateFromGit`) require a **user-delegated** credential — service principals cannot call them (see `docs/design_notes.md` for the underlying platform gap). Plan to complete the initial repo connect + "Update from Git" step as a signed-in user, not purely via script. |

## 2. Microsoft Entra ID

| Requirement | Notes |
|---|---|
| Rights to register an App Registration | The setup script creates a dedicated service principal (App-Owns-Data embed identity) in your tenant. Requires "Application Developer" role or higher. |
| Rights to grant the SP a Fabric workspace role | Needed so the SP can generate embed tokens and query the model (Admin/Member on the new workspace). |

## 3. Local tooling

| Requirement | Notes |
|---|---|
| Node.js 20+ | `node --version` |
| Azure CLI | `az --version`, and `az login` to an account in your target tenant |
| PowerShell 7+ | Setup script and Fabric REST calls are PowerShell-based |
| `SqlServer` PowerShell module | `Install-Module SqlServer -Scope CurrentUser` — required for `Invoke-ASCmd` (XMLA queries used by the RLS/entitlement query layer) |

## What the setup script will ask you for

- Microsoft Entra **Tenant ID**
- Azure **Subscription ID** (for the app registration / role assignment `az` calls)
- Target **region** (for any resources it does create)
- A **workspace name** for the new Fabric workspace
- Confirmation that Fabric Git integration is enabled and that you'll complete the one manual "Update from Git" click after the workspace is connected (this step has no service-principal-callable API — see `docs/design_notes.md`)

## Running setup

`scripts/Setup-Tenant.ps1` collects the values above either interactively, as
named parameters, or from a config file — so it can be run unattended once
you know the values for your tenant.

```powershell
# Interactive (prompts for anything not already supplied)
./scripts/Setup-Tenant.ps1

# Config file (copy scripts/tenant.config.example.json -> scripts/tenant.config.json and fill it in)
./scripts/Setup-Tenant.ps1 -ConfigFile ./scripts/tenant.config.json

# Named parameters
./scripts/Setup-Tenant.ps1 -TenantId <guid> -SubscriptionId <guid> `
    -WorkspaceName "VISA Demo" -CapacityId <guid>
```

`scripts/tenant.config.json` is gitignored (it contains your tenant/subscription
IDs) — only `scripts/tenant.config.example.json` is tracked in the repo.

## What it does NOT do

- Does not provision Fabric capacity or Key Vaults — bring your own.
- Does not reference the original author's tenant ID or workspace GUID in any generated output.
- Does not commit any secrets — the final `.env` is written locally and stays gitignored.
