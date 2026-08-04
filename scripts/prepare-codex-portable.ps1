[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PortableRoot,

    [ValidateSet('Launch', 'InitialMigration', 'Verify')]
    [string]$Mode = 'Launch',

    [string]$SourceProfile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Write-PortableLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $script:LogPath -Value "$timestamp $Message" -Encoding UTF8
}

function Get-OperationalTextFiles {
    param([string]$Profile, [string]$CodexHome)

    $extensions = @(
        '.md', '.txt', '.toml', '.json', '.jsonl', '.yaml', '.yml',
        '.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.ini', '.conf',
        '.js', '.mjs', '.cjs', '.ts', '.tsx', '.py', '.sh', '.xml', '.env'
    )

    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'

    if (Test-Path -LiteralPath $CodexHome) {
        Get-ChildItem -LiteralPath $CodexHome -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -le 20MB -and ($extensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -eq '.env') } |
            ForEach-Object { $files.Add($_) }
    }

    $roots = @(
        (Join-Path $CodexHome 'skills'),
        (Join-Path $CodexHome 'Skill-Install'),
        (Join-Path $CodexHome 'PPT-Design'),
        (Join-Path $Profile '.agents\skills'),
        (Join-Path $Profile '.agents\plugins'),
        (Join-Path $Profile 'plugins\AI-Canvas')
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -le 20MB -and
                ($extensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -eq '.env') -and
                $_.FullName -notmatch '\\node_modules\\' -and
                $_.FullName -notmatch '\\\.git\\'
            } |
            ForEach-Object { $files.Add($_) }
    }

    $roamingCodex = Join-Path $Profile 'AppData\Roaming\Codex'
    if (Test-Path -LiteralPath $roamingCodex) {
        Get-ChildItem -LiteralPath $roamingCodex -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -le 20MB -and $extensions -contains $_.Extension.ToLowerInvariant() } |
            ForEach-Object { $files.Add($_) }
    }

    $gitConfig = Join-Path $Profile '.gitconfig'
    if (Test-Path -LiteralPath $gitConfig) {
        $files.Add((Get-Item -LiteralPath $gitConfig))
    }

    return $files | Sort-Object FullName -Unique
}

function Replace-PathInTextFiles {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Files
    )

    if ([string]::IsNullOrWhiteSpace($From) -or [string]::IsNullOrWhiteSpace($To)) {
        return 0
    }

    if ([string]::Equals($From, $To, [StringComparison]::OrdinalIgnoreCase)) {
        return 0
    }

    $pairs = New-Object 'System.Collections.Generic.List[object]'
    $pairs.Add(@($From.Replace('\', '\\'), $To.Replace('\', '\\'))) | Out-Null

    if ($From.Length -gt 3 -and $From[1] -eq ':' -and $From[2] -eq '\') {
        $driveDoubledFrom = $From.Substring(0, 3) + '\' + $From.Substring(3)
        $driveDoubledTo = $To.Substring(0, 3) + '\' + $To.Substring(3)
        $pairs.Add(@($driveDoubledFrom, $driveDoubledTo)) | Out-Null
    }

    $pairs.Add(@($From.Replace('\', '/'), $To.Replace('\', '/'))) | Out-Null
    $pairs.Add(@($From, $To)) | Out-Null

    $utf8 = New-Object Text.UTF8Encoding($false)
    $changed = 0

    foreach ($file in $Files) {
        try {
            $text = [IO.File]::ReadAllText($file.FullName)
            $updated = $text

            foreach ($pair in $pairs) {
                $pattern = [Text.RegularExpressions.Regex]::Escape([string]$pair[0])
                $replacement = [string]$pair[1]
                $updated = [Text.RegularExpressions.Regex]::Replace(
                    $updated,
                    $pattern,
                    [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement },
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
            }

            if ($updated -cne $text) {
                [IO.File]::WriteAllText($file.FullName, $updated, $utf8)
                Write-PortableLog "REBASE $($file.FullName)"
                $changed++
            }
        }
        catch {
            Write-PortableLog "WARN Could not inspect $($file.FullName): $($_.Exception.Message)"
        }
    }

    return $changed
}

$root = Get-NormalizedPath $PortableRoot
$profile = Join-Path $root 'data\profile'
$codexHome = Join-Path $profile '.codex'
$logs = Join-Path $root 'data\logs'
$statePath = Join-Path $root 'data\portable-state.json'

if (-not (Test-Path -LiteralPath (Join-Path $root 'app\ChatGPT.exe'))) {
    throw "Missing app\ChatGPT.exe under $root"
}

@(
    $profile,
    $codexHome,
    (Join-Path $profile 'AppData\Roaming'),
    (Join-Path $profile 'AppData\Local'),
    (Join-Path $profile 'Documents\Codex'),
    (Join-Path $profile 'Desktop'),
    (Join-Path $profile 'Downloads'),
    $logs
) | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

$script:LogPath = Join-Path $logs 'prepare-history.log'
$state = $null

if (Test-Path -LiteralPath $statePath) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-PortableLog "WARN Invalid portable-state.json: $($_.Exception.Message)"
    }
}

$lastRoot = $null
$rootChanged = $false
if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'lastRoot') {
    $lastRoot = [string]$state.lastRoot
    $rootChanged = -not [string]::IsNullOrWhiteSpace($lastRoot) -and
        -not [string]::Equals($lastRoot, $root, [StringComparison]::OrdinalIgnoreCase)
}

$needsTextScan = ($Mode -eq 'InitialMigration') -or $rootChanged
$files = @()
if ($needsTextScan) {
    $files = @(Get-OperationalTextFiles -Profile $profile -CodexHome $codexHome)
}

$changed = 0

if ($Mode -eq 'InitialMigration' -and -not [string]::IsNullOrWhiteSpace($SourceProfile)) {
    $source = Get-NormalizedPath $SourceProfile
    $changed += Replace-PathInTextFiles -From $source -To $profile -Files $files
}

if ($rootChanged) {
    $changed += Replace-PathInTextFiles -From $lastRoot -To $root -Files $files
    Write-PortableLog "ROOT_CHANGED $lastRoot -> $root"
}

$preservedSourceProfile = $null
if ($Mode -eq 'InitialMigration') {
    $preservedSourceProfile = $SourceProfile
}
elseif ($null -ne $state) {
    try {
        $preservedSourceProfile = [string]$state.sourceProfile
    }
    catch {
        $preservedSourceProfile = $null
    }
}

$newState = [ordered]@{
    schemaVersion = 1
    launcherVersion = '1.0.0'
    lastRoot = $root
    profile = $profile
    codexHome = $codexHome
    sourceProfile = $preservedSourceProfile
    lastPreparedUtc = (Get-Date).ToUniversalTime().ToString('o')
    lastMode = $Mode
    rebasedFileCount = $changed
}

$json = $newState | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($statePath, $json, (New-Object Text.UTF8Encoding($false)))
Write-PortableLog "READY mode=$Mode root=$root files=$($files.Count) changed=$changed"

Write-Output "PortableRoot=$root"
Write-Output "Profile=$profile"
Write-Output "CodexHome=$codexHome"
Write-Output "RebasedFileCount=$changed"
