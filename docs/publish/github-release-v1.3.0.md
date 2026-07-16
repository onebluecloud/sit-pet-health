# RousePet v1.3.0

这是面向 RedSkill 重新整理的审核版本。产品健康逻辑和桌宠体验不变，重点收紧安装权限、上传包结构和平台边界。

## 审核改进

- ZIP 顶层固定为 `rousepet/`，与根 Skill 的 `name: rousepet` 一致。
- 仅包含 `.json`、`.md`、`.ps1`、`.py`、`.txt`；不再使用 YAML 文本载体，也不会在安装后恢复被上传平台过滤的文件。
- 安装前必须逐项披露官方宠物只读访问、私有数据、系统空闲秒数、Codex 生命周期 Hooks、桌面常驻窗口与卸载范围，并获得用户明确同意。
- 删除发布包中的 macOS 实验文件和直接 OpenAI API fallback；RedSkill v1.3.0 仅支持 Windows 10/11。
- 发布包内安装器和运行脚本不覆盖 PowerShell 执行策略。
- 升级前校验 RousePet 所有权记录，拒绝替换来源不明的同名目录。

## 保持不变

- 官方 `/hatch` 宠物只读，RousePet 的健康数据和补齐动作只写入 Plugin 私有目录。
- 五阶段久坐反馈、真实离开电脑判定、Codex 任务空窗提醒、拖动、无级缩放和本地设置继续保留。
- 不安装独立 EXE，运行期不联网、不调用 LLM、不读取 Codex 会话正文。

## 附件

- `rousepet-redskill-v1.3.0.zip`
- `rousepet-redskill-v1.3.0.zip.sha256`

上传解析结果必须显示 42 个文件且没有“不支持格式已过滤”提示。安装时先阅读权限说明，明确同意后再继续。
