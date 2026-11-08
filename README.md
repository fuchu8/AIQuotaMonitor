# AI Quota Monitor

macOS 菜单栏工具，监控 **OpenAI Codex**、**Cursor**、**OpenCode Go** 与 **Grok Bot** 的额度。原生 Swift / SwiftUI / AppKit，无第三方依赖，常驻菜单栏，不占 Dock。

包 ID：`com.skye.aiquotamonitor` · 当前版本 **1.4.6** · 需要 macOS 14+。

仓库里只有程序本身。没有作者的 API Key、访问令牌、账号或私人接口地址。每个人用自己电脑上已经登录的 Codex、Cursor、OpenCode Go 或 Grok Bot。

---

## 下载后怎么用

需要 macOS 14 或更高，并安装 Xcode 或 Command Line Tools（里面带 `swift`）。

```bash
git clone https://github.com/fuchu8/AIQuotaMonitor.git
cd AIQuotaMonitor
./build.sh
cp -R -P -p -X "dist/AI Quota Monitor.app" /Applications/
open "/Applications/AI Quota Monitor.app"
```

应用不进 Dock。打开后看屏幕顶部菜单栏右侧的圆形猫图标。悬停可以看到额度摘要，点击打开详情。详情右上角是刷新和设置，底部菜单可以退出。

各平台都用你自己的登录，不需要把密钥写进这个项目：

| 想看的额度 | 你需要先做好的事 |
|---|---|
| Codex | 本机已安装并登录 `codex`。程序会调用它的 `app-server` 只读账户接口。 |
| Cursor | Cursor 桌面版保持登录。程序读取本机钥匙串里已有的登录态。 |
| Grok Bot | 同上，使用 Cursor / Grok Bot 已有的登录态。周池和 Grok、Cursor 共用，不是另一份额度。 |
| OpenCode Go 百分比 | OpenCode 已登录，或本机环境变量 `OPENCODE_GO_API_KEY` / `OPENCODE_API_KEY` 里有你自己的 `oc_` 密钥。密钥留在本机，不要提交到 Git。 |
| OpenCode Go 的 Token 列 | 只统计本机 `~/.workbuddy/logs` 里能匹配到的用量。换一台电脑、日志不全时，这三列会不完整。百分比仍以官方接口为准。 |

Cursor 读不到官方百分比时，可以在详情或设置里导入 [Cursor Dashboard](https://cursor.com/dashboard?tab=usage) 导出的 CSV，或手动填一个已用百分比。这是备用，不是必须。

设置里可以改刷新间隔（1 / 5 / 15 / 30 分钟）、低额度提醒、登录后自动启动，以及显示或隐藏桌面小窗。桌面小窗从顶部或底部标着「拖动」的区域按住移动，它不是系统「添加小组件」里的 Widget。

---

## 一、数据来源

| 平台 | 数据源 | 状态 | 可获取字段 |
|---|---|---|---|
| Codex | 官方 App Server `account/rateLimits/read` | ✅ 可用 | 额度池、已用百分比、重置时间、Credits、限流状态 |
| Codex | 官方 `account/read` / `account/usage/read` | ✅ 可用 | 账号与套餐、逐日 / 累计 Token |
| Cursor | 本机登录态 → DashboardService（**非公开稳定 API**） | ✅ 可用 | Cursor Models / Other Models 已用百分比；今日 / 本周期 / 近 90 天 Token |
| Cursor | 官方 Dashboard → Export CSV / 手动录入 | ✅ 备用 | CSV Token 明细；手动百分比 |
| Cursor | 本地 `state.vscdb` / `ai-code-tracking.db` | ✅ 元数据 | 套餐、订阅状态、版本、本地代码片段调用量（非额度） |
| OpenCode Go | 官方 `/zen/go/v1/usage` | ✅ 可用 | 5 小时 / 每周 / 每月已用百分比 |
| OpenCode Go | 本机 ModelProvider 日志增量汇总 | ✅ 可用 | 今日 / 本周期或近 30 天 / 日志覆盖范围内累计 Token（**不是 WorkBuddy 积分**） |
| Grok Bot | 本机登录态 → `GetSandUsageStatus` | ✅ 可用 | 周池已用百分比 |

本版本**不再监控 WorkBuddy 积分**，也不会读取 `workbuddy.db`。若 Go Token 日志仍位于 `~/.workbuddy/logs`，界面会标明「Go 本机日志」，不会把它当成 WorkBuddy 额度。

---

## 二、功能

**菜单栏**
- 始终只显示猫图标；悬停看 tooltip；点击打开 NSPopover 详情（无悬停展开、无动态变宽）
- Tooltip 可切换剩余/已用与 Codex 代表窗口

**桌面常驻窗**
- 可拖动的普通层级信息窗（不是系统「添加小组件」）。设置 / 详情面板可显示或隐藏；位置会记住。详见 `WIDGET.md`。

**面板**
- Codex / Cursor / OpenCode Go / Grok Bot 四张卡片；中间可滚动，高度跟随屏幕
- 额度与 Token 分开标注成功时间；抓取失败时保留旧值并标明过期
- Go Token 常驻说明覆盖范围与「模型匹配估算」

**设置**
- 刷新间隔 1 / 5 / 15 / 30 分钟（修改后下一次计时立即采用新值）
- ≤20% / ≤10% / 重置通知（关闭重置通知不会阻断下一周期的低额度提醒）
- 登录后自动启动、Cursor CSV / 手动录入

---

## 三、构建

```bash
cd AIQuotaMonitor
./build.sh              # release + ad-hoc 签名 → dist/AI Quota Monitor.app
swift test              # 自动测试（WAL 只读、Codex 去重、告警周期、Go 合并/增量日志）
```

安装：

```bash
cp -R -P -p -X "dist/AI Quota Monitor.app" /Applications/
open "/Applications/AI Quota Monitor.app"
```

---

## 四、诊断

```bash
B="/Applications/AI Quota Monitor.app/Contents/MacOS/AIQuotaMonitor"
"$B" --diagnose          # 各来源独立状态；失败/超时非 0 退出；默认脱敏
"$B" --render-panel      # 等待刷新后离屏渲染到 /tmp/aqm/panel.png
```

日志：`~/Library/Application Support/AIQuotaMonitor/app.log`（不含凭据）  
历史：`~/Library/Application Support/AIQuotaMonitor/history.sqlite3`

---

## 五、隐私

- 不向独立遥测服务上报。
- 仅向对应厂商发送已认证的用量查询（Codex App Server / Cursor 与 Grok 账户接口 / OpenCode Go）。
- 不读取 `~/.codex/auth.json` 原文写入日志；不把 Cursor 令牌或 OpenCode Go 密钥写入本程序配置、历史或日志。
- 可能读取本机钥匙串中已有的 Cursor 登录态，以及 Go 本机日志中的 Token 用量行。
- 不修改 Codex / Cursor / WorkBuddy / OpenCode 的登录状态、配置或项目文件；不卸载 WorkBuddy，不删除其数据。

---

## 六、工程结构

```
Sources/AIQuotaMonitor/          # AIQuotaMonitorCore
Sources/App/main.swift           # 可执行入口
Tests/AIQuotaMonitorTests/       # 复现场景自动测试
```
