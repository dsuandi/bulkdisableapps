# bulk-disable-apps

PowerShell 7+ script that reads a CSV of Entra ID app registrations and disables sign-ins on each — sets `accountEnabled = $false` on the corresponding service principal — after per-row operator consent. Fully reversible; the app registration object itself is left intact.

## Requirements

- PowerShell 7.0 or later (`pwsh -Version`)
- Microsoft Graph PowerShell SDK: `Install-Module Microsoft.Graph -Scope CurrentUser`
- Delegated Graph scopes granted at sign-in: `Application.ReadWrite.All`, `Directory.ReadWrite.All`
- An admin account that can consent to those scopes and modify the target service principals

## CSV format

Headers: `AppId,DisplayName` (case-insensitive). `AppId` is the application (client) ID GUID; `DisplayName` is shown to the operator for confirmation only.

See [sample-apps.csv](sample-apps.csv):

```csv
AppId,DisplayName
11111111-1111-1111-1111-111111111111,Contoso Expired Reporting App
22222222-2222-2222-2222-222222222222,Contoso Legacy Sync
```

Rows with a blank or non-GUID `AppId` are counted as `Skipped (invalid)` and the run continues.

## Usage

```pwsh
# Interactive per-row consent (recommended for first run)
./Disable-EntraAppRegistrations.ps1 -CsvPath ./expired-apps.csv

# Multi-tenant admin: specify tenant explicitly
./Disable-EntraAppRegistrations.ps1 -CsvPath ./expired-apps.csv -TenantId <tenant-guid>

# Skip prompts (auto-approve every row) — use with care
./Disable-EntraAppRegistrations.ps1 -CsvPath ./expired-apps.csv -Force

# Custom transcript location
./Disable-EntraAppRegistrations.ps1 -CsvPath ./expired-apps.csv -TranscriptPath ./audit/run-2026-08-06.txt
```

At the consent prompt, valid answers are `Y` (yes, this one), `N` (skip this one), `A` (yes to all remaining), `Q` (stop the run).

## Output

- **Console:** one colored line per row (`DISABLED` / `ALREADY DISABLED` / `SKIPPED` / `NOT FOUND` / `FAILED`).
- **Transcript:** written to `./logs/disable-apps-<yyyyMMdd-HHmmss>.txt` by default. Starts with an identity header (who ran it, tenant, host, CSV path, scopes) and ends with a summary footer listing counters and any failed rows. `./logs/` is gitignored.

## Safety guardrails

The script refuses to disable service principals in these categories, even under `-Force`:

- **Microsoft first-party SPs** (`AppOwnerOrganizationId = f8cdef31-a31e-4b4a-93e4-5f571e91255a`) — disabling these can break Entra itself, Microsoft Graph, or portal admin tools.
- **Managed identities** (`ServicePrincipalType = ManagedIdentity`) — disabling breaks the Azure resource (VM, Function App, App Service, etc.) that owns them.

Such rows appear in the console as `SKIPPED (protected)` and in the footer under `Skipped (protected)`. If you truly need to disable one of these, use the Entra portal or `Update-MgServicePrincipal` directly — there is no override flag on this script.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Run completed; zero `Failed` and zero `Not found` rows. |
| 1 | Run completed but had `Failed` and/or `Not found` rows. |
| 2 | Run aborted before per-row processing (bad CSV path, missing module, connect failed). |

Pressing `Q` mid-run follows the 0/1 rule based on what was already processed.

## What "disable" means

The script calls `Update-MgServicePrincipal -AccountEnabled:$false`. This is the same action as the "disable" toggle in the Entra portal for enterprise applications. It is **fully reversible** — re-enable via portal or `Update-MgServicePrincipal -AccountEnabled:$true`. It does **not** delete the app registration, rotate credentials, or remove secrets.
