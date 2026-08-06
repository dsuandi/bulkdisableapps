# Bulk Disable Entra App Registrations — Design

**Date:** 2026-08-06
**Status:** Approved for planning
**Repo:** `bulk-disable-apps`

## 1. Overview

A single-file PowerShell 7+ script (`Disable-EntraAppRegistrations.ps1`) that reads a CSV of Entra app registrations and disables sign-ins on each one after per-row operator consent. "Disable" means setting `accountEnabled = $false` on the corresponding service principal — a fully reversible action that matches the Entra portal's "disable" toggle. The app registration object itself is left intact.

Primary user: a cloud admin cleaning up expired app registrations. Auth is interactive Microsoft Graph delegated sign-in. A timestamped transcript file with a header (who/when/where) and footer (statistics) serves as the audit artifact.

### Out of scope (YAGNI)
- Deleting app registrations (soft or hard)
- Rotating credentials or removing secrets
- Batched/parallel Graph calls
- Non-interactive/CI usage beyond a `-Force` bypass switch
- Unit tests (verification is manual against a non-prod tenant)

## 2. Parameters

| Parameter | Type | Required | Purpose |
|---|---|---|---|
| `-CsvPath` | `string` | yes | Path to input CSV. |
| `-TenantId` | `string` | no | Passed to `Connect-MgGraph` for multi-tenant admins. |
| `-Force` | `switch` | no | Skip per-row consent prompts (still logs each action). |
| `-TranscriptPath` | `string` | no | Override default transcript path. |

Default transcript path: `./logs/disable-apps-<yyyyMMdd-HHmmss>.txt` (folder auto-created).

## 3. CSV contract

- Headers: **`AppId,DisplayName`** (case-insensitive via `Import-Csv`).
- `AppId` is the application (client) ID GUID and is the only value used for matching.
- `DisplayName` is shown to the operator for confirmation only; the actual display name from Graph is also shown so mismatches are visible.
- Rows with a blank or non-GUID `AppId` are logged as `SKIPPED (invalid)` and the run continues.
- A sample `sample-apps.csv` ships in the repo.

## 4. Authentication

- `Connect-MgGraph -Scopes 'Application.ReadWrite.All','Directory.ReadWrite.All' [-TenantId $TenantId]`.
- After connect, capture identity via `Get-MgContext`: `Account`, `TenantId`, granted `Scopes`, and client info — used in the transcript header.
- `Disconnect-MgGraph` runs in a `finally` block.
- Preflight: verify PS 7+ and that the `Microsoft.Graph.Applications` module is available; otherwise print a one-line install hint (`Install-Module Microsoft.Graph -Scope CurrentUser`) and exit with code 2.

## 5. Per-row flow

1. Validate `AppId` is a GUID; if not → log `SKIPPED (invalid)` and continue.
2. Look up service principal: `Get-MgServicePrincipal -Filter "appId eq '<guid>'"`.
   - No match → log `NOT FOUND` and continue.
3. If `accountEnabled` is already `false` → log `ALREADY DISABLED` and continue (idempotent).
4. Show a one-line summary (`AppId`, actual Graph `DisplayName`, CSV `DisplayName` if it differs) and prompt: `[Y]es / [N]o / [A]ll / [Q]uit`.
   - `-Force` skips the prompt and behaves like `A` (sticky "all").
5. On `Y` or `A`: call `Update-MgServicePrincipal -ServicePrincipalId <id> -AccountEnabled:$false`.
   - Success → log `DISABLED`.
   - Exception → log `FAILED: <error>` and continue to next row.
6. On `N`: log `SKIPPED (user)` and continue.
7. On `Q`: stop the loop; still write the footer and finalize the transcript.

## 6. Output and logging

### 6.1 Console
Colored one-line-per-row output:
- green — `DISABLED`
- yellow — `SKIPPED` / `ALREADY DISABLED`
- red — `NOT FOUND` / `FAILED`

### 6.2 Transcript header
Written at the top of the transcript and echoed to the console at start:

