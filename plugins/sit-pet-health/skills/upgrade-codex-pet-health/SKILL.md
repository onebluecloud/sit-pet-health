---
name: upgrade-codex-pet-health
description: 安装、启动、检查、换宠物或卸载无 EXE 的 Codex 宠物健康升级器；只读复制本地 /hatch 宠物，由 Codex Plugin Hooks 根据键鼠空闲推断离开电脑、监测久坐阶段和 Codex 任务空窗。也用于用户说“把我的 Codex 宠物放到桌面”“久坐提醒”“宠物健康版”“宠物没出现/没回血/没提醒”或要求用 prompt/图片先创建宠物再升级时。Windows 为正式支持，macOS 为实验性支持；不用于修改、覆盖或修复官方宠物原文件，也不把元气解释为真实寿命或医疗指标。
---

# Codex 宠物健康升级器

## 原则

- 把 `$CODEX_HOME/pets` 或 `~/.codex/pets` 当作只读输入。
- 复制体、扩展图集、健康状态和配置只能写入 `CLAUDE_PLUGIN_DATA`（Codex 当前的插件持久化目录变量）。
- 不安装或下载 EXE；Windows 只运行 PowerShell/WPF，macOS 只运行 JXA/AppKit。
- 不读取或保存任务正文。Hooks 只传递开始、等待和结束事件。
- 不提供“我动过了”。键鼠空闲 1 分钟开始部分恢复；连续空闲达到阈值后，等键鼠重新出现才确认一次离开电脑并完整恢复。
- 最差状态是可逆的休息/罢工，不生成死亡画面，不声称元气对应寿命。

## 首次启动

1. 确认平台为 Windows 或 macOS；其他平台明确说明尚不支持桌面浮窗。
2. 找出宠物根：优先 `$CODEX_HOME/pets`，否则 `~/.codex/pets`。
3. 首次 Hook 为保证安装后立即出现，会先显示最近更新的一只合法宠物；若检测到多只，桌面设置选择器会自动打开，让用户明确选择。选择只写入插件私有配置，不修改任何候选宠物。
4. 每次 `SessionStart` 只比较源宠物与私有复制体的 SHA-256；未变化直接复用，`/hatch` 更新后才重建私有扩展图集并热切换窗口。
5. Windows 运行：

   ```powershell
   PowerShell -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\scripts\prepare-pet-windows.ps1" -PluginData "$env:CLAUDE_PLUGIN_DATA" -SourcePet "<slug>"
   ```

6. macOS 运行：

   ```bash
   /bin/zsh "$CLAUDE_PLUGIN_ROOT/scripts/prepare-pet-macos.sh" "$CLAUDE_PLUGIN_DATA" "<slug>"
   ```

7. 告知用户 Codex 会要求审核一次插件 Hooks。该信任步骤是官方安全机制，不能绕过。
8. 让 `SessionStart` Hook 启动窗口；调试时可直接运行对应 `runtime-*` 脚本。安装动作发生在当前任务时不要等下一次会话，必须直接运行启动助手并检查其 JSON 结果中的 `ok`。
9. 安装动作发生在当前会话且用户要求立即显示时，运行 `scripts/launch-windows.ps1` 或 `scripts/launch-macos.sh`；未来会话仍必须经过 Codex 的 Hooks 信任审核。

复制体必须包含源图集 SHA-256、五阶段 atlas strip、庆祝 atlas 和 `health-profile.json`。标准 Codex 图集按 `assets/action-layouts.json` 的语义动作映射；自定义宠物可以在私有 manifest 提供 `sitPetHealthActions`，缺少 tired/sick/rest 等动作时按 fallback 链退回 waiting/idle，不伪造新表情。建立前后都校验源文件 SHA-256；不一致立即停止。

## 运行语义

