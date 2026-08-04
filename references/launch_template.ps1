# UTF-8 BOM 编码。文件名用 ASCII（如 launch.ps1），勿用中文名。
# 本文件是模板：把 <APP>、<AppName>、<user> 等占位符替换为实际值即可。
# 路径全部基于脚本自身位置推导，绝不硬编码盘符（U盘插到任何盘符都能用）。

param()

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Join-Path $root '<AppName>'          # 程序目录，如 H:\WorkBuddy
$data = Join-Path $root 'Data'               # 数据根，如 H:\Data
$home = Join-Path $data '.<appname>'         # home 隐藏配置，如 H:\Data\.workbuddy

# ---------- 1) 依赖自检自愈（必须在启动 exe 之前） ----------
function Repair-DependencyRecords {
    param([string]$AppDir, [string]$DataDir)
    $vendor = Join-Path $AppDir 'resources\vendor'
    if (-not (Test-Path $vendor)) { return }
    $zipBases = @{}
    Get-ChildItem $vendor -Filter '*.zip' -ErrorAction SilentlyContinue |
        ForEach-Object { $zipBases[$_.BaseName] = $_.FullName }
    Get-ChildItem $DataDir -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq '.extracted' } | ForEach-Object {
        $extFile = $_.FullName; $matched = $null
        foreach ($b in $zipBases.Keys) { if ($extFile -like "*\$b\*") { $matched = $b; break } }
        if (-not $matched) { return }
        $zipHash = (Get-FileHash $zipBases[$matched] -Algorithm SHA256).Hash
        $j = Get-Content $extFile -Raw -ErrorAction SilentlyContinue
        $rec = $null
        if ($j -match '"archiveHash"\s*:\s*"([0-9a-fA-F]+)"') { $rec = $Matches[1] }
        if (-not $rec -or $rec -ne $zipHash) {
            Remove-Item $extFile -Force -ErrorAction SilentlyContinue
            Write-Host "[self-heal] 重建依赖记录: $matched"
        }
    }
}

# ---------- 2) 确保本机标准位置 junction 到 U盘 ----------
# 标准位置 -> U盘副本 的映射（按第1步探查结果填写）
$maps = @{
    "C:\Users\<user>\.<appname>"          = (Join-Path $home '')                       # home 配置
    "C:\Users\<user>\AppData\Roaming\<AppName>" = (Join-Path $data "AppData\Roaming\<AppName>")
    "C:\Users\<user>\AppData\Local\<AppName>"  = (Join-Path $data "AppData\Local\<AppName>")
    # 其它扩展目录按需追加
}

foreach ($src in $maps.Keys) {
    $dst = $maps[$src]
    if (-not (Test-Path $dst)) { continue }            # U盘副本缺失则跳过，避免建空联接
    if (Test-Path $src) {
        $it = Get-Item $src -Force
        if ($it.LinkType -eq 'Junction') {
            # 已是 junction：校验目标是否指向本 U盘，否则先删后建
            if ($it.Target -and $it.Target[0] -eq $dst) { continue }
            cmd /c "rmdir /q `"$src`"" 2>$null
        } else {
            # 真实目录（之前误直接启动过 exe，用户数据落在了本机）：
            # 先整体增量并入 U盘(/E 不删任一端)，避免 skill/md/新文件夹/设置随盘拔走而丢失。
            # 只合并用户内容(home 与 Roaming)，跳过 Local/Extension 缓存。
            $isUserContent = ($src -like '*.workbuddy') -or ($dst -like '*\AppData\Roaming\*')
            if ($isUserContent) {
                if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
                robocopy $src $dst /E /R:1 /W:1 /NFL /NDL | Out-Null
                Write-Host "[rescue] 本机 -> U盘(整树增量): $src"
            }
            # 备份到 .bak，避免覆盖本机数据
            Move-Item $src ($src + '.bak') -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path $src)) {
        New-Item -ItemType Junction -Path $src -Target $dst -Force | Out-Null
        Write-Host "[junction] $src -> $dst"
    }
}

# ---------- 3) 自检自愈 ----------
Repair-DependencyRecords -AppDir $app -DataDir $home

# ---------- 4) 启动应用 ----------
$exe = Join-Path $app '<AppName>.exe'
if (Test-Path $exe) {
    Start-Process -FilePath $exe
    Write-Host "[launch] 已启动 $exe"
} else {
    Write-Host "[error] 未找到 $exe" -ForegroundColor Red
}