```
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

### 6.3 Transcript footer with statistics
Written at end of run to both transcript and console:

```
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
 Not found          :   1
 Failed             :   1
 Stopped early (Q)  : No
 -Force mode        : No

 Failed rows (see transcript above for details)
 ----------------------------------------------
 - 6d3a...  "Legacy Reporting App"  :  Insufficient privileges to complete the operation.
================================================================
```

### 6.4 Counter definitions
Each processed row lands in exactly one bucket.

| Counter | Increments when |
|---|---|
| `Disabled` | `Update-MgServicePrincipal` succeeded (accountEnabled true → false). |
| `Already disabled` | Service principal found but `accountEnabled` was already false. |
| `Skipped (user)` | Operator answered `N` at the consent prompt. |
| `Skipped (invalid)` | CSV row had a blank or non-GUID `AppId`. |
| `Not found` | No service principal matched the `appId`. |
| `Failed` | Graph call threw an exception during the disable attempt. |

Additional footer fields:
- `Stopped early (Q)` — `Yes` if the operator hit `Q` mid-run, otherwise `No`. When `Yes`, an extra line `Remaining (not processed): N` is added.
- `-Force mode` — `Yes`/`No`, reflects whether `-Force` was supplied.

**Invariant** (when not stopped early): `Total rows = Disabled + Already disabled + Skipped (user) + Skipped (invalid) + Not found + Failed`.

### 6.5 Exit codes
- `0` — run completed with zero `Failed` and zero `Not found`.
- `1` — run completed but had `Failed` and/or `Not found` rows.
- `2` — run aborted before the per-row loop started (bad `-CsvPath`, missing module, `Connect-MgGraph` failed).

Choosing `Q` mid-run does not affect the exit code — `0`/`1` still applies based on what was processed.

## 7. Script structure

Single file, small helper functions:

- `Assert-Prereqs` — checks PS version and `Microsoft.Graph.Applications` module.
- `Read-AppRows` — `Import-Csv` + row validation; yields normalized objects with a `Reason` for invalid rows.
- `Get-AppServicePrincipal` — wraps the `Get-MgServicePrincipal -Filter "appId eq '<guid>'"` call.
- `Invoke-DisableApp` — `Update-MgServicePrincipal` with try/catch, returns a status enum.
- `Read-Consent` — Y/N/A/Q prompt; honors `-Force` and the sticky "all" state.
- `Write-RunHeader` — formats and writes the header block to console and transcript.
- `Write-RunFooter` — accepts a `$Stats` hashtable, formats the summary block plus the failed-rows list, writes to console and transcript.
- `Main` — orchestrates: preflight → connect → transcript start → header → loop → footer → transcript stop → disconnect → exit code.

## 8. Error handling

- Any non-terminating error inside a row is caught, logged as `FAILED`, and the loop continues.
- Terminating errors only for: bad `-CsvPath`, connect failure, or missing module. Each prints a one-line remediation and exits with code 2.
- All uncaught exceptions are logged inside the transcript before exit.

## 9. Verification (manual)

Verified in a non-production tenant with a CSV containing these cases; each has an expected transcript line:

| Case | Expected outcome |
|---|---|
| Valid enabled app | `DISABLED`, counter increments |
| Already-disabled app | `ALREADY DISABLED`, no Graph write |
| Bogus / non-GUID `AppId` | `SKIPPED (invalid)`, no Graph read |
| Valid GUID with no matching SP | `NOT FOUND` |
| Valid app, operator answers `N` | `SKIPPED (user)` |
| Full run with `-Force` | All eligible apps disabled, no prompts |
| Operator hits `Q` mid-run | Loop stops, footer shows `Stopped early: Yes` and `Remaining: N` |
| Insufficient privileges on one row | `FAILED: <error>`; row appears in footer's `Failed rows` list |

## 10. Repo layout

```
bulk-disable-apps/
├── README.md                          (updated: usage, required scopes, examples)
├── Disable-EntraAppRegistrations.ps1
├── sample-apps.csv
├── docs/superpowers/specs/
│   └── 2026-08-06-bulk-disable-entra-apps-design.md
└── logs/                              (gitignored)
```
