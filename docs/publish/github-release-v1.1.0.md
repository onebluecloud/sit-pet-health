# RousePet v1.1.0

RousePet 让用户已有的 Codex 宠物替他们记住起身：连续久坐时逐级没精神，真正离开电脑后恢复，Codex 接手任务时则提醒用户利用空窗活动。

这是采用正式品牌名后的自包含 RedSkill 版本。Skill、Codex Plugin、Hooks 和本地运行脚本都在同一个压缩包中，用户从小红书获取后即可让 Codex 本地安装，不需要跳转 GitHub，也不安装独立 EXE。

## 本版变化

- 对外品牌与界面统一为 RousePet。
- 根级 RedSkill 入口与安装指令。
- Windows/macOS 本地 marketplace 安装器。
- 安装完成后立即启动桌宠。
- 无官方宠物时进入一句描述或参考图创建流程。
- RedSkill 发布检查单和小红书发布文案。

## 安全边界

- `CODEX_HOME/pets` 与 `~/.codex/pets` 始终只读。
- 健康状态、复制体和自定义宠物只写入 Plugin 私有目录。
- 不读取或保存任务正文，不向网络上传宠物与健康数据。
- 不安装 EXE；最差状态是可逆休息，不是死亡或医疗指标。

## 平台

- Windows 10/11：正式支持。
- macOS：实验性支持，尚未完成真机 UI 全量验收。
- Linux：暂无桌面浮窗。

## Release 附件

- `rousepet-redskill-v1.1.0.zip`
- `rousepet-redskill-v1.1.0.zip.sha256`

安装提示词：

> 安装并立即显示 RousePet，保持我的官方 Codex 宠物完全不变。
