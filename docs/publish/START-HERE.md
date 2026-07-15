# 发布顺序

先打开 `rousepet-xhs-publish-guide.html`。里面已经集中放好 RousePet 的简介、详细功能、使用方法、标题、正文、标签、7 张图片预览和每张图片的绝对路径。

1. GitHub：把 `v1.1.1` 代码推到 `main`，创建 Release，并上传 RousePet RedSkill ZIP 与 SHA-256 文件。
2. 小红书：依次上传 `xiaohongshu/01.png` 到 `07.png`。
3. 使用 `xiaohongshu-post.md` 的推荐标题和正文，人工检查一次真实表述。
4. 在笔记下方挂载 `rousepet-redskill-v1.1.1.zip`，不要把 GitHub URL 放进正文。
5. 选择“原创”，精确添加 `#REDSkill`；图组由本地 HTML/CSS 和真实宠物截图生成，如平台要求则勾选“含 AI 合成内容”。
6. 公开、立即、人工发布，不使用定时发布或自动化脚本。
7. 发布后用另一个 Codex 环境按 `redskill-upload-checklist.md` 完成获取和安装验证。

推荐先发小红书，再把笔记链接补进 GitHub Release 或仓库主页；正文不做站外导流。
