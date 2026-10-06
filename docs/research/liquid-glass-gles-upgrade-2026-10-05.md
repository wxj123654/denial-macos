# 液态玻璃：Flutter 3.47 GLES 采样升级回归

## 症状与状态

用户确认：异常发生在桌面玻璃控件，表现为玻璃消失或变黑。
当前会话使用 Flutter 3.47.6 基线候选 fork
`2e1ce631751d94733af330b58caa90c84b7ffe95`、Dart 3.13.5；
正式 `SOURCE_LOCK.json` 仍锁定 3.44.7 fork `d0817320163b`。

**源码修复和无窗口数值回归已通过；修复后的同源候选 bundle 已在用户
明确请求后，通过进程内刷新激活，尚未完成用户视觉验收。** 没有注销或重启
本地 compositor 会话、启动可见应用、触发测试通知或截图。

## 可复现信号

初始 18 项液态玻璃 + 10 项 gallery 测试在旧、新 Vulkan/SwiftShader
`flutter_tester` 上全部通过，但没有检查融合材质的背景颜色采样。

新增 `dart_shell/test/macos/liquid_glass_blend_rendering_test.dart`：

- 实际 `MacosGlass` → `LiquidGlassBlend.surface`，340×62、圆角 22、
  负根变换、DPR 1/1.75、亮/暗 palette、有/无模糊。在恒定亮背景上
  以 CPU optics 计算中心颜色，检查材质确实读取 backdrop，而非仅绘制 tint。
- 实际双形状组件，`blend=0/48`、默认 `blur=2`、正/负根变换，
  检查 SDF 内外和只存在于 smooth union 的桥接点。
- 实际 inset 胶囊在保留层下平移/缩放后的对齐。
- 双形状材质在关闭位移时，应保留背景渐变的颜色与方向。

同一 shader 源、同一控件实现和用例：

| 对照 | 桌面材质 | 渐变采样 |
| --- | --- | --- |
| 旧 3.44.7 OpenGLES | 通过 | 通过 |
| 新 3.47.6 OpenGLES，修复前 | 失败 | 失败 |
| 新引擎 + 旧 compiler 的 shader | 仍失败 | 未用于最终判定 |
| 新引擎，仅跳过新版不需要的旧 GLES UV flip | 通过 | 通过 |

修复前可重复的数字：亮背景桌面材质中心红通道预期
`229.31 ± 4`，实测 `77`（`blurSigma` 控件输入 12，经 frost=0.5
实际预模糊为 6）；双形状背景蓝通道预期 `46.65 ± 4`，实测 `208`。

新测试使用的三份修复前 GLES runtime shader SHA-256 与运行中已部署
bundle 的 shader 完全相同，排除了误测不同 compiler 产物。

## 根因与最小修复

新版 Flutter 改变了 GLES render-to-texture 坐标约定，owned 滤镜纹理
不再需要过去的 Y 采样翻转；borrowed compositor FBO 仍有独立的方向描述。
Denial shader 的 `glassUv` 仍在所有 `IMPELLER_TARGET_OPENGLES` 场景
额外执行 `uv.y = 1.0 - uv.y`，对新版滤镜纹理造成第二次翻转。
模糊会使滤镜输入包含透明 padding，错误 UV 可落在该 padding 上，
于是只剩 tint，形成暗块或玻璃消失。

源码证据（候选 fork）：

- `engine/src/flutter/impeller/compiler/compiler.cc` 的 GLES runtime stage
  处理显式定义 `IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED`，注释指出
  该宏供 shader 区分 Flutter <=3.44 与移除 GLES flip 后的版本。
- `impeller/renderer/backend/gles/texture_gles.cc` 的 `GetYCoordScale()`
  为 borrowed FBO 返回 -1、owned texture 返回 +1；旧版按
  upload/render-to-texture 分类，render-to-texture 返回 -1。
- 上游 `impeller/fixtures/runtime_stage_filter_circle.frag` 已移除旧 GLES UV flip。

`dart_shell/shaders/glass_core.glsl` 修复：

```glsl
#if defined(IMPELLER_TARGET_OPENGLES) && !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
  uv.y = 1.0 - uv.y;
#endif
```

输出根反射的 `uRootYInverted` 处理保留，与旧 GLES API 原点修正分开。
无需改变 Flutter/Skia 源锁、引擎二进制或 embedder ABI。
编辑 included GLSL 后已 touch 三个入口 `.frag`，重新编译再验证。

## 测试通道与误判修正

新增仓库支持的无窗口 GLES 测试入口：

