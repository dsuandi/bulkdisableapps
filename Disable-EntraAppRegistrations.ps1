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

function Test-ProtectedSp {
    param([Parameter(Mandatory)] $ServicePrincipal)

    $microsoftTenantId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'

    if ($ServicePrincipal.ServicePrincipalType -eq 'ManagedIdentity') {
        return @{ Protected = $true; Reason = 'ManagedIdentity — disabling breaks the Azure resource that owns it' }
    }
    if ($ServicePrincipal.AppOwnerOrganizationId -eq $microsoftTenantId) {
        return @{ Protected = $true; Reason = 'Microsoft first-party SP' }
    }
    return @{ Protected = $false; Reason = $null }
}

function Read-Consent {
    param(
        [Parameter(Mandatory)][string] $AppId,
        [Parameter(Mandatory)][string] $GraphDisplayName,
        [Parameter()][string] $CsvDisplayName,
        [Parameter()][bool] $Force,
        [Parameter()][ref] $ApproveAll
    )

    if ($Force -or $ApproveAll.Value) { return 'YES' }

    $csvHint = ''
    if ($CsvDisplayName -and ($CsvDisplayName -ne $GraphDisplayName)) {
        $csvHint = " (CSV said: `"$CsvDisplayName`")"
    }
    Write-Host ""
    Write-Host ("About to disable  {0}  ""{1}""{2}" -f $AppId, $GraphDisplayName, $csvHint) -ForegroundColor Cyan

    while ($true) {
        $answer = (Read-Host "Disable this app? [Y]es / [N]o / [A]ll / [Q]uit").Trim().ToUpperInvariant()
        switch ($answer) {
            'Y'   { return 'YES' }
            'YES' { return 'YES' }
            'N'   { return 'NO' }
            'NO'  { return 'NO' }
            'A'   { $ApproveAll.Value = $true; return 'YES' }
            'ALL' { $ApproveAll.Value = $true; return 'YES' }
            'Q'   { return 'QUIT' }
            'QUIT'{ return 'QUIT' }
            default { Write-Host "Please answer Y, N, A, or Q." -ForegroundColor Yellow }
        }
    }
}

function Write-RunHeader {
    param([Parameter(Mandatory)][hashtable] $Info)

    $bar = '=' * 64
    $lines = @(
        $bar,
        ' Bulk Disable Entra App Registrations',
        $bar,
        (' Run started : {0}' -f $Info.StartedAt),
        (' Run by      : {0}' -f $Info.Account),
        (' Tenant ID   : {0}' -f $Info.TenantId),
        (' Host        : {0} / {1} (PowerShell {2})' -f $Info.HostName, $Info.OS, $Info.PSVersion),
        (' CSV input   : {0}  ({1} rows)' -f $Info.CsvPath, $Info.RowCount),
        (' Scopes      : {0}' -f ($Info.Scopes -join ', ')),
        (' -Force      : {0}' -f $Info.Force),
        $bar
    )
    $lines | ForEach-Object { Write-Host $_ }
}

function Write-RunFooter {
    param([Parameter(Mandatory)][hashtable] $Stats)

    $bar = '=' * 64
    Write-Host $bar
    Write-Host ' Run Summary'
    Write-Host $bar
    Write-Host (' Run by      : {0}' -f $Stats.Account)
    Write-Host (' Tenant ID   : {0}' -f $Stats.TenantId)
    Write-Host (' Run started : {0}' -f $Stats.StartedAt)
    Write-Host (' Run ended   : {0}' -f $Stats.EndedAt)
    Write-Host (' Duration    : {0}' -f $Stats.Duration)
    Write-Host (' CSV input   : {0}' -f $Stats.CsvPath)
    Write-Host (' Total rows  : {0}' -f $Stats.TotalRows)
    Write-Host ''
    Write-Host ' Results'
    Write-Host ' -------'
    Write-Host (' Disabled           : {0,3}' -f $Stats.Disabled)
    Write-Host (' Already disabled   : {0,3}' -f $Stats.AlreadyDisabled)
    Write-Host (' Skipped (user)     : {0,3}' -f $Stats.SkippedUser)
    Write-Host (' Skipped (invalid)  : {0,3}' -f $Stats.SkippedInvalid)
    Write-Host (' Skipped (protected): {0,3}' -f $Stats.SkippedProtected)
    Write-Host (' Not found          : {0,3}' -f $Stats.NotFound)
    Write-Host (' Failed             : {0,3}' -f $Stats.Failed)
    $stoppedText = if ($Stats.StoppedEarly) { 'Yes' } else { 'No' }
    Write-Host (' Stopped early (Q)  : {0}' -f $stoppedText)
    if ($Stats.StoppedEarly) {
        Write-Host (' Remaining (not processed) : {0}' -f $Stats.Remaining)
    }
    $forceText = if ($Stats.Force) { 'Yes' } else { 'No' }
    Write-Host (' -Force mode        : {0}' -f $forceText)

    if ($Stats.FailedRows -and $Stats.FailedRows.Count -gt 0) {
        Write-Host ''
        Write-Host ' Failed rows (see transcript above for details)'
        Write-Host ' ----------------------------------------------'
        foreach ($f in $Stats.FailedRows) {
            Write-Host (' - {0}  "{1}"  :  {2}' -f $f.AppId, $f.DisplayName, $f.Message)
        }
    }
    Write-Host $bar
}

function Main {
    Assert-Prereqs

    # --- 1. Read + validate CSV up front so we know row count for the header
    $rows = @(Read-AppRows -Path $CsvPath)

    # --- 2. Compute transcript path and start transcript
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (-not $TranscriptPath) {
        $logsDir = Join-Path -Path (Get-Location) -ChildPath 'logs'
        if (-not (Test-Path -LiteralPath $logsDir)) {
            New-Item -ItemType Directory -Path $logsDir | Out-Null
        }
        $TranscriptPath = Join-Path -Path $logsDir -ChildPath "disable-apps-$ts.txt"
    }
    Start-Transcript -Path $TranscriptPath -Append | Out-Null

    $startedAt = Get-Date
    $stats = @{
        Account = $null; TenantId = $null
        StartedAt = $startedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')
        EndedAt = $null; Duration = $null
        CsvPath = $CsvPath; TotalRows = $rows.Count
        Disabled = 0; AlreadyDisabled = 0
        SkippedUser = 0; SkippedInvalid = 0; SkippedProtected = 0
        NotFound = 0; Failed = 0
        StoppedEarly = $false; Remaining = 0
        Force = [bool]$Force
        FailedRows = @()
    }

    try {
        # --- 3. Connect to Graph
        $scopes = @('Application.ReadWrite.All','Directory.ReadWrite.All')
        $connectArgs = @{ Scopes = $scopes; NoWelcome = $true }
        if ($TenantId) { $connectArgs.TenantId = $TenantId }
        Connect-MgGraph @connectArgs | Out-Null

        $ctx = Get-MgContext
        $stats.Account  = $ctx.Account
        $stats.TenantId = $ctx.TenantId

        # --- 4. Emit header
        Write-RunHeader -Info @{
            StartedAt = $stats.StartedAt
            Account   = $stats.Account
            TenantId  = $stats.TenantId
            HostName  = [System.Environment]::MachineName
            OS        = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
            PSVersion = $PSVersionTable.PSVersion
            CsvPath   = $CsvPath
            RowCount  = $rows.Count
            Scopes    = $scopes
            Force     = [bool]$Force
        }

        # --- 5. Per-row loop
        $approveAll = $false
        $processed = 0
        foreach ($row in $rows) {
            $processed++

            if (-not $row.IsValid) {
                Write-Host ("SKIPPED (invalid)  {0}  ({1})" -f $row.AppId, $row.Reason) -ForegroundColor Yellow
                $stats.SkippedInvalid++
                continue
            }

            $sp = $null
            try { $sp = Get-AppServicePrincipal -AppId $row.AppId } catch { $sp = $null }
            if (-not $sp) {
                Write-Host ("NOT FOUND          {0}  ""{1}""" -f $row.AppId, $row.DisplayName) -ForegroundColor Red
                $stats.NotFound++
                continue
            }

            if ($sp.AccountEnabled -eq $false) {
                Write-Host ("ALREADY DISABLED   {0}  ""{1}""" -f $row.AppId, $sp.DisplayName) -ForegroundColor Yellow
                $stats.AlreadyDisabled++
                continue
            }

            $guard = Test-ProtectedSp -ServicePrincipal $sp
            if ($guard.Protected) {
                Write-Host ("SKIPPED (protected) {0}  ""{1}""  :  {2}" -f $row.AppId, $sp.DisplayName, $guard.Reason) -ForegroundColor Magenta
                $stats.SkippedProtected++
                continue
            }

            $consent = Read-Consent -AppId $row.AppId `
                                    -GraphDisplayName $sp.DisplayName `
                                    -CsvDisplayName $row.DisplayName `
                                    -Force:([bool]$Force) `
                                    -ApproveAll ([ref]$approveAll)

            if ($consent -eq 'QUIT') {
                $stats.StoppedEarly = $true
                $stats.Remaining = $rows.Count - ($processed - 1)
                Write-Host "Operator chose Q. Stopping." -ForegroundColor Yellow
                break
            }
            if ($consent -eq 'NO') {
                Write-Host ("SKIPPED (user)     {0}  ""{1}""" -f $row.AppId, $sp.DisplayName) -ForegroundColor Yellow
                $stats.SkippedUser++
                continue
            }

            $result = Invoke-DisableApp -ServicePrincipalId $sp.Id -DisplayName $sp.DisplayName
            if ($result.Status -eq 'DISABLED') {
                Write-Host ("DISABLED           {0}  ""{1}""" -f $row.AppId, $sp.DisplayName) -ForegroundColor Green
                $stats.Disabled++
            } else {
                Write-Host ("FAILED             {0}  ""{1}""  :  {2}" -f $row.AppId, $sp.DisplayName, $result.Message) -ForegroundColor Red
                $stats.Failed++
                $stats.FailedRows += @{ AppId = $row.AppId; DisplayName = $sp.DisplayName; Message = $result.Message }
            }
        }

        # --- 6. Footer + exit code
        $endedAt = Get-Date
        $stats.EndedAt  = $endedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')
        $stats.Duration = ($endedAt - $startedAt).ToString('hh\:mm\:ss')
        Write-RunFooter -Stats $stats

        if (($stats.Failed -gt 0) -or ($stats.NotFound -gt 0)) {
            $script:__ExitCode = 1
        } else {
            $script:__ExitCode = 0
        }
    }
    finally {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { Stop-Transcript | Out-Null } catch { }
    }
}

$script:__ExitCode = 2
try {
    Main
    exit $script:__ExitCode
}
catch {
    Write-Error $_ -ErrorAction Continue
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
    exit 2
}
