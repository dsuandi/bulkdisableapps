# bulkdisableapps
Script to disable several apps registration in Entra with bulk

## Disable app registrations from CSV

`Disable-EntraAppsFromCsv.ps1` disables sign-in for the service principal that belongs to each Entra application registration listed in a CSV file.

### Prerequisites

- PowerShell 7 or Windows PowerShell 5.1
- Microsoft Graph PowerShell SDK:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

- Permission to update applications/service principals in Microsoft Entra ID. The script requests the `Application.ReadWrite.All` Microsoft Graph scope.

### CSV format

The input CSV must include these columns:

```csv
applicationId,applicationName
00000000-0000-0000-0000-000000000000,Example application
```

`applicationId` is used to find the service principal to disable. `applicationName` is included for readability in warnings and logs.

### Usage

Preview the changes first:

```powershell
./Disable-EntraAppsFromCsv.ps1 -CsvPath ./applications.csv -WhatIf
```

Disable the applications:

```powershell
./Disable-EntraAppsFromCsv.ps1 -CsvPath ./applications.csv
```

For a specific tenant:

```powershell
./Disable-EntraAppsFromCsv.ps1 -CsvPath ./applications.csv -TenantId <tenant-id>
```

If you are already connected to Microsoft Graph with the required permission, use `-SkipConnect`.