```sh
DENIAL_FLUTTER_TEST_BACKEND=opengles tools/denial-pc flutter-test \
  test/macos/liquid_glass_test.dart \
  test/macos/liquid_glass_blend_rendering_test.dart \
  test/macos/macos_design_gallery_test.dart
```

- 构建 lock-matched `flutter_tester_opengles`、ANGLE、SwiftShader、compiler。
- 普通 Flutter tester assets 只包含 SkSL/Vulkan；使用同源 compiler
  编译 GLES/GLES3 阶段，wrapper 在 assets build 后原子替换测试 shader。
- 独立 `_gles_test` local-engine host；不替换普通 tester、正常 bundle
  或已映射引擎。wrapper 明确选择 OpenGLES，移除 DISPLAY/WAYLAND_DISPLAY。
- GLES 专属用例在其他后端明确 skip。OpenGLES 通道用 ANGLE/SwiftShader
  pbuffer，仍不能证明硬件 persistent external FBO 的全部运行行为。
- `tools/test-denial-flutter-test-gles` 的 6 项无窗口工具测试通过，
  覆盖独立 host、阶段与 include、路径空格、headless 标记、资产安装、重入
  及 Flutter framework 自带 ink_sparkle/stretch shader 的 GLES 阶段。

原镜像测试在旧新 GLES 都因采样最终 framebuffer alpha 而误报越界：
opaque backdrop 使 alpha 无法代表玻璃覆盖。改用白色 tint 在黑底上的红通道
测 coverage，并配对像素中心行，保留原有边界/对称/AA 阈值。

双形状 field 的默认模糊在旧新引擎都有几像素 padding 偏差。
它不是本次采样升级回归：无模糊边界仍使用 2 物理像素，默认模糊仅在
距轮廓 8 逻辑像素以外检查稳定内外区域，并独立断言融合桥。
这不等于近边轮廓已修好；真实采样、材质断言不使用该宽松边界。
Vulkan reflected scene.toImage 的桌面材质/默认 blur field
有同样存在于旧版的透明 padding/coverage 限制，两项明确 GLES-only。

## 最终验证

| 模式 | 结果 |
| --- | --- |
| 新 3.47.6 OpenGLES | 33/33，通过；默认并发及重复运行通过 |
| 旧 3.44.7 OpenGLES | 33/33，通过 |
| 新/旧 Vulkan Impeller | 31 通过、2 项 GLES-only skip |
| 旧版默认 Skia fallback | 31 通过、2 项 GLES-only skip（shader 检查按支持情况返回） |
| 新/旧 OpenGLES 完整 test/macos 套件 | 112/112，通过 |
| 工具 helper 单元测试 | 6/6，通过 |

最后在 disposable candidate shader 中恢复无条件 GLES flip，两个新增采样
回归再次失败；重新应用兼容条件，整组 33 项再次通过。
`bash -n`、Dart/Shell helper LSP diagnostics、`git diff --check` 通过。
本机没有 shellcheck 命令，未将其列作验证依据；无扩展名的主工具没有配置 LSP，
由 shell 语法检查和真实旧新 GLES 入口执行覆盖。
未把仅通过的默认 Skia 测试视作 shader rendering 验证。

完整日志：`~/.cache/denial/glass-regression-20261005/`，尤其：
`final-red-without-fix.log`、`final-green-gles.log`、`final-old-gles.log`、
`final-new-vulkan.log`、`final-old-vulkan.log`。
候选测试继续使用隔离工作区、已部署候选锁及精确匹配的新 framework/debug
engine，正式源码锁未前移。运行中 PID 4300 和引擎 hash 未改变。

## 激活与用户验收

用户明确要求打包后直接刷新。核对运行中 `/proc/4300/exe --help`，当前
compositor 支持 `SIGUSR1` 进程内 bundle 刷新，不需要注销。此处并不切换
引擎版本：新旧包的 engine 与 compositor SHA-256 完全相同。

使用两份候选 canonical source-root override 和独立候选锁执行
`tools/denial-pc engine-test-build --source-lock ... --compositor ...`，重新
assemble 完整 AOT/assets；fresh disposable workspace 保证三份入口 shader
重新编译。新只读工件为：

```text
~/.cache/denial/engine-test/
  2e1ce631751d94733af330b58caa90c84b7ffe95-650b8e73e98fa4aa-457b8f961df8d5c5/
```

三份打包 shader 与通过数值回归的 GLES test assets **逐字节相同**：

