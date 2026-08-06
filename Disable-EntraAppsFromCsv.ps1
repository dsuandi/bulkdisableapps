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
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
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
        $applicationGuid = [guid]$applicationId
    }
    catch {
        Write-Warning "Skipping applicationId '$applicationId' because it is not a valid GUID."
        return
    }

    if ([string]::IsNullOrWhiteSpace($applicationName)) {
        Write-Warning "CSV row for applicationId '$applicationId' has an empty applicationName."
    }

    $normalizedApplicationId = $applicationGuid.ToString()
    $servicePrincipals = @(Get-MgServicePrincipal -Filter "appId eq '$normalizedApplicationId'" -All)

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

$requiredColumns = @('applicationId', 'applicationName')
Add-Type -AssemblyName Microsoft.VisualBasic
$csvHeaderParser = $null

try {
    $csvHeaderParser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($CsvPath)
    $csvHeaderParser.HasFieldsEnclosedInQuotes = $true
    $csvHeaderParser.SetDelimiters(',')
    $rawColumns = $csvHeaderParser.ReadFields()
}
finally {
    if ($null -ne $csvHeaderParser) {
        $csvHeaderParser.Dispose()
    }
}

if ($null -eq $rawColumns -or $rawColumns.Count -eq 0) {
    throw 'CSV file must contain a header row.'
}

$actualColumns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$rawColumns | ForEach-Object { [void]$actualColumns.Add($_.Trim()) }

foreach ($requiredColumn in $requiredColumns) {
    if (-not $actualColumns.Contains($requiredColumn)) {
        throw "CSV file must contain a '$requiredColumn' column."
    }
}

$applications = Import-Csv -LiteralPath $CsvPath

foreach ($application in $applications) {
    Disable-EntraApplicationFromRow -Row $application
}
