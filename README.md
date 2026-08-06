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
- **Transcript:** written to `./logs/disable-apps-<yyyyMMdd-HHmmss>.txt` by default. Starts with a run header (see below), one line per row, then a summary footer. `./logs/` is gitignored.

### Sample header

The transcript opens with an identity block describing who ran the script and against which tenant:

```text
================================================================
 Bulk Disable Entra App Registrations
================================================================
 Run started : 2026-08-06 14:32:11 +07:00
 Run by      : admin@contoso.onmicrosoft.com
 Tenant ID   : 11111111-2222-3333-4444-555555555555
 Host        : DSU-LAPTOP-01 / Linux (PowerShell 7.4.1)
 CSV input   : ./expired-apps.csv  (23 rows)
 Scopes      : Application.ReadWrite.All, Directory.ReadWrite.All
 -Force      : False
================================================================
```

Use this block as the audit record: **who** (`Run by`), **where** (`Tenant ID` + `Host`), **what input** (`CSV input`), and **which permissions** (`Scopes`). The final field shows whether the run used `-Force`.

### Sample footer

The run ends with a summary block. Each processed row lands in exactly one counter, so on a normal run:

`Total rows = Disabled + Already disabled + Skipped (user) + Skipped (invalid) + Skipped (protected) + Not found + Failed`

```text
================================================================
 Run Summary
================================================================
 Run by      : admin@contoso.onmicrosoft.com
 Tenant ID   : 11111111-2222-3333-4444-555555555555
 Run started : 2026-08-06 14:32:11 +07:00
 Run ended   : 2026-08-06 14:35:47 +07:00
 Duration    : 00:03:36
 CSV input   : ./expired-apps.csv
 Total rows  : 23

 Results
 -------
 Disabled           :  17
 Already disabled   :   2
 Skipped (user)     :   1
 Skipped (invalid)  :   1
 Skipped (protected):   1
 Not found          :   1
 Failed             :   0
 Stopped early (Q)  : No
 -Force mode        : No
================================================================
```

Meaning of each counter:

- **Disabled** — the script flipped `accountEnabled` from true to false.
- **Already disabled** — the SP was already disabled; no Graph write happened.
- **Skipped (user)** — the operator answered `N` at the consent prompt.
- **Skipped (invalid)** — the CSV row had a blank or non-GUID `AppId`.
- **Skipped (protected)** — the guardrail refused (see [Safety guardrails](#safety-guardrails)).
- **Not found** — no service principal in the tenant matched the `AppId`.
- **Failed** — the Graph update raised an error; the exception message is captured in the per-row transcript line and listed under a `Failed rows` sub-block at the bottom of the footer.

If the operator hit `Q` mid-run, `Stopped early (Q)` shows `Yes` and an extra `Remaining (not processed): N` line appears — the reconciliation invariant then adds `+ Remaining` on the right.

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

## Troubleshooting

### `pwsh: command not found`

PowerShell 7 is not installed. Install from <https://learn.microsoft.com/powershell/scripting/install/installing-powershell> for your OS, then verify with `pwsh -Version`.

### Windows: `File cannot be loaded because running scripts is disabled on this system`

The Windows execution policy is blocking the script. Set the policy for the current user:

```pwsh
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then re-run the script.

### Windows: script downloaded from GitHub is still blocked

Files downloaded from the internet get a "Mark of the Web" (MOTW) tag that Windows treats as untrusted, even after the execution policy is loosened. Clear it:

```pwsh
Unblock-File .\Disable-EntraAppRegistrations.ps1
```

Or in Explorer: right-click the file → Properties → check **Unblock** at the bottom → OK.

### Linux/macOS: `permission denied` when running as `./Disable-EntraAppRegistrations.ps1`

The file needs an execute bit if you want to invoke it directly:

```bash
chmod +x Disable-EntraAppRegistrations.ps1
```

Alternatively, always invoke through pwsh — no `chmod` needed:

```bash
pwsh -NoProfile -File ./Disable-EntraAppRegistrations.ps1 -CsvPath ./expired-apps.csv
```

### `Microsoft.Graph.Applications module not found`

The Graph SDK is missing. Install it once for your user:

```pwsh
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```

The install pulls in ~40 sub-modules and can take several minutes. If you're bandwidth-constrained, install only what the script actually uses:

```pwsh
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
```

### Sign-in browser doesn't open (SSH, headless, WSL)

`Connect-MgGraph` tries to open a browser for interactive sign-in. On headless hosts that fails silently or errors. Force device-code auth instead — set this environment variable **before** running the script:

```pwsh
$env:MG_USE_DEVICE_CODE = 'true'
```

The script will print a code and a URL; open that URL on any device (phone / laptop), enter the code, sign in with your admin account, and the script continues.

### `Insufficient privileges to complete the operation` on every row

Your account has the required Graph scopes granted at sign-in, but lacks the tenant-side role to modify service principals. Ensure your admin account has at least the **Application Administrator** role (or higher, such as **Cloud Application Administrator** or **Global Administrator**) in the target tenant.
