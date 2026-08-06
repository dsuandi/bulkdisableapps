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

function Main {
    Assert-Prereqs
    Write-Host "Skeleton OK. CsvPath = $CsvPath"
}

try {
    Main
    exit 0
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 2
}
