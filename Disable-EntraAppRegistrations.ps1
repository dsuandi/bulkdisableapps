#Requires -Version 7.0

<#
.SYNOPSIS
    Bulk-disables Entra app registrations listed in a CSV by flipping accountEnabled
    on each service principal, with per-row operator consent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $CsvPath,

    [Parameter()]
    [string] $TenantId,

    [Parameter()]
    [switch] $Force,

    [Parameter()]
    [string] $TranscriptPath
)

$ErrorActionPreference = 'Stop'

function Assert-Prereqs {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7 or later is required. Current: $($PSVersionTable.PSVersion)."
    }
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
        throw "Microsoft.Graph.Applications module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser"
    }
}

function Read-AppRows {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CSV file not found: $Path"
    }

    $guidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    Import-Csv -LiteralPath $Path | ForEach-Object {
        $appId = ($_.AppId ?? '').Trim()
        $name  = ($_.DisplayName ?? '').Trim()
        $valid = $appId -match $guidRegex

        [pscustomobject]@{
            AppId       = $appId
            DisplayName = $name
            IsValid     = $valid
            Reason      = if ($valid) { $null } elseif (-not $appId) { 'blank AppId' } else { 'AppId is not a GUID' }
        }
    }
}

function Get-AppServicePrincipal {
    param([Parameter(Mandatory)][string] $AppId)

    # Graph filter uses OData syntax; expect 0 or 1 result.
    Get-MgServicePrincipal -Filter "appId eq '$AppId'" -ConsistencyLevel eventual -CountVariable c -ErrorAction Stop |
        Select-Object -First 1
}

function Invoke-DisableApp {
    param(
        [Parameter(Mandatory)][string] $ServicePrincipalId,
        [Parameter(Mandatory)][string] $DisplayName
    )

    try {
        Update-MgServicePrincipal -ServicePrincipalId $ServicePrincipalId -AccountEnabled:$false -ErrorAction Stop
        return @{ Status = 'DISABLED'; Message = $null }
    }
    catch {
        return @{ Status = 'FAILED'; Message = $_.Exception.Message }
    }
}

function Main {
    Assert-Prereqs
    $rows = @(Read-AppRows -Path $CsvPath)
    Write-Host "Rows read: $($rows.Count)"
    foreach ($r in $rows) {
        if ($r.IsValid) {
            Write-Host ("  OK    {0}  ""{1}""" -f $r.AppId, $r.DisplayName)
        } else {
            Write-Host ("  BAD   {0}  ({1})" -f $r.AppId, $r.Reason) -ForegroundColor Yellow
        }
    }
}

try {
    Main
    exit 0
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 2
}
