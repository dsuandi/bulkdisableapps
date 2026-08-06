[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
            throw "CSV file was not found: $_"
        }
        return $true
    })]
    [string]$CsvPath,

    [string]$TenantId,

    [switch]$SkipConnect
)

$ErrorActionPreference = 'Stop'

function Assert-GraphCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw "Microsoft Graph PowerShell SDK command '$Name' is not available. Install it with: Install-Module Microsoft.Graph -Scope CurrentUser"
    }
}

function Disable-EntraApplicationFromRow {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row
    )

    $applicationId = [string]$Row.applicationId
    $applicationName = [string]$Row.applicationName

    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        Write-Warning "Skipping a row because applicationId is empty."
        return
    }

    try {
        [void][guid]$applicationId
    }
    catch {
        Write-Warning "Skipping applicationId '$applicationId' because it is not a valid GUID."
        return
    }

    if ([string]::IsNullOrWhiteSpace($applicationName)) {
        Write-Warning "CSV row for applicationId '$applicationId' has an empty applicationName."
    }

    $servicePrincipals = @(Get-MgServicePrincipal -Filter "appId eq '$applicationId'" -All)

    if ($servicePrincipals.Count -eq 0) {
        Write-Warning "No service principal was found for applicationId '$applicationId' ($applicationName)."
        return
    }

    foreach ($servicePrincipal in $servicePrincipals) {
        if ($servicePrincipal.AccountEnabled -eq $false) {
            Write-Host "Already disabled: $($servicePrincipal.DisplayName) [$applicationId]"
            continue
        }

        $target = "$($servicePrincipal.DisplayName) [$applicationId]"
        if ($PSCmdlet.ShouldProcess($target, 'Disable service principal sign-in')) {
            Update-MgServicePrincipal -ServicePrincipalId $servicePrincipal.Id -AccountEnabled:$false
            Write-Host "Disabled: $target"
        }
    }
}

Assert-GraphCommand -Name 'Connect-MgGraph'
Assert-GraphCommand -Name 'Get-MgServicePrincipal'
Assert-GraphCommand -Name 'Update-MgServicePrincipal'

if (-not $SkipConnect) {
    $connectParameters = @{
        Scopes = @('Application.ReadWrite.All')
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectParameters.TenantId = $TenantId
    }

    Connect-MgGraph @connectParameters | Out-Null
}

$applications = Import-Csv -LiteralPath $CsvPath
$requiredColumns = @('applicationId', 'applicationName')
$headerLine = Get-Content -LiteralPath $CsvPath -TotalCount 1

if ([string]::IsNullOrWhiteSpace($headerLine)) {
    throw 'CSV file must contain a header row.'
}

$actualColumns = @($headerLine.Split(',') | ForEach-Object { $_.Trim().Trim('"') })

foreach ($requiredColumn in $requiredColumns) {
    if ($actualColumns -notcontains $requiredColumn) {
        throw "CSV file must contain a '$requiredColumn' column."
    }
}

foreach ($application in $applications) {
    Disable-EntraApplicationFromRow -Row $application
}
