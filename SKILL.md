---
name: install-sit-pet-health
description: 从当前 RedSkill 包离线安装、启动、检查或卸载 RousePet。用于用户说“安装 RousePet”“把 Codex 宠物放到桌面”“开启久坐提醒”“宠物没出现”或“卸载 RousePet”时；安装只使用包内 Plugin，不访问 GitHub，不修改官方宠物和 Codex 会话数据。Windows 正式支持，macOS 实验性支持。
---

# 安装 RousePet

## 数据边界

- 把 `CODEX_HOME/pets` 或 `~/.codex/pets` 作为只读输入。
- 所有复制体、配置和健康数据只写入 Codex Plugin 私有数据目录。
- 不下载或安装 EXE，不读取任务正文，不写入官方宠物目录。
- 最差状态是可逆休息，不把元气解释为寿命或医疗指标。

## 首次安装

1. 将包含本文件的目录作为 `PACKAGE_ROOT`。不要从 GitHub 或其他站点重新下载项目。
   包内 `openai.yaml.txt` 是 RED Skill 上传兼容载体，安装器会在本地自动还原为 `openai.yaml`；不要要求用户手工改名。
2. Windows 运行：

   ```powershell
   PowerShell -ExecutionPolicy Bypass -File "<PACKAGE_ROOT>\scripts\install-redskill-windows.ps1" -PackageRoot "<PACKAGE_ROOT>"
   ```

3. macOS 运行：

   ```bash
   /bin/zsh "<PACKAGE_ROOT>/scripts/install-redskill-macos.sh" "<PACKAGE_ROOT>"
   ```

4. 检查安装器返回的 JSON。只有 `ok=true` 且 `installedPath` 存在时才算安装完成。
5. 安装器会立即启动桌宠。若本地没有官方 `/hatch` 宠物，桌面会显示创建入口；询问用户一句宠物描述或一张参考图片，再使用已安装 Plugin 内的 `upgrade-codex-pet-health` Skill 完成私有创建。
6. 告知用户未来 Codex 会话第一次触发 Hooks 时会出现官方信任审核；这是安全边界，不能绕过。

## 后续操作

- 安装完成后，改宠物、诊断、久坐提醒、创建自定义宠物和卸载都交给已安装 Plugin 内的 `upgrade-codex-pet-health` Skill。
- 右键宠物可打开设置、暂停提醒、换宠物和生成分享卡。
- 不提供常驻“我动过了”按钮；系统根据键鼠连续空闲和返回自动确认起身。

## 失败处理

- `codex` 命令不存在：明确说明需要 Codex Desktop/CLI，停止安装。
- Plugin 安装成功但窗口没出现：运行已安装目录内的 `scripts/diagnose-windows.ps1`，不要修改官方宠物。
- Linux：明确说明当前没有桌面浮窗，不执行 Windows 或 macOS 脚本。
