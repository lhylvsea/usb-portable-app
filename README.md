# usb-portable-app

把安装在 Windows 上的桌面应用（Electron/Chromium 架构，如 OpenAI Codex/ChatGPT、WorkBuddy、
VS Code、Slack、Discord、Figma 等）改造为 **U 盘绿色便携版** 的可复用 Skill。

## 解决什么问题

这类应用把用户配置、登录态、依赖(vendor)写进本机：

- `C:\Users\<user>\.<appname>` （home 隐藏配置）
- `C:\Users\<user>\AppData\Roaming\<AppName>`
- `C:\Users\<user>\AppData\Local\<AppName>`

它们**不读** `USERPROFILE`/`APPDATA` 环境变量，`--user-data-dir` 之类 CLI 重定向也被拒。
本 Skill 用 **NTFS 目录联接(junction)** 在文件系统层把这些位置重定向到 U 盘，
并内置 **依赖记录(`.extracted`)自检自愈**，防止"环境准备中"无限循环。

## 核心机制

- **junction 重定向**：本机标准位置 → U 盘 `Data\` 副本，本机仅留指针，数据只在 U 盘。
- **依赖自愈**：Electron 捆绑的 vendor 依赖（git/python/node）解压后会写 `.extracted` 记录，
  其中 `archiveHash` = 对应 `resources/vendor/*.zip` 的 sha256。启动前校验，错配即删记录让
  应用重建，正常态零副作用。这是根治"插到别的电脑就卡环境准备中"的关键。

## 安装

把本仓库整个文件夹复制到目标 Agent 的用户级 skills 目录。Codex 使用：

```
C:\Users\<user>\.codex\skills\usb-portable-app\
```

WorkBuddy 使用：

```
~/.workbuddy/skills/usb-portable-app/
```

即保证路径下存在 `SKILL.md` 即可，重启 WorkBuddy 后会在 Skill 列表中可用。

## 使用

在 Codex 或 WorkBuddy 对话中说类似：

> 把 WorkBuddy 改成 U 盘绿色便携版，插任意电脑都能跑

或：

> 把 Codex/ChatGPT 桌面版改成 U 盘便携版，配置和新增 Skill 跟着 U 盘走

Skill 会引导你完成：发现落盘点 → 复制到 U 盘 → 建 junction → 写盘符无关启动器
（`%~dp0` 动态取目录，纯 ASCII `.cmd` 无 BOM）→ 注入自愈逻辑 → 同步/升级策略。

## 文件

- `SKILL.md` — 完整工作流、编码规范、沙箱坑、验证清单
- `references/launch_template.ps1` — 可改写的启动器模板（含 `Repair-DependencyRecords`、junction 建立、启动 exe）
- `references/codex-portable.md` — OpenAI Codex/ChatGPT 桌面版的目录、环境变量、双向同步和验收约定
- `references/codex-launcher.cmd` — 盘符无关的 Codex 启动器模板
- `scripts/sync-codex-profile.ps1` — Codex 配置/Skills 本机↔U 盘双向增量同步
- `scripts/prepare-codex-portable.ps1` — Codex 便携路径重写与换盘处理
- `scripts/Repair-DependencyRecords.ps1` — vendor `.extracted` SHA-256 自检自愈

## 注意

- 便携版内**不要点"升级/更新"**：会自动改写 U 盘 exe 与 vendor 哈希，再次触发重解压循环。
  要升级回本机做，再用同步脚本重同步到 U 盘。
- junction 要求 U 盘为 NTFS；非 NTFS 需降级为复制同步模式（Skill 内有说明）。

## License

MIT
