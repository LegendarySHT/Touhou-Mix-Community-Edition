## CI 发布链路试跑

- 新增 GitHub Actions 一键发布：三平台并行导出后进入草稿 Release，校验通过才转正
- 发布前自动校验 build 递增、tag 冲突与签名身份，任一不满足即中止
- 正式发布不再需要本机安装 Godot 与 Android SDK

<!--
本次为「发布链路试跑」（mode=draft-only），草稿不会转正，线上不可见。
试跑通过后请把本文件改回模板内容。
-->
