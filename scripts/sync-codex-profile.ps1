[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Sync')]
    [string]$Mode = 'Preview',

    [string]$PortableRoot,

    [string]$LocalProfile,

    [switch]$AllowRunning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Split-Path -Parent $PSScriptRoot
}

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-HostProfile {
    param([string]$ExplicitProfile, [string]$PortableProfile)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitProfile)) {
        return (Normalize-Path $ExplicitProfile)
    }

    $candidates = @(
        [Environment]::GetEnvironmentVariable('USERPROFILE', 'User'),
        [Environment]::GetEnvironmentVariable('USERPROFILE', 'Machine'),
        $env:USERPROFILE
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $fallback = $null
    foreach ($candidate in $candidates) {
        try {
            $profile = Normalize-Path $candidate
            if (-not [string]::Equals($profile, $PortableProfile, [StringComparison]::OrdinalIgnoreCase)) {
                if ((Test-Path -LiteralPath (Join-Path $profile '.codex')) -or
                    (Test-Path -LiteralPath (Join-Path $profile '.agents'))) {
                    return $profile
                }
                if ($null -eq $fallback -and (Test-Path -LiteralPath $profile)) {
                    $fallback = $profile
                }
            }
        }
        catch {
            continue
        }
    }

    if ($null -ne $fallback) { return $fallback }
    throw 'Cannot determine the local user profile. Pass -LocalProfile explicitly.'
}

function Get-CodexProcesses {
    param(
        [string]$PortableRoot,
        [string]$LocalProfile
    )

    # Block every Codex process, not only the currently known install path.
    # A newer host install (for example C:\Codex) may not mention USERPROFILE
    # in its command line, but it can still write the local profile while sync
    # is running.
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(ChatGPT|codex|codex-code-mode-host|node_repl)(\.exe)?$'
        })
}

function Add-RobocopyArguments {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Source,
        [string]$Destination,
        [bool]$Preview,
        [bool]$MissingOnly,
        [bool]$LocalAuthority
    )

    $Arguments.Add($Source)
    $Arguments.Add($Destination)
    $Arguments.Add('/E')
    if ($Preview) { $Arguments.Add('/L') }
    if ($MissingOnly) {
        $Arguments.Add('/XC')
        $Arguments.Add('/XN')
        $Arguments.Add('/XO')
    }
    elseif (-not $LocalAuthority) {
        $Arguments.Add('/XO')
    }
    else {
        $Arguments.Add('/IS')
        $Arguments.Add('/IT')
    }
    $Arguments.Add('/FFT')
    $Arguments.Add('/COPY:DAT')
    $Arguments.Add('/DCOPY:DAT')
    $Arguments.Add('/R:1')
    $Arguments.Add('/W:1')
    $Arguments.Add('/MT:8')
    $Arguments.Add('/XJ')
    $Arguments.Add('/NFL')
    $Arguments.Add('/NDL')
    $Arguments.Add('/NJH')
    $Arguments.Add('/NJS')
    $Arguments.Add('/NP')
    $Arguments.Add('/XD')
    foreach ($name in @(
        'node_modules', '.git', '.venv', 'venv', '__pycache__', 'cache', 'tmp', '.tmp', 'logs',
        'generated_images', 'visualizations', 'node_repl', 'process_manager',
        'mcp-oauth-locks', '.sandbox', '.sandbox-bin', '.sandbox-secrets', 'sessions', 'archived_sessions',
        'Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
        'Crashpad', 'sentry', 'BrowserMetrics', 'component_crx_cache',
        'extensions_crx_cache', 'GPUPersistentCache', 'GrShaderCache', 'ShaderCache'
    )) {
        $Arguments.Add((Join-Path $Source $name))
    }
    $Arguments.Add('/XF')
    foreach ($pattern in @('*.sqlite', '*.sqlite-wal', '*.sqlite-shm', '*.log', '*.lock', 'lockfile', 'Cookies', 'Cookies-journal', '*Safe Browsing Cookies*', 'History', 'History-journal', 'Login Data', 'Login Data-journal', 'Web Data', 'Web Data-journal')) {
        $Arguments.Add($pattern)
    }
    # Stable text files are synced by Invoke-TextSyncFile so profile/root paths
    # can differ between the host and the USB copy without causing ping-pong.
    foreach ($relative in @(
        'AGENTS.md', 'SOUL.md', 'USER.md', 'config.toml', 'auth.json', '.env',
        '.codex-global-state.json', 'chrome-native-hosts-v2.json',
        'gpt-5.5-base-instructions.md', 'version.json', '.skill-lock.json',
        'browser-sidebar-local-servers.json', 'Local State', 'Preferences', 'SharedStorage'
    )) {
        $Arguments.Add((Join-Path $Source $relative))
    }
}