| 连续活跃久坐 | 状态 | 表现 |
|---|---|---|
| 0-30 分钟 | 精神 | 原宠物 idle |
| 30-60 分钟 | 发懒 | 原宠物 waiting 慢放 |
| 60-90 分钟 | 蔫了 | 原宠物 tired；没有则回退 waiting/idle |
| 90-120 分钟 | 病恹恹 | 原宠物 sick；没有则回退 tired/waiting/idle |
| 120 分钟以上 | 罢工 | 原宠物 rest；没有则原地休息，可逆 |

- idle 1-5 分钟期间逐步回退久坐时间。
- idle 达 5 分钟时恢复到精神并播放 jumping/庆祝动作。
- 锁屏和睡眠只暂停，不算久坐，也不伪造起身奖励。
- Codex 开始任务且用户已久坐时，宠物提示用户利用空窗活动。
- 用户随后连续离开键鼠 5 分钟并返回，记录一次“听劝”并给明显庆祝。
- Codex 结束而用户仍未离开时，最多再提醒一次；每小时总提醒受预算限制。

## 台词

运行期不调用 LLM。用户可在设置选择损友、温柔或冷幽默；按以下上下文从本地模板组合，并避免连续重复：

- 宠物显示名。
- 当前逻辑久坐分钟和阶段。
- 今天完整起身次数、听劝次数、连续听劝。
- 当前是阶段到达、Codex 接手、Codex 完成还是恢复。
- 最近一小时已提醒次数。
- 当前宠物的只读图集哈希（只用于稳定区分宠物，不上传）。

语气要像熟悉用户的损友，不训诫、不使用医疗诊断或寿命话术。

## 检查

需要诊断时读取 `CLAUDE_PLUGIN_DATA` 下这些文件，不读取官方宠物之外的 Codex 数据：

- `current-pet.json`
- `health-state.json`
- `config.json`
- `logs/runtime.log`
- `runtime.pid`
- `last-error.json`

Windows 优先直接运行只读诊断，不要求用户自己翻文件：

```powershell
PowerShell -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\scripts\diagnose-windows.ps1" -PluginData "$env:CLAUDE_PLUGIN_DATA"
```

检查源宠物 SHA-256 是否仍等于 `health-profile.json` 的 `sourceSpriteSha256`。不要用修复动作写回源宠物。

## 换宠物与卸载

- 换宠物：优先让用户从右键“宠物与提醒设置”选择；命令行可带新的 `-SourcePet` 重新运行准备脚本。旧复制体留在 `CLAUDE_PLUGIN_DATA/pets`，直到明确清理。
- 设置：右键可调整宠物、尺寸、离开电脑灵敏度、久坐阶段节奏、提醒语气和安静时段；保存后运行时自动重启应用。
- 暂停：右键可暂停一小时、暂停到当天结束或恢复；兼容旧 `pause.flag`，新状态写入插件私有 `pause.json`，不要改 Codex 配置。
- 分享：右键生成 1080×1350 今日分享卡，输出到插件私有 `share` 目录；卡片明确元气不是寿命/医疗指标。
- 卸载：先运行 `scripts/uninstall-windows.ps1` 或 `scripts/uninstall-macos.sh`，由脚本校验进程命令行和私有数据目录后结束窗口、删除 `CLAUDE_PLUGIN_DATA`；再用 `codex plugin remove` 删除对应 marketplace 的插件。不要删除 `~/.codex/pets` 中任何目录。
- 用户要求用一句 prompt 或图片创建新宠物时，先读取 `CLAUDE_PLUGIN_ROOT/vendor/hatch-pet/SKILL.md`，并把其中的 `SKILL_DIR` 视为 `CLAUDE_PLUGIN_ROOT/vendor/hatch-pet`。按该流程生成和质检，但最终打包必须显式传入 `--package-dir CLAUDE_PLUGIN_DATA/custom-sources/<slug>`，不得使用它默认的 Codex `pets` 输出目录。完成后 Windows 用 `prepare-pet-windows.ps1 -SourceDirectory <目录>`，macOS 用 `prepare-pet-macos.sh "$CLAUDE_PLUGIN_DATA" "" <目录>` 建立健康复制体；已有官方宠物仍不改、不删、不覆盖。