| shader | SHA-256 |
| --- | --- |
| glass_refract.frag | `14bd75ccade6f7ae77beb20c740f5bc0e41d7a107567746ae445b0fd8d6dd576` |
| glass_liquid.frag | `07fe969f0370598c53064cda2cc86894bfb23d5a982121e896f370790542132c` |
| glass_metaball.frag | `02261e011254ff10b2f72967ec2d3d1f2006540ace19de92588bebc893601db9` |

`engine-test-check` 的实际 ABI/AOT 加载检查 1/1 通过。正式锁、默认 bundle
及 canonical source commits 保持不变；没有武装下一次登录。

当前 launcher 缓存原 bundle **路径**，不支持传入任意新 release bundle 路径；
直接移动 `current` 软链接也不会改变它。因此在原路径与临时软链接之间用
Linux `renameat2(RENAME_EXCHANGE)` 原子交换：原完整工件改名为
`...-3bb98ccc040f145f.pre-glass-fix`，原路径成为指向新工件的软链接。交换无
路径空窗，没有重写或截断任何文件，旧 compositor/engine 映射 inode 保留。
这是一回性候选会话适配，不代表默认 `tools/denial-pc refresh` 已支持跨版本
候选路径；不能用默认 build/refresh 覆盖候选或切回正式锁的旧引擎。

2026-10-05 12:44:04 +0800 发出 `SIGUSR1` 后：

- compositor PID 4300、启动时间、start ticks `88887` 均未变化；
- UI generation 1 → 2，operation=idle、UI error 为空；
- 日志明确记录 `refreshed Flutter bundle without restarting the compositor session`；
- 实际 asset 目录 FD 和 `libapp.so` 映射来自 `...-457b8f961df8d5c5`；
- 原 engine 映射仍来自备份工件，SHA-256 为
  `650b8e73e98fa4aa9801631ffcd1fa9de42c1cc18953b261e46419db4b405744`；
- DP-1 仍为 3840×2160 @180Hz、DPR 1.75、powered=true；
- 被动观察 GPU gfx 计数仍增长，刷新后没有 shader 编译错误。

刷新启动阶段出现一次 `MissingAuthorization` backing-store 拒绝；同样诊断
在本次刷新前的候选启动和运行中已出现。后续被动观察未重复，也没有会话
退出或 UI controller 失败。记录此已有问题，不声称运行日志完全无错误，
不将它混同为本次 shader 采样修复失败。

构建、ABI gate、激活和健康记录在
`~/.cache/denial/glass-regression-20261005/refresh-*`。原包保留完整 manifest，
可独立 `verify-bundle`。该目录的 `rollback-fixed-bundle.py` 仅在明确回滚请求
时执行，重新原子指向备份并发出 `SIGUSR1`，不会停止 compositor。
**没有执行回滚。**

用户自行验证桌面玻璃恢复、颜色/方向、模糊、移动和缩放。
不得仅凭测试或刷新成功宣称视觉问题已解决。

## 刷新后现场复查：借用 FBO 取样方向（2026-10-05 下午）

用户提供的现场照片显示：上方黄色圆在下方融合按钮里再次出现，说明玻璃取样行镜像，
不是简单的颜色范围错误。此前 `scene.toImage` 回归使用 owned 离屏 target，
覆盖不到实际负 render view 的 borrowed FBO。

新增无窗口、无截图的真实 seam：`tools/test-denial-flutter-borrowed-gles`
（`tools/flutter-borrowed-gles-probe`）。它用 surfaceless Mesa 软件 EGL、
当前 release `EngineHost`、负 render view 和非零 borrowed FBO，渲染红蓝渐变及远处标记，
再读取数值。零折射位移下，旧候选引擎在 blur=0/2 时按钮中心红通道期望 140、
实测 115；大 blur 路径正常。

根因在 Flutter fork：runtime image filter 绑定输入 sampler，但不消费 borrowed FBO 的
`GetYCoordScale() == -1`；GLES fused blur 又绕过原下采样 pass 的 Y 校正。
提交 `5e99b0e6`：borrowed 输入强制先经 TextureContents 归一化，并在共享 Gaussian
subpass 中校正；新增 `RootRenderingTest.RuntimeFiltersNormalizeBorrowedFramebufferInputs`。
新候选 `5e99b0e6...-c2ffe19b16a12d9d-ecbe957a3908aafe` 在 blur 0/2/12/30、有无前置
玻璃共 8 组数值断言通过。

此修复在引擎库中，不能通过进程内 bundle 刷新生效，需要用户注销后重新登录
`Denial (development)`。回滚用 `tools/denial-pc engine-test-cancel` 后重新登录。
视觉验收仍由用户完成。