function Invoke-SyncPass {
    param(
        [string]$Source,
        [string]$Destination,
        [bool]$Preview,
        [bool]$MissingOnly,
        [bool]$LocalAuthority,
        [System.Collections.Generic.List[string]]$Log
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        $Log.Add("SKIP missing source: $Source")
        return 0
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    Add-RobocopyArguments -Arguments $arguments -Source $Source -Destination $Destination -Preview $Preview -MissingOnly $MissingOnly -LocalAuthority $LocalAuthority
    $output = (& robocopy.exe @arguments 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $Log.Add("ROBOCOPY $Source -> $Destination code=$code")
    if (-not [string]::IsNullOrWhiteSpace($output)) {
        $Log.Add($output.Trim())
    }
    if ($code -ge 8) {
        throw "Robocopy failed ($code): $Source -> $Destination"
    }
    return $code
}

function Invoke-SyncFile {
    param(
        [string]$RelativeFile,
        [string]$LocalRoot,
        [string]$PortableRoot,
        [bool]$Preview,
        [bool]$MissingOnly,
        [ValidateSet('Local', 'Portable')][string]$SourceSide,
        [bool]$ForceSource,
        [System.Collections.Generic.List[string]]$Log
    )

    $localPath = Join-Path $LocalRoot $RelativeFile
    $portablePath = Join-Path $PortableRoot $RelativeFile
    $sourcePath = if ($SourceSide -eq 'Local') { $localPath } else { $portablePath }
    $destinationPath = if ($SourceSide -eq 'Local') { $portablePath } else { $localPath }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        return
    }
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $arguments.Add((Split-Path -Parent $sourcePath))
    $arguments.Add((Split-Path -Parent $destinationPath))
    $arguments.Add((Split-Path -Leaf $sourcePath))
    if ($Preview) { $arguments.Add('/L') }
    if ($MissingOnly) {
        $arguments.Add('/XC'); $arguments.Add('/XN'); $arguments.Add('/XO')
    }
    elseif (-not $ForceSource) {
        $arguments.Add('/XO')
    }
    else {
        $arguments.Add('/IS'); $arguments.Add('/IT')
    }
    $arguments.Add('/FFT'); $arguments.Add('/COPY:DAT'); $arguments.Add('/R:1'); $arguments.Add('/W:1'); $arguments.Add('/NJH'); $arguments.Add('/NJS'); $arguments.Add('/NP')
    $output = (& robocopy.exe @arguments 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $Log.Add("ROBOCOPY FILE $RelativeFile code=$code")
    if (-not [string]::IsNullOrWhiteSpace($output)) { $Log.Add($output.Trim()) }
    if ($code -ge 8) { throw "Robocopy failed ($code): $RelativeFile" }
}

function Get-CanonicalText {
    param(
        [string]$Text,
        [string[]]$KnownPaths
    )

    $normalized = $Text
    $variants = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $KnownPaths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        foreach ($variant in @(
            $path,
            $path.Replace('\', '/'),
            $path.Replace('\', '\\')
        )) {
            if (-not [string]::IsNullOrWhiteSpace($variant)) {
                $variants.Add($variant)
            }
        }
    }

    foreach ($variant in ($variants | Sort-Object Length -Descending -Unique)) {
        $normalized = [Text.RegularExpressions.Regex]::Replace(
            $normalized,
            [Text.RegularExpressions.Regex]::Escape($variant),
            '<CODEX_PATH>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    return $normalized
}

function Rebase-TextFile {
    param(
        [string]$Path,
        [string[]]$FromPaths,
        [string]$ToPath
    )

    foreach ($from in ($FromPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object Length -Descending -Unique)) {
        Replace-PathInTextFile -Path $Path -From $from -To $ToPath
    }
}

function Copy-TextFileWithRebase {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$FromPaths,
        [string]$ToPath,
        [datetime]$Timestamp
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    $text = [IO.File]::ReadAllText($Source)
    [IO.File]::WriteAllText($Destination, $text, (New-Object Text.UTF8Encoding($false)))
    Rebase-TextFile -Path $Destination -FromPaths $FromPaths -ToPath $ToPath
    [IO.File]::SetLastWriteTimeUtc($Destination, $Timestamp.ToUniversalTime())
}

function Invoke-TextSyncFile {
    param(
        [string]$RelativeFile,
        [string]$LocalRoot,
        [string]$PortableRoot,
        [string[]]$KnownPaths,
        [string[]]$PortablePathHistory,
        [bool]$Preview,
        [System.Collections.Generic.List[string]]$Log
    )

    $localPath = Join-Path $LocalRoot $RelativeFile
    $portablePath = Join-Path $PortableRoot $RelativeFile
    $localExists = Test-Path -LiteralPath $localPath -PathType Leaf
    $portableExists = Test-Path -LiteralPath $portablePath -PathType Leaf
    if (-not $localExists -and -not $portableExists) { return }

    $localFromPaths = @($PortablePathHistory + $LocalRoot)
    $portableFromPaths = @($LocalRoot + $PortablePathHistory)

    if (-not $localExists) {
        $sourceTime = (Get-Item -LiteralPath $portablePath -Force).LastWriteTimeUtc
        $Log.Add("TEXT COPY portable -> local $RelativeFile")
        if (-not $Preview) {
            Copy-TextFileWithRebase -Source $portablePath -Destination $localPath -FromPaths $localFromPaths -ToPath $LocalRoot -Timestamp $sourceTime
        }
        return
    }
    if (-not $portableExists) {
        $sourceTime = (Get-Item -LiteralPath $localPath -Force).LastWriteTimeUtc
        $Log.Add("TEXT COPY local -> portable $RelativeFile")
        if (-not $Preview) {
            Copy-TextFileWithRebase -Source $localPath -Destination $portablePath -FromPaths $portableFromPaths -ToPath $PortableRoot -Timestamp $sourceTime
        }
        return
    }

    try {
        $localText = [IO.File]::ReadAllText($localPath)
        $portableText = [IO.File]::ReadAllText($portablePath)
        $localCanonical = Get-CanonicalText -Text $localText -KnownPaths $KnownPaths
        $portableCanonical = Get-CanonicalText -Text $portableText -KnownPaths $KnownPaths
    }
    catch {
        $Log.Add("TEXT FALLBACK ${RelativeFile}: $($_.Exception.Message)")
        [void](Invoke-SyncFile -RelativeFile $RelativeFile -LocalRoot $LocalRoot -PortableRoot $PortableRoot -Preview $Preview -MissingOnly $false -SourceSide Local -ForceSource $false -Log $Log)
        return
    }

    if ($localCanonical -ceq $portableCanonical) {
        $Log.Add("TEXT SAME (path-normalized) $RelativeFile")
        return
    }

    $localTime = (Get-Item -LiteralPath $localPath -Force).LastWriteTimeUtc
    $portableTime = (Get-Item -LiteralPath $portablePath -Force).LastWriteTimeUtc
    if ($localTime -ge $portableTime) {
        $Log.Add("TEXT NEWER local -> portable $RelativeFile")
        if (-not $Preview) {
            Copy-TextFileWithRebase -Source $localPath -Destination $portablePath -FromPaths $portableFromPaths -ToPath $PortableRoot -Timestamp $localTime
        }
    }
    else {
        $Log.Add("TEXT NEWER portable -> local $RelativeFile")
        if (-not $Preview) {
            Copy-TextFileWithRebase -Source $portablePath -Destination $localPath -FromPaths $localFromPaths -ToPath $LocalRoot -Timestamp $portableTime
        }
    }
}

function Replace-PathInTextFile {
    param([string]$Path, [string]$From, [string]$To)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        [string]::IsNullOrWhiteSpace($From) -or
        [string]::Equals($From, $To, [StringComparison]::OrdinalIgnoreCase) -or
        ([IO.Path]::GetExtension($Path).ToLowerInvariant() -notin @('.md', '.txt', '.toml', '.json', '.jsonl', '.yaml', '.yml', '.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.ini', '.conf', '.xml', '.env'))) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -gt 20MB) { return }
    $text = [IO.File]::ReadAllText($Path)
    $updated = $text
    foreach ($pair in @(
        @($From.Replace('\', '\\'), $To.Replace('\', '\\')),
        @($From.Replace('\', '/'), $To.Replace('\', '/')),
        @($From, $To)
    )) {
        $updated = [Text.RegularExpressions.Regex]::Replace(
            $updated,
            [Text.RegularExpressions.Regex]::Escape([string]$pair[0]),
            [Text.RegularExpressions.MatchEvaluator]{ param($match) [string]$pair[1] },
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    if ($updated -cne $text) {
        [IO.File]::WriteAllText($Path, $updated, (New-Object Text.UTF8Encoding($false)))
    }
}

function Repair-LocalProfilePaths {
    param([string]$LocalProfile, [string]$PortableProfile)
    $files = @(
        (Get-ChildItem -LiteralPath (Join-Path $LocalProfile '.codex') -Force -File -ErrorAction SilentlyContinue),
        (Get-ChildItem -LiteralPath (Join-Path $LocalProfile '.agents') -Force -File -ErrorAction SilentlyContinue)
    ) | Where-Object { $null -ne $_ }
    foreach ($file in $files) {
        Replace-PathInTextFile -Path $file.FullName -From $PortableProfile -To $LocalProfile
    }
}

$root = Normalize-Path $PortableRoot
$portableProfile = Normalize-Path (Join-Path $root 'data\profile')
$localProfile = Get-HostProfile -ExplicitProfile $LocalProfile -PortableProfile $portableProfile
$statePath = Join-Path $root 'data\sync-state.json'
$portableStatePath = Join-Path $root 'data\portable-state.json'
$logDirectory = Join-Path $root 'data\logs'
$logPath = Join-Path $logDirectory 'sync-latest.txt'
$log = New-Object 'System.Collections.Generic.List[string]'

if (-not (Test-Path -LiteralPath (Join-Path $root 'CodexPortable.exe'))) { throw "Portable launcher not found: $root" }
if (-not (Test-Path -LiteralPath $portableProfile)) { throw "Portable profile not found: $portableProfile" }
if ([string]::Equals($localProfile, $portableProfile, [StringComparison]::OrdinalIgnoreCase)) { throw 'Local and portable profiles are the same path.' }

$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "Cannot read sync state: $($_.Exception.Message)" }
}
$portableState = $null
if (Test-Path -LiteralPath $portableStatePath -PathType Leaf) {
    try { $portableState = Get-Content -LiteralPath $portableStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $portableState = $null }
}
$initial = $null -eq $state -or -not [bool]$state.initialSyncComplete
$log.Add("MODE=$Mode")
$log.Add("INITIAL_SYNC=$initial")
$log.Add("LOCAL_PROFILE=$localProfile")
$log.Add("PORTABLE_PROFILE=$portableProfile")

# Text files are kept path-portable: compare them after replacing both sides'
# known profile/root paths with a token, then rebase only the copied side.
# Rebase uses profile paths only so a suffix such as `\.codex` is preserved.
$portablePathHistory = New-Object 'System.Collections.Generic.List[string]'
$portablePathHistory.Add($portableProfile)
$portableRootHistory = New-Object 'System.Collections.Generic.List[string]'
$portableRootHistory.Add($root)
if ($null -ne $state) {
    foreach ($propertyName in @('portableProfile', 'profile')) {
        if ($state.PSObject.Properties.Name -contains $propertyName) {
            $value = [string]$state.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($value)) { $portablePathHistory.Add($value) }
        }
    }
    if ($state.PSObject.Properties.Name -contains 'lastRoot') {
        $value = [string]$state.lastRoot
        if (-not [string]::IsNullOrWhiteSpace($value)) { $portableRootHistory.Add($value) }
    }
}
if ($null -ne $portableState) {
    if ($portableState.PSObject.Properties.Name -contains 'profile') {
        $value = [string]$portableState.profile
        if (-not [string]::IsNullOrWhiteSpace($value)) { $portablePathHistory.Add($value) }
    }
    if ($portableState.PSObject.Properties.Name -contains 'lastRoot') {
        $value = [string]$portableState.lastRoot
        if (-not [string]::IsNullOrWhiteSpace($value)) { $portableRootHistory.Add($value) }
    }
}
$localPathHistory = New-Object 'System.Collections.Generic.List[string]'
$localPathHistory.Add($localProfile)
if ($null -ne $state) {
    foreach ($propertyName in @('localProfile', 'sourceProfile')) {
        if ($state.PSObject.Properties.Name -contains $propertyName) {
            $value = [string]$state.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($value)) { $localPathHistory.Add($value) }
        }
    }
}
$knownSyncPaths = @($localPathHistory + $portablePathHistory + $portableRootHistory)

$running = @(Get-CodexProcesses -PortableRoot $root -LocalProfile $localProfile)
if ($running.Count -gt 0) {
    $log.Add("RUNNING_PROCESSES=$($running.Count)")
    foreach ($process in $running) { $log.Add("PROCESS=$($process.ProcessId) $($process.Name) $($process.ExecutablePath)") }
}
if ($Mode -eq 'Sync' -and $running.Count -gt 0 -and -not $AllowRunning) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    [IO.File]::WriteAllLines($logPath, $log, (New-Object Text.UTF8Encoding($false)))
    throw 'Codex is running. Close the local and portable Codex windows before syncing.'
}

$directoryRoots = @(
    '.codex',
    '.agents\skills',
    '.agents\plugins',
    '.cache\codex-runtimes',
    'plugins\AI-Canvas',
    'AppData\Roaming\Codex',
    'AppData\Local\OpenAI'
)
$stableFiles = @(
    '.codex\AGENTS.md', '.codex\SOUL.md', '.codex\USER.md', '.codex\config.toml',
    '.codex\auth.json', '.codex\.env', '.codex\.codex-global-state.json',
    '.codex\chrome-native-hosts-v2.json', '.codex\gpt-5.5-base-instructions.md',
    '.codex\version.json', '.agents\.skill-lock.json', '.gitconfig', '.npmrc',
    'pip\pip.ini', 'AppData\Roaming\Codex\browser-sidebar-local-servers.json',
    'AppData\Roaming\Codex\Local State', 'AppData\Roaming\Codex\Preferences',
    'AppData\Roaming\Codex\SharedStorage'
)

if ($Mode -eq 'Preview') {
    if ($initial) {
        foreach ($relative in $directoryRoots) {
            [void](Invoke-SyncPass -Source (Join-Path $portableProfile $relative) -Destination (Join-Path $localProfile $relative) -Preview $true -MissingOnly $true -LocalAuthority $false -Log $log)
            [void](Invoke-SyncPass -Source (Join-Path $localProfile $relative) -Destination (Join-Path $portableProfile $relative) -Preview $true -MissingOnly $false -LocalAuthority $false -Log $log)
        }
        foreach ($relative in $stableFiles) {
            [void](Invoke-TextSyncFile -RelativeFile $relative -LocalRoot $localProfile -PortableRoot $portableProfile -KnownPaths $knownSyncPaths -PortablePathHistory $portablePathHistory -Preview $true -Log $log)
        }
    }
    else {
        foreach ($relative in $directoryRoots) {
            [void](Invoke-SyncPass -Source (Join-Path $localProfile $relative) -Destination (Join-Path $portableProfile $relative) -Preview $true -MissingOnly $false -LocalAuthority $false -Log $log)
            [void](Invoke-SyncPass -Source (Join-Path $portableProfile $relative) -Destination (Join-Path $localProfile $relative) -Preview $true -MissingOnly $false -LocalAuthority $false -Log $log)
        }
        foreach ($relative in $stableFiles) {
            [void](Invoke-TextSyncFile -RelativeFile $relative -LocalRoot $localProfile -PortableRoot $portableProfile -KnownPaths $knownSyncPaths -PortablePathHistory $portablePathHistory -Preview $true -Log $log)
        }
    }
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    [IO.File]::WriteAllLines($logPath, $log, (New-Object Text.UTF8Encoding($false)))
    Write-Output "MODE=Preview"
    Write-Output "INITIAL_SYNC=$initial"
    Write-Output "LOCAL_PROFILE=$localProfile"
    Write-Output "PORTABLE_PROFILE=$portableProfile"
    Write-Output "REPORT=$logPath"
    exit 0
}

foreach ($relative in $directoryRoots) {
    if ($initial) {
        [void](Invoke-SyncPass -Source (Join-Path $portableProfile $relative) -Destination (Join-Path $localProfile $relative) -Preview $false -MissingOnly $true -LocalAuthority $false -Log $log)
        [void](Invoke-SyncPass -Source (Join-Path $localProfile $relative) -Destination (Join-Path $portableProfile $relative) -Preview $false -MissingOnly $false -LocalAuthority $false -Log $log)
    }
    else {
        [void](Invoke-SyncPass -Source (Join-Path $localProfile $relative) -Destination (Join-Path $portableProfile $relative) -Preview $false -MissingOnly $false -LocalAuthority $false -Log $log)
        [void](Invoke-SyncPass -Source (Join-Path $portableProfile $relative) -Destination (Join-Path $localProfile $relative) -Preview $false -MissingOnly $false -LocalAuthority $false -Log $log)
    }
}

foreach ($relative in $stableFiles) {
    [void](Invoke-TextSyncFile -RelativeFile $relative -LocalRoot $localProfile -PortableRoot $portableProfile -KnownPaths $knownSyncPaths -PortablePathHistory $portablePathHistory -Preview $false -Log $log)
}

# Rebase text paths after copying. This keeps the USB side portable and the
# host side valid when the drive letter changes.
$prepare = Join-Path $root 'portable\Prepare-Portable.ps1'
if (Test-Path -LiteralPath $prepare) {
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $prepare -PortableRoot $root -Mode InitialMigration -SourceProfile $localProfile | ForEach-Object { $log.Add([string]$_) }
    if ($LASTEXITCODE -ne 0) { throw 'Portable path preparation failed after sync.' }
}
Repair-LocalProfilePaths -LocalProfile $localProfile -PortableProfile $portableProfile

$state = [ordered]@{
    schemaVersion = 1
    initialSyncComplete = $true
    lastSyncUtc = (Get-Date).ToUniversalTime().ToString('o')
    localProfile = $localProfile
    portableProfile = $portableProfile
    policy = 'newer-file-wins; no deletions; missing files are added in both directions'
}
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllLines($logPath, $log, (New-Object Text.UTF8Encoding($false)))

Write-Output 'MODE=Sync'
Write-Output "INITIAL_SYNC=$initial"
Write-Output "LOCAL_PROFILE=$localProfile"
Write-Output "PORTABLE_PROFILE=$portableProfile"
Write-Output "STATE=$statePath"
Write-Output "REPORT=$logPath"
