---
name: upgrade-codex-pet-health
description: 启动、检查、换宠物或卸载无 EXE 的 RousePet；只读复制本地 /hatch 宠物，由 Codex Plugin Hooks 根据键鼠空闲推断离开电脑、监测久坐阶段和 Codex 任务空窗。也用于用户说“把我的 Codex 宠物放到桌面”“久坐提醒”“宠物没出现/没回血/没提醒”或要求用 prompt/图片先创建宠物时。Windows 为正式支持；macOS 仅 GitHub 完整版实验支持，RedSkill 包不包含 macOS 运行文件。不用于修改、覆盖或修复官方宠物原文件，也不把元气解释为真实寿命或医疗指标。
---

# RousePet

## 原则

- 把 `$CODEX_HOME/pets` 或 `~/.codex/pets` 当作只读输入。
- 复制体、扩展图集、健康状态和配置只能写入 `CLAUDE_PLUGIN_DATA`（Codex 当前的插件持久化目录变量）。
- 不安装或下载 EXE；Windows 只运行 PowerShell/WPF。只有当前安装目录确实包含 macOS 脚本时，才可把 macOS 视为实验性支持。
- 不读取或保存任务正文。Hooks 只传递开始、等待和结束事件。
- 不提供“我动过了”。键鼠空闲 1 分钟开始部分恢复；连续空闲达到阈值后，等键鼠重新出现才确认一次离开电脑并完整恢复。
- 最差状态是可逆的休息/罢工，不生成死亡画面，不声称元气对应寿命。

## 首次启动

1. 确认平台和安装内容。Windows 可继续；macOS 只有安装目录存在 `scripts/launch-macos.sh` 时才可继续，否则明确说明当前 RedSkill 包不支持；其他平台明确说明尚不支持桌面浮窗。
2. 找出宠物根：优先 `$CODEX_HOME/pets`，否则 `~/.codex/pets`。如果没有合法宠物，不要把用户丢给空选择器，也不要只让用户自行运行 `/hatch`；主动询问一句宠物描述或一张参考图片，然后立即执行本文件末尾的私有自定义宠物流程。
3. 首次 Hook 为保证安装后立即出现，会先显示最近更新的一只合法宠物；若检测到多只，桌面设置选择器会自动打开，让用户明确选择。若一只也没有，Hook 会打开明确的空状态并向当前 Codex 任务注入创建指引；收到用户描述或图片后，完成生成、质检、私有打包、准备和启动，再结束当前任务。选择只写入插件私有配置，不修改任何候选宠物。
4. 每次 `SessionStart` 只比较源宠物与私有复制体的 SHA-256；未变化直接复用，`/hatch` 更新后才重建私有扩展图集并热切换窗口。
5. Windows 运行：

   ```powershell
   & "$env:CLAUDE_PLUGIN_ROOT\scripts\prepare-pet-windows.ps1" -PluginData "$env:CLAUDE_PLUGIN_DATA" -SourcePet "<slug>"
   ```

6. 告知用户 Codex 会要求审核一次插件 Hooks。该信任步骤是官方安全机制，不能绕过。
7. 让 `SessionStart` Hook 启动窗口；调试时可直接运行对应运行脚本。安装动作发生在当前任务时不要等下一次会话，必须直接运行启动助手并检查其 JSON 结果中的 `ok`。
8. 安装动作发生在当前会话且用户要求立即显示时，Windows 运行 `scripts/launch-windows.ps1`；只有安装目录确实包含 macOS 启动脚本时才运行它。未来会话仍必须经过 Codex 的 Hooks 信任审核。

复制体必须包含源图集 SHA-256、五阶段 atlas strip、庆祝 atlas 和 `health-profile.json`。标准 Codex 图集按 `assets/action-layouts.json` 建立立即可用的回退动作；只有私有 manifest 通过 `sitPetHealthActions` 明确声明的 `tired/sick/rest` 才算专用健康动作。其他宠物必须继续执行下方的私有健康动作补齐流程。建立前后都校验源文件 SHA-256；不一致立即停止。

## 补齐私有健康动作

当准备脚本返回 `enhancementRequired=true`，宠物已经显示，但缺少独立的健康动画。继续完成以下步骤，不要求用户再次授权，不重新生成整只宠物，不写回官方图集：

1. 从准备结果读取 `cloneDirectory` 和 `enhancementActions`。只处理列出的 `tired`、`sick`、`rest`；已有专用动作不得重做。
2. 使用当前环境可用的 Python 3 运行：

   ```text
   python CLAUDE_PLUGIN_ROOT/scripts/prepare-health-extension.py --clone-dir <cloneDirectory>
   ```

   记录返回的 `run_dir`。脚本会从私有 clone 提取身份参考图、自动选择安全色键、生成六帧布局参考和三个独立提示词，不会修改官方宠物。
