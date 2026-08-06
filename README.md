# bulk-disable-apps

PowerShell 7+ script that reads a CSV of Entra ID app registrations and disables sign-ins on each (sets `accountEnabled = $false` on the corresponding service principal) after per-row operator consent.

> Status: implementation in progress. Full usage docs will be added at the end.

## Requirements

- PowerShell 7.0 or later
- Microsoft Graph PowerShell SDK: `Install-Module Microsoft.Graph -Scope CurrentUser`
- Delegated Graph scopes granted at sign-in: `Application.ReadWrite.All`, `Directory.ReadWrite.All`

## CSV format

Headers: `AppId,DisplayName`. Only `AppId` (the application/client ID GUID) is used for matching; `DisplayName` is shown to the operator for confirmation.

See [sample-apps.csv](sample-apps.csv).
