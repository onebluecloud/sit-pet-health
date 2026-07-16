---
name: rousepet
description: 仅在用户明确要求安装、启动、检查或卸载 RousePet 桌面宠物久坐提醒时使用；Windows 版只读使用本地 Codex /hatch 宠物，通过系统空闲时间和 Codex 生命周期事件提供五阶段久坐反馈。安装前必须逐项披露本地权限并获得用户明确确认。不用于医疗诊断，也不修改官方宠物或会话正文。
---

# RousePet

版本：1.3.0 RedSkill 审核版。

RousePet 是本地 Codex Skill + Plugin。它把用户已有的 `/hatch` 宠物只读复制到独立目录，显示为 Windows 桌面挂件，并根据连续操作、真实离开电脑和 Codex 任务空窗提供久坐提醒。

## 安装前权限确认

首次安装前，必须把下面六项完整告诉用户，并等待用户明确回复同意。不得把用户最初的“安装 RousePet”自动视为已经理解这些权限，也不得静默安装。

1. **只读宠物**：读取 `CODEX_HOME/pets` 或 `~/.codex/pets` 中的 `pet.json` 和 spritesheet；不写入、删除或覆盖官方宠物。
2. **本地私有数据**：在 Codex Plugin 私有数据目录保存宠物复制体、配置、健康状态、日志和用户主动生成的分享卡。
3. **系统空闲时间**：调用 Windows `GetLastInputInfo`，只获得“距上次键鼠输入多少秒”，不记录按键、鼠标位置或输入内容。
4. **Codex 生命周期事件**：安装 `SessionStart`、`UserPromptSubmit`、`PermissionRequest`、`Stop` Hooks，只保存事件名、时间和会话 ID 的短哈希；不读取或保存 prompt、回复、仓库文件和任务正文。
5. **桌面常驻窗口**：启动一个本地 PowerShell/WPF 进程显示桌宠；不会设置 Windows 开机启动，用户可随时从右键菜单退出。
6. **卸载范围**：卸载时只结束经命令行校验属于 RousePet 的进程，并删除 RousePet Plugin 私有数据；官方宠物目录不在删除范围内。

同时说明：Windows 10/11 已验证；RedSkill 包不提供 macOS/Linux 桌面版；运行期不联网、不调用 LLM、不下载 EXE；元气只是互动值，不是寿命或医疗指标。

只有用户在看到上述说明后明确回复“同意安装并授予这些权限”或同等清晰表述，才执行：

```powershell
& "<PACKAGE_ROOT>\scripts\install-redskill-windows.ps1" -PackageRoot "<PACKAGE_ROOT>" -AcknowledgePermissions
```

不要覆盖或降低系统的 PowerShell 执行策略。若系统策略阻止本地脚本，如实报告并停止。

## 安装结果

1. 解析安装器 JSON；仅当 `ok=true`、`installedPath` 存在且 `launched=true` 时，才报告已经安装并显示。
2. 安装器会从包内可见的 `metadata/*.json` 和 `plugin/` 源码创建本地 Codex marketplace，再调用 Codex 官方 Plugin CLI。它不会从 GitHub或其他地址下载代码。
3. 安装后会立即显示最近更新的一只合法宠物；有多只时打开选择器。
4. 若没有官方宠物，询问一句宠物描述或一张参考图片，再读取已安装的 `upgrade-codex-pet-health` Skill，生成到 Plugin 私有目录。不得写入官方 `pets` 目录。
5. 若返回 `enhancementRequired=true`，桌宠已使用原图集安全动作运行。继续按已安装 Skill 的私有健康动作流程，仅补齐缺失的 `tired/sick/rest`，视觉质检通过后再启用。

## 后续操作

- 启动、设置、换宠物、诊断和私有动作补齐：读取安装结果 `installedPath` 下的 `skills/upgrade-codex-pet-health/SKILL.md`。
- 暂停提醒：使用桌宠右键菜单。
- 卸载：先运行已安装 Plugin 的 `scripts/uninstall-windows.ps1` 清理自身进程和私有数据，再执行 `codex plugin remove`。只在用户明确要求卸载时执行。

## 安全边界

- 不访问网络，不下载额外代码、模型或可执行文件。
- 不读取密码、API Key、浏览器数据、剪贴板、按键内容、鼠标坐标或 Codex 对话正文。
- 不设置开机启动、计划任务、注册表启动项或系统服务。
- 不恢复被上传平台过滤的文件，不改名伪装不支持的格式。
- 不生成死亡、墓碑或不可逆状态，不给出医疗结论。