3. 运行 `CLAUDE_PLUGIN_ROOT/vendor/hatch-pet/scripts/pet_job_status.py --run-dir <run_dir>`。对每个 ready job，读取它的 prompt 文件并把列出的两张输入图一起交给内置 `$imagegen`：一张是当前宠物身份参考，一张是仅用于布局的六帧 guide。
4. 每个动作单独生成一条横向六帧动画。必须保持同一物种、脸、眼睛、配色、花纹、轮廓、配件和身体比例；主要用表情、姿态、眼睑、头部角度、四肢和呼吸表达。禁止蘑菇、墓碑、死亡、夸张哭泣、文字、气泡、医疗符号、背景、地面阴影、漂浮星星、分离水滴和跨格元素。
5. 只接受内置 `$imagegen` 返回的原始 `$CODEX_HOME/generated_images/.../ig_*.png`。由父任务逐个运行：

   ```text
   python CLAUDE_PLUGIN_ROOT/vendor/hatch-pet/scripts/record_imagegen_result.py --run-dir <run_dir> --job-id <tired|sick|rest> --source <ig_*.png>
   ```

   不手改 `imagegen-jobs.json`，不使用本地绘图脚本冒充生成结果。
6. 全部记录后，先运行一次下面的命令生成确定性质检和联系表。首次不带批准参数时会在联系表生成后停止，这是正常流程：

   ```text
   python CLAUDE_PLUGIN_ROOT/scripts/finalize-health-extension.py --run-dir <run_dir>
   ```

7. 用图片查看能力打开 `<run_dir>/qa/contact-sheet.png`。逐行动作确认：角色身份没有漂移；六帧完整、互不重叠；`tired` 是轻度低能量；`sick` 是明显疲惫但不卖惨；`rest` 是安稳可逆休息而非死亡。任何一项失败时，只重新生成失败动作并重新记录。
8. 视觉检查通过后原子启用：

   ```text
   python CLAUDE_PLUGIN_ROOT/scripts/finalize-health-extension.py --run-dir <run_dir> --approve-visual-identity --review-note "<具体说明身份、六帧连续性和三阶段递进均已检查>"
   ```

   脚本把新条带写入 `<cloneDirectory>/extensions/<id>/`，最后一步才更新 `health-profile.json`，并请求运行时重启。原来的回退 atlas 保留，因此中断或失败不会让宠物消失。
9. 再次运行启动助手并确认 `health-profile.json` 中 `healthExtension.status=complete`，三个阶段的 `semanticAction` 分别为 `generated-tired`、`generated-sick`、`generated-rest`。最后再次校验私有 `source-spritesheet.*` 哈希仍等于 `sourceSpriteSha256`。

如果当前 Codex 环境没有图片生成能力、Python/Pillow 不可用或生成结果始终无法通过质检，停止补齐并保留已经运行的回退动作。向用户准确说明“桌宠可用，但专用健康动作尚未生成”，不要声称五阶段新动画已经完成。

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
& "$env:CLAUDE_PLUGIN_ROOT\scripts\diagnose-windows.ps1" -PluginData "$env:CLAUDE_PLUGIN_DATA"
```

检查源宠物 SHA-256 是否仍等于 `health-profile.json` 的 `sourceSpriteSha256`。不要用修复动作写回源宠物。

## 换宠物与卸载

- 换宠物：优先让用户从右键“宠物与提醒设置”选择；命令行可带新的 `-SourcePet` 重新运行准备脚本。旧复制体留在 `CLAUDE_PLUGIN_DATA/pets`，直到明确清理。
- 设置：桌面上悬停后拖右下角或滚轮可直接调整尺寸；右键设置可切换宠物、调整离开电脑灵敏度、久坐阶段节奏、提醒语气和安静时段，保存后运行时自动重启应用。
- 暂停：右键可暂停一小时、暂停到当天结束或恢复；兼容旧 `pause.flag`，新状态写入插件私有 `pause.json`，不要改 Codex 配置。
- 分享：右键生成 1080×1350 今日分享卡，输出到插件私有 `share` 目录；卡片明确元气不是寿命/医疗指标。
- 卸载：Windows 运行 `scripts/uninstall-windows.ps1`；只有安装目录确实包含 macOS 卸载脚本时才运行它。脚本校验进程命令行和私有数据目录后结束窗口、删除 `CLAUDE_PLUGIN_DATA`；再用 `codex plugin remove` 删除对应 marketplace 的插件。不要删除 `~/.codex/pets` 中任何目录。
- 用户要求用一句 prompt 或图片创建新宠物，或首次启动没有任何宠物时，先读取 `CLAUDE_PLUGIN_ROOT/vendor/hatch-pet/SKILL.md`，并把其中的 `SKILL_DIR` 视为 `CLAUDE_PLUGIN_ROOT/vendor/hatch-pet`。按该流程生成和质检，但最终打包必须显式传入 `--package-dir CLAUDE_PLUGIN_DATA/custom-sources/<slug>`，不得使用它默认的 Codex `pets` 输出目录。完成后 Windows 用 `prepare-pet-windows.ps1 -SourceDirectory <目录>` 建立健康复制体，并立即运行启动助手确认窗口出现；已有官方宠物仍不改、不删、不覆盖。
