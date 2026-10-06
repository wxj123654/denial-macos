# Flutter 引擎迁移 TODO

建立日期：2026-10-04。状态：迁移进行中，当前运行及正式 source lock 仍为 3.44.7。

目标：把 Denial 的 Flutter framework、tool、Dart、embedder 引擎和 Skia
一起迁移到执行时的最新 stable，并保留 compositor、玻璃及局部重绘契约。
截至建立日期，官方 [stable 更新日志](https://github.com/flutter/flutter/blob/stable/CHANGELOG.md)
最新列出 **3.47.6**，以此作为候选；开始实施时重新核对并冻结精确提交。
升级后的抗锯齿效果必须独立验证，不能仅凭版本号判定修复。

## 已确认的起点

- [x] 当前 upstream compatibility base：Flutter 3.44.7，Dart 3.12.2。
- [x] 当前锁定 Flutter fork：`d0817320163b3fb5a284e63cc21f2d6b9138442b`。
- [x] 当前锁定 Skia fork：`0ee042f542b3e79f5ac49115387718c6bb3d7d34`。
- [x] 3.44.7 的 GLES root MSAA 实验已完成独立构建及 4 个无窗口回归测试；
  用户反馈切回原引擎后再次出现锯齿。实验尚未锁定或发布，性能验收未完成。
  依据见 [MSAA 实验记录](../research/gles-root-msaa-2026-10-04.md)。

## 1. 冻结目标与迁移基线

- [ ] 核对官方 stable tag，记录完整 Flutter commit、engine compatibility
  revision、Dart 版本、DEPS 指定的 Skia 和构建依赖 revision。
  将最终输入及验证结果记录到对应版本的 `VALIDATION.md`。
- [ ] 保留现有玻璃布局改动，准备迁移分支，保存已知正常的旧引擎及完整 shell
  bundle，记录哈希及回滚入口。
- [ ] 逐项审计 Flutter、Skia fork 相对旧 upstream 的提交，建立
  “已被上游覆盖／需要移植／需要重新实现”的清单，并为每项关联验证。
- [ ] 在可编辑源目录建立新版 fork 分支；只提交普通 fork commits，不在
  Denial 仓库增加 patch series。提交身份使用
  `Doctor Logix <doctor.logix@gmail.com>`。

本机可编辑源目录为 `/home/wxj/document/denial-engine-sources/flutter` 和
`/home/wxj/document/denial-engine-sources/skia`，使用时必须同时设置
`DENIAL_FLUTTER_SOURCE_ROOT`、`DENIAL_SKIA_SOURCE_ROOT`。
缓存中的 detached source projection 不作为编辑对象。

### 当前执行记录

- [x] 冻结官方 stable 3.47.6：`5fc346839b5d0eef006ed8404392afb4dfae428d`。
  `engine.version` 为 `692136cb6582dbfc5af3fb33c2515a069f2f66d0`，
  Dart DEPS revision 为 `04bcd1036cdc799ac6564988f159ee454d42c822`。
- [x] Flutter 已建立 `codex/flutter-3.47.6` 迁移分支，累计旧改动三方合并，
  接口冲突正在处理；旧 MSAA 实验分支保留。
- [x] Skia 三个定制提交已移植且 clean：upstream
  `8df24be66531469e576a806749a0202ae26b8d08`，fork
  `0b41f940531a4fa4380f794275e7fe1b0119afa0`。
  四个受影响翻译单元仍待新版引擎编译验证。
- [ ] 完成新版依赖同步、源码提交、隔离 release 构建及汇总验证。

## 2. 移植 Denial 的引擎契约

- [ ] 移植 compositor-owned FBO 的能力描述、纹理包装、stencil、生命周期
  及 Skia 路径，保证描述与真实附件一致。
- [ ] 移植 negative render views、输出变换、persistent FBO 局部更新和 damage
  语义；确认未损伤区域、透明区域及 backdrop 输入能够保留。
- [ ] 移植 external texture 更新、帧调度、缓存及资源释放契约，核对 Rust 侧
  使用的 Denial 扩展导出和 embedder ABI。
- [ ] 核对自定义 shader/filter、framework 与 Flutter tool 改动；验证 shader
  输入尺寸、`FlutterFragCoord()`、玻璃采样坐标及 coverage inset。
- [ ] 审计 3.47 的 SDF 圆角路径及 Y 方向处理变更如何到达 Denial 的自定义
  embedder，不能直接套用官方 Linux runner 的启用结果。
  参照 [3.47 release notes](https://docs.flutter.dev/release/release-notes/release-notes-3.47.0)。

## 3. 抗锯齿与性能

- [ ] 优先验证新版 SDF 路径是否覆盖普通药丸、开关及圆角矩形，并核对 clip、
  变换、透明度及 backdrop 场景；确认仍需 MSAA 的几何类型。
- [ ] 根据结果决定保留、调整或移除 `cae32eb60bb4571f32fb6139f2fb92c648d3f80d`
  的 root MSAA 实验，避免无依据地给所有输出永久开启全屏 4x MSAA。
- [ ] 移植或调整 4 个无窗口回归测试：实际几何 pipeline 的抗锯齿设置、局部
  重绘初始化、backdrop 与未标记 root 的行为；增加迁移发现的契约回归。
- [ ] 核对缺少 implicit-MSAA 扩展时的 GLES explicit resolve 路径。
- [ ] 在相同输出尺寸、DPR 和用户操作场景下记录帧时间、GPU 内存及局部更新
  开销，与旧引擎和 MSAA 实验比较，记录选择依据。

## 4. 配套构建与隔离试运行

- [ ] 审计构建工具中旧 Flutter/Dart、GN 参数、target 名称、artifact revision
  及路径假设，适配新版工具链；交互机器编译至少留出 1–2 个逻辑 CPU。
- [ ] 先构建 release 实验引擎，再用同版本 framework/Dart 重建 AOT、shader
  及 assets，组成独立、只读且按 revision 标识的完整测试 bundle。
- [ ] 确认或扩展跨版本 `engine-test-build/check/arm` 流程：现有流程复制旧的
  known-good bundle，不能把旧版 AOT 与新版 Dart VM 的组合当作升级验证。
  试验输入单独记录，验收前保留正式 `SOURCE_LOCK.json`。
- [ ] 检查实验 bundle 的 ABI、AOT、ICU、所需导出及依赖，保持一次登录生效、
  后续登录自动回到已知正常版本的机制。
- [ ] 请用户自行注销并登录测试会话；收到登录确认后核对新 `deniald`、映射的
  引擎路径、bundle 哈希、renderer 及服务健康。禁止覆盖运行中映射的库。

## 5. 验证与用户验收

- [ ] 运行相关引擎无窗口测试及 Rust 契约测试。
- [ ] 使用与候选引擎匹配的隔离测试配置，经 `tools/denial-pc flutter-test`
  运行 liquid-glass、gallery 的 Impeller 测试，核对 banner 的 340×62 布局。
  修改 included GLSL 后先 touch 对应入口 `.frag`，再编译 shader/bundle。
- [ ] 用户检查普通控件锯齿、banner/dock 圆角、玻璃采样方向及窗口底边对齐。
- [ ] 用户检查缩放、旋转、多输出、窗口移动/缩放、局部重绘和 backdrop 场景；
  agent 只核对日志及运行数据。所有视觉验证由用户完成，不截图、不代开应用，
  不自行触发通知或其他可见测试事件。
- [ ] 用户确认候选可接受，记录性能数据及遗留问题；不通过时使用旧完整 bundle
  回滚，并保留候选和失败证据。

## 6. 正式锁定及发布验证

- [ ] 验收后提交 Flutter、Skia fork 改动，确认精确 commits 已存在于 fork remote，
  再更新 `prebuilt/flutter-engine/SOURCE_LOCK.json`。
- [ ] 更新兼容版本元数据，运行一次
  `tools/denial-flutter-engine refresh-metadata`，同步生成所有模式的 GN 参数、
  校验和及工件；禁止逐模式修补预期 checksum。
- [ ] 运行 `tools/generate-flutter-embedder-bindings` 及其 `--check`，核对提交的
  Rust ABI、header SHA-256 和对应 revision。
- [ ] 刷新 `packaging/arch/flutter-engine/manifest.json` 与
  `packaging/arch/ui-development/manifest.json`；更新 Nix engine/pub locks、
  许可证和源目录/版本文档。缺少 Nix 时在具备 Nix 的主机完成两个 lock 刷新。
- [ ] 经 `tools/denial-pc bootstrap/doctor/build/test` 完成正式锁定构建验证，运行
  `tools/denial-release source-audit --branch dev`，验证打包与已锁定输入一致。
- [ ] trusted changes 先落 `dev`，推送前 arm ephemeral builder，验证 exact commit；
  通过保持 validated dev tree 的 merge-commit PR 晋升到 `main`。
- [ ] `main` 独立构建并验证 production、version-neutral candidate；发布时才选择
  并签署版本 tag，由 tag workflow 晋升保留 payload，不重新编译。

完成条件：精确源锁、配套 bundle、ABI、全模式元数据、测试及用户验收都有证据，
`dev` 构建验证通过，且旧版本回滚可用。发布步骤仅在本次迁移需要发布时执行。
