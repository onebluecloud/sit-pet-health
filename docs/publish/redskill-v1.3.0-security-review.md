# RousePet RedSkill v1.3.0 安全复核

## 对照结论

本版按已通过审核的 Book to Comic 包结构重新整理：使用单一稳定顶层目录、Skill 名与目录名一致、只提交平台可直接读取的普通源码文件，不依赖上传后恢复隐藏或被过滤格式。

Book to Comic 是执行后退出的前台任务；RousePet 必须常驻显示桌宠，因此不能照搬其运行模型。v1.3.0 对这项额外风险采用“安装前完整披露 + 用户明确同意 + 本地限定 + 可退出 + 不开机启动”的边界，而不是隐藏常驻行为。

## 包结构

- 顶层目录：`rousepet/`
- 根 Skill：`rousepet/SKILL.md`
- frontmatter：`name: rousepet`
- 文件数：42
- 文件类型：6 JSON、6 Markdown、10 PowerShell、15 Python、5 TXT
- 不含：隐藏目录、YAML/YML、SH、JS、无扩展名文件、路径穿越、符号链接、EXE、DLL、模型文件

## 权限与数据

- 官方宠物目录只读，不写入、删除或覆盖。
- Windows idle 只读取距上次键鼠输入的秒数，不记录输入内容或坐标。
- Hooks 只保存事件名、时间和会话 ID 短哈希，不保存 prompt、回复或仓库内容。
- 运行期不联网、不调用 OpenAI API、不下载代码或可执行文件。
- 不设置开机启动、计划任务、系统服务或注册表启动项。
- 卸载与升级只处理经过固定路径和所有权记录校验的 RousePet 数据。

## 自动验证

- 未确认权限时安装器拒绝执行。
- 确认权限后，本地 marketplace 与 Plugin manifest 可由可见 JSON 模板创建。
- 重复安装成功；无 RousePet 所有权记录的同名目录拒绝覆盖。
- 健康引擎 JS/PowerShell、健康动作补齐 Python、Windows 生命周期、宠物准备和 UI 资产测试全部通过。
- ZIP 解压后仍为 42 个文件，未检出不支持格式、过滤恢复逻辑、执行策略覆盖或直接网络客户端。

## 已知限制

- RedSkill v1.3.0 只支持 Windows 10/11。
- 桌宠依赖本地 PowerShell/WPF 常驻进程；用户退出桌宠或卸载 Plugin 后停止。
- 若系统 PowerShell 策略阻止本地脚本，安装会如实失败，不尝试绕过策略。
- 元气是互动值，不代表真实寿命，也不构成医疗建议。
