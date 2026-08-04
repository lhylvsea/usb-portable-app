[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VendorDir,

    [Parameter(Mandatory = $true)]
    [string]$DataDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

$vendorRoot = Normalize-Path $VendorDir
$dataRoot = Normalize-Path $DataDir
if (-not (Test-Path -LiteralPath $vendorRoot -PathType Container)) {
    Write-Output "SKIP vendor directory not found: $vendorRoot"
    exit 0
}
if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    Write-Output "SKIP data directory not found: $dataRoot"
    exit 0
}

$archives = @{}
foreach ($zip in @(Get-ChildItem -LiteralPath $vendorRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue)) {
    $archives[$zip.BaseName] = $zip.FullName
}
if ($archives.Count -eq 0) {
    Write-Output "SKIP no vendor archives under: $vendorRoot"
    exit 0
}

$checked = 0
$healthy = 0
$repaired = 0
$unmatched = 0

foreach ($recordFile in @(Get-ChildItem -LiteralPath $dataRoot -Recurse -Force -File -Filter '.extracted' -ErrorAction SilentlyContinue)) {
    $matchedName = $null
    foreach ($name in ($archives.Keys | Sort-Object Length -Descending)) {
        $segment = [regex]::Escape(('\' + $name + '\'))
        if ($recordFile.FullName -match $segment) {
            $matchedName = $name
            break
        }
    }
    if ($null -eq $matchedName) {
        $unmatched++
        continue
    }

    $checked++
    $archiveHash = (Get-FileHash -LiteralPath $archives[$matchedName] -Algorithm SHA256).Hash.ToUpperInvariant()
    $recordHash = $null
    try {
        $json = Get-Content -LiteralPath $recordFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'archiveHash') {
            $recordHash = [string]$json.archiveHash
        }
    }
    catch {
        $recordHash = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($recordHash) -and
        [string]::Equals($recordHash, $archiveHash, [StringComparison]::OrdinalIgnoreCase)) {
        $healthy++
        continue
    }

    if ($PSCmdlet.ShouldProcess($recordFile.FullName, "Remove stale .extracted record for $matchedName")) {
        Remove-Item -LiteralPath $recordFile.FullName -Force
        $repaired++
        Write-Output "REPAIRED $matchedName $($recordFile.FullName)"
    }
}

Write-Output "CHECKED=$checked HEALTHY=$healthy REPAIRED=$repaired UNMATCHED=$unmatched"
