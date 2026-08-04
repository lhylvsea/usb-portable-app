# Codex 便携版实施参考

这份参考用于把 Windows Codex/ChatGPT 桌面版做成可移动副本。它描述的是可复用的目录和验证约定，不包含任何用户密钥。

## 推荐布局

```text
<portable-root>\
├─ app\ChatGPT.exe
├─ CodexPortable.exe
├─ Start-Codex-Portable.cmd
├─ data\
│  ├─ profile\.codex\
│  ├─ profile\.agents\skills\
│  ├─ profile\.cache\codex-runtimes\
│  ├─ profile\AppData\Roaming\Codex\
│  └─ profile\AppData\Local\OpenAI\
└─ portable\
   ├─ Prepare-Portable.ps1
   └─ Sync-Codex-Portable.ps1
```

## 启动变量

启动器必须根据 `%~dp0` 推导根目录，至少设置：

```text
USERPROFILE=<root>\data\profile
HOME=<root>\data\profile
CODEX_HOME=<root>\data\profile\.codex
APPDATA=<root>\data\profile\AppData\Roaming
LOCALAPPDATA=<root>\data\profile\AppData\Local
GIT_CONFIG_GLOBAL=<root>\data\profile\.gitconfig
NPM_CONFIG_USERCONFIG=<root>\data\profile\.npmrc
PIP_CONFIG_FILE=<root>\data\profile\pip\pip.ini
```

XDG、npm/pip/uv、Cargo 和 dotnet 的用户目录也应指向 `data\profile`，避免依赖落到主机用户目录。不能直接启动 `app\ChatGPT.exe`。

## 两种重定向策略

1. 先使用环境变量重定向。这是 Codex 当前便携实现的首选，便携副本直接读写 U 盘 `data\profile`。
2. 如果某个组件忽略环境变量并仍写入 `C:\Users\<user>` 或 `AppData`，再对**实测写入点**创建 NTFS junction。创建前先增量合并真实目录，确认目标目录存在，并记录还原路径；不要把整个用户目录做成 junction。

## 同步策略

运行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\portable\Sync-Codex-Portable.ps1 `
  -PortableRoot $PWD `
  -Mode Preview
```

确认报告无误后把 `Preview` 换成 `Sync`。脚本自动识别当前 Windows 用户 profile，不依赖 `E:`、`H:`、`X:` 等固定盘符；它从 `portable-state.json` 和 `sync-state.json` 读取旧根目录，处理复制/换盘后残留路径。

同步范围包括 `.codex` 中的非易变配置、Skills、插件、工具、记忆、认证文件，以及 `.agents\skills`、`.agents\plugins`、运行时和 Codex 桌面配置。会话 SQLite、WAL、日志、缓存和临时目录排除，避免复制运行中的数据库。

冲突规则：较新的文件胜出；缺失文件双向补齐；不自动删除。两边同时修改同一文件且时间戳相同，应人工查看 `data\logs\sync-latest.txt`。

## 依赖自愈

在启动 Codex 前调用：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Repair-DependencyRecords.ps1 `
  -VendorDir .\app\resources\vendor `
  -DataDir .\data\profile\.codex
```

脚本只检查 `.extracted` 的 `archiveHash` 是否等于对应 vendor zip 的 SHA-256。健康记录不触碰；缺失、损坏或哈希漂移的记录被删除，让应用下一次启动重新解压。删除的是记录文件，不是 vendor 压缩包或用户数据。

## 验收

- `app\ChatGPT.exe`、`resources`、DLL 和 vendor 文件来自同一完整版本。
- 启动日志中的 `USERPROFILE`/`CODEX_HOME` 指向当前 U 盘根目录。
- `Get-Item <host-path> | Select-Object LinkType,Target` 能确认 junction 的目标（如使用 junction）。
- 运行依赖自愈脚本后，健康记录显示未修改；构造一个错误 hash 的隔离测试记录时只删除该记录。
- 本机新增 Skill → 同步后 U 盘出现；U 盘新增 Skill → 插回本机同步后本机出现。
- 换盘符后启动器能正常重写路径；不得以旧盘符仍出现在文本配置中作为成功标准。
