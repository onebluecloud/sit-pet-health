# RousePet v1.1.1

RousePet 让用户已有的 Codex 宠物替他们记住起身：连续久坐时逐级没精神，真正离开电脑后恢复，Codex 接手任务时则提醒用户利用空窗活动。

这是 RedSkill 上传兼容修订。平台会过滤 `.yaml` 和无扩展名文件，本版将 Codex UI 元数据保存为 `.yaml.txt` 载体、将许可证保存为 `.txt`，安装时自动还原标准结构，不需要用户手工改文件。

## 本版变化

- 修复上传后显示“过滤了不支持的格式”的问题。
- 保证 MIT 许可证在平台解析后仍被保留。
- 安装器自动还原 `agents/openai.yaml`。
- 核心健康逻辑、官方宠物只读边界和界面行为不变。

## 安全边界

- `CODEX_HOME/pets` 与 `~/.codex/pets` 始终只读。
- 健康状态、复制体和自定义宠物只写入 Plugin 私有目录。
- 不读取或保存任务正文，不向网络上传宠物与健康数据。
- 不安装 EXE；最差状态是可逆休息，不是死亡或医疗指标。

## Release 附件

- `rousepet-redskill-v1.1.1.zip`
- `rousepet-redskill-v1.1.1.zip.sha256`

安装提示词：

> 安装并立即显示 RousePet，保持我的官方 Codex 宠物完全不变。
