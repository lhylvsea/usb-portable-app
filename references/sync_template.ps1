# WorkBuddy Portable Sync-Install
# 把本机已安装的 WorkBuddy 程序文件同步进U盘，升级后保持便携版程序最新。
# 数据目录(Data)不动——U盘数据才是真相来源，必须保留。

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$app  = Join-Path $root 'WorkBuddy'

# 候选安装位置（覆盖常见盘符与安装方式，含升级后迁移到 D:\Program Files 的情况）
$search = [System.Collections.Generic.List[string]]::new()
$search.Add((Join-Path $env:LOCALAPPDATA 'Programs\WorkBuddy\WorkBuddy.exe'))
$search.Add((Join-Path $env:USERPROFILE 'AppData\Local\Programs\WorkBuddy\WorkBuddy.exe'))
$search.Add('C:\Program Files\WorkBuddy\WorkBuddy.exe')
$search.Add('C:\Program Files (x86)\WorkBuddy\WorkBuddy.exe')
$search.Add('D:\Program Files\WorkBuddy\WorkBuddy.exe')
$search.Add('D:\Program Files (x86)\WorkBuddy\WorkBuddy.exe')

# 全盘扫描所有磁盘的 Program Files / Program Files (x86) 下的 WorkBuddy（盘符不固定也兜底）
try {
  Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    $root2 = $_.Root
    foreach ($sub in @('Program Files', 'Program Files (x86)')) {
      $p = Join-Path $root2 (Join-Path $sub 'WorkBuddy\WorkBuddy.exe')
      if (Test-Path $p) { $search.Add($p) }
    }
  }
} catch {}

# 收集所有真实存在的 exe，选取修改时间最新者（避免把残留的旧版误同步进U盘）
$candidates = $search | Where-Object { Test-Path $_ } | ForEach-Object { Get-Item $_ }
if ($candidates.Count -eq 0) {
  Write-Host '无法自动定位本机 WorkBuddy.exe。'
  Write-Host '请手动把它的父文件夹复制到本U盘的 WorkBuddy 文件夹。'
  Read-Host '按回车退出'
  exit 1
}
$srcItem = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$src = $srcItem.FullName
Write-Host ('已定位源(最新): ' + $src + '  修改时间: ' + $srcItem.LastWriteTime)

$confirm = Read-Host '将程序文件同步进U盘(覆盖U盘\WorkBuddy)? [Y/N]'
if ($confirm -ne 'Y' -and $confirm -ne 'y') { Write-Host '已取消。'; exit 0 }

$srcDir = Split-Path $src
# 双保险：源必须是真实安装目录(含 resources)，否则 /MIR 可能误清空U盘程序
if (-not (Test-Path (Join-Path $srcDir 'resources'))) {
  Write-Host '[错误] 源目录不含 resources 子目录，可能不是 WorkBuddy 安装目录。已中止，以防误清空U盘程序。'
  Read-Host '按回车退出'
  exit 1
}
Write-Host ('正在从 ' + $srcDir + ' 镜像同步(含清理旧文件)...')
& robocopy $srcDir $app /MIR /R:2 /W:2 /NFL /NDL
Write-Host '同步完成。'
