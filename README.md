# CC Cost Monitor

[English](#english) | [中文](#中文)

<img width="193" height="330" alt="image" src="https://github.com/user-attachments/assets/13c5218d-5e0f-4ad3-ade1-f80416825592" />
<img width="193" height="418" alt="image" src="https://github.com/user-attachments/assets/8b9e98f6-0543-47cd-b694-f4e531d09f01" />

---

## English

macOS menu bar app that shows how much you're spending on [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Parses local session logs — zero tokens consumed, nothing sent anywhere.

### Why this exists

Claude Code's `/cost` only shows the current session. If you have multiple Anthropic accounts, use API keys, or connect through AWS Bedrock / GCP Vertex — good luck figuring out your total spend.

This app reads all your local session data and puts it in one place. One menu bar icon, done.

### What you get

- **Cost & Tokens** — switch views, with per-model breakdown (Opus / Sonnet / Haiku)
- **Subscription quota** (Pro / Max) — dedicated tab showing how much is *left* in the 5-hour, 7-day and 7-day Sonnet windows, with reset countdowns. Live from Anthropic's official usage endpoint — the same source Claude Code's `/usage` uses
- **Today / This Week / This Month** — token distribution by type (input, output, cache read, cache write)
- **Daily bar chart** — hover for details
- **Month navigation** — browse past months, cached locally
- **4 languages** — English, 简体中文, 繁體中文, 日本語
- **Auto-refresh** — every 30 min + on screen wake
- **Menu bar only** — no Dock icon, click app again to show popover

### Requirements

- macOS 13+, Intel or Apple Silicon
- Python 3
- Claude Code with session data in `~/.claude/projects/`

### Install

#### Download DMG

Grab `CCCostMonitor.dmg` from [Releases](../../releases), drag to Applications.

First launch: right-click → Open (bypasses Gatekeeper for unsigned apps).

#### Build from source

```bash
git clone https://github.com/kuen54/CCCostMonitor.git
cd CCCostMonitor
bash setup_signing.sh   # optional, one-time — see below
bash build.sh
open build/CCCostMonitor.app
```

> If `swiftc` complains about `redefinition of module 'SwiftBridging'`, run `bash fix_swift.sh`.

> **`setup_signing.sh`** (optional, run once) creates a stable self-signed code-signing
> identity. `build.sh` then signs every build with it, so the macOS Keychain *Always Allow*
> grant for the OAuth token survives rebuilds. Without it the build falls back to ad-hoc
> signing, whose identity changes each build — you'd have to re-authorize Keychain access
> (and the Subscription tab would keep vanishing) after every rebuild.

### How it works

The app shells out to a bundled Python script that scans `~/.claude/projects/**/*.jsonl`, parses token usage from each session, and returns structured JSON. Pricing comes from [LiteLLM](https://github.com/BerriAI/litellm) (cached 24h).

```
~/.claude/projects/**/*.jsonl
    → analyze_usage.py --json
    → SwiftUI popover
```

The **Subscription** tab is separate: it calls Anthropic's OAuth usage endpoint directly (no local logs involved). The access token is read from `~/.claude/.credentials.json` or — the default on macOS — the login **Keychain** (`Claude Code-credentials`). macOS may prompt for Keychain access on first use; choose *Always Allow*. API-key users (Bedrock / Vertex / Console) have no subscription quota, so the tab is hidden for them.

### Project structure

Single-file Swift app. No Xcode, no SPM. Just `swiftc`.

```
Sources/main.swift      ← everything
build.sh                ← compile + bundle + DMG
setup_signing.sh        ← one-time stable self-signed signing identity
generate_icon.swift     ← ASCII-art app icon generator
Info.plist              ← LSUIElement=true
```

### On pricing accuracy

Costs are estimates based on public API pricing. If you're on a subscription plan (Pro / Max / Team), actual billing works differently — treat the numbers as a rough guide.

Token counts match [ccusage](https://github.com/ryoppippi/ccusage) within ~0.5%.

---

## 中文

macOS 菜单栏应用，查看 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 的用量和花费。解析本地会话日志 — 零 token 消耗，数据不会发送到任何地方。

### 为什么做这个

Claude Code 的 `/cost` 只显示当前会话。如果你有多个 Anthropic 账户、使用 API key、或通过 AWS Bedrock / GCP Vertex 接入 — 想搞清楚总花费几乎不可能。

这个应用读取所有本地会话数据，汇总到一个菜单栏图标里。

### 功能

- **费用 & Tokens** — 双视图切换，按模型分类（Opus / Sonnet / Haiku）
- **订阅剩余用量**（Pro / Max）— 独立 tab，查看 5 小时 / 7 天 / 7 天 Sonnet 窗口**还剩多少**及重置倒计时。数据来自 Anthropic 官方用量接口 —— 与 Claude Code `/usage` 同源
- **今日 / 本周 / 本月** — 按类型拆分 token（输入、输出、缓存读、缓存写）
- **每日柱状图** — 悬浮查看详情
- **月份导航** — 浏览历史月份，本地缓存
- **4 种语言** — English、简体中文、繁體中文、日本語
- **自动刷新** — 每 30 分钟 + 屏幕唤醒后刷新
- **仅菜单栏** — 无 Dock 图标，再次点击 app 可唤出弹窗

### 系统要求

- macOS 13+，Intel 或 Apple Silicon
- Python 3
- Claude Code 会话数据位于 `~/.claude/projects/`

### 安装

#### 下载 DMG

从 [Releases](../../releases) 下载 `CCCostMonitor.dmg`，拖入 Applications。

首次启动：右键 → 打开（绕过未签名应用的 Gatekeeper 检查）。

#### 从源码构建

```bash
git clone https://github.com/kuen54/CCCostMonitor.git
cd CCCostMonitor
bash setup_signing.sh   # 可选，一次性 — 见下方说明
bash build.sh
open build/CCCostMonitor.app
```

> 如果 `swiftc` 报错 `redefinition of module 'SwiftBridging'`，运行 `bash fix_swift.sh`。

> **`setup_signing.sh`**（可选，跑一次即可）会生成一个稳定的自签名代码签名证书。之后
> `build.sh` 每次都用它签名，这样 macOS 钥匙串对 OAuth token 的*始终允许*授权就能在重新
> 构建后依然有效。不跑它则回退到 ad-hoc 签名，其身份每次构建都变 —— 每次重新构建后你都得
> 重新授权钥匙串（且订阅 tab 会反复消失）。

### 工作原理

应用调用内置的 Python 脚本扫描 `~/.claude/projects/**/*.jsonl`，解析每个会话的 token 用量，返回结构化 JSON。定价数据来自 [LiteLLM](https://github.com/BerriAI/litellm)（缓存 24 小时）。

```
~/.claude/projects/**/*.jsonl
    → analyze_usage.py --json
    → SwiftUI 弹窗
```

**订阅** tab 走的是另一条路：直接调用 Anthropic 的 OAuth 用量接口（不读本地日志）。访问 token 从 `~/.claude/.credentials.json` 读取，或——在 macOS 上的默认情况——从登录**钥匙串**（`Claude Code-credentials`）读取。首次使用时 macOS 可能弹出钥匙串授权框，请选择*始终允许*。API-key 用户（Bedrock / Vertex / Console）没有订阅限额，该 tab 对他们隐藏。

### 项目结构

单文件 Swift 应用，不依赖 Xcode 或 SPM，直接用 `swiftc` 编译。

```
Sources/main.swift      ← 全部源码
build.sh                ← 编译 + 打包 + DMG
setup_signing.sh        ← 一次性生成稳定自签名证书
generate_icon.swift     ← ASCII art 风格图标生成器
Info.plist              ← LSUIElement=true
```

### 关于费用准确性

费用基于公开 API 定价估算。如果你使用订阅计划（Pro / Max / Team），实际计费方式不同 — 数字仅供参考。

Token 计数与 [ccusage](https://github.com/ryoppippi/ccusage) 误差在 ~0.5% 以内。

---

## License

[Apache 2.0](LICENSE)
