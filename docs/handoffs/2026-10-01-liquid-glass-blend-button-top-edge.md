# 交接：融合玻璃液态按钮上沿圆角问题（未解决）

- 日期：2026-10-01
- 分支：`macos-shell-skeleton`（上游 `origin/devin/macos-shell-skeleton`）
- 相关提交：`61d0d00` `dart_shell: add liquid-glass shaders, blend button and lab`（已推送）
- 状态：**问题在真机上仍存在，离屏测试全部通过；根源已收窄到设备侧 GLES/反射路径，未复现、未修复**

## 用户可见的症状

LiquidGlassLab（`dart_shell/lib/src/macos/design/liquid_glass_lab.dart`）里：

- "融合图形"（两个 blob 的 `LiquidGlassBlend`，blend=48，形状浮在控件中间）圆角**正常**。
- "融合玻璃"按钮（`_BlendGlassButton` → 单形状 `LiquidGlassBlend`，blend=0、roundness=1，胶囊形状**贴满控件边界**）的**上沿圆角仍不对**（顶部圆角像被削平/变小，下沿正常）。

关键结构差异：按钮的形状边缘与 `ClipRect` 裁剪框**重合**，融合图形的形状不贴边。因此"着色器场相对裁剪框有几像素纵向错位"在融合图形上不可见，在按钮上会把顶部圆角切掉。这与全部观测吻合。

## 已完成并已验证的工作（上个会话，已提交）

修复了两个本身读错行的契约测试，并新增镜像对称测试：

- 足迹测试与 rim 连续性测试原来按场景矩形行（245..413）遍历，而翻转根下按钮实际渲染在输出 287..455 行——上半圆采样的全是裁剪区外背景（扇区 count=0 → 均值 0.00）。已改为按翻转后的输出行遍历，rim 测试增加每扇区 count>0 断言。
- 新增 `blended button top and bottom contours mirror each other`（上/下沿镜像跨度 ≤3px、不越出裁剪框 ±2px、平坦边 AA 对称 <25%）。
- 验证：`tools/denial-pc flutter-test --enable-impeller test/macos/liquid_glass_test.dart` 18/18；默认（Skia 回退）18/18；`macos_design_gallery_test.dart` 8/8。

结论：**Vulkan 后端的离屏模型里轮廓是对称的**（亚像素测量也在 ±1px 方法噪声内对齐）。问题只在真机。

## 本会话调查结果（未提交，无代码变更）

### 设备事实（来自本机 `journalctl -t deniald`）

- 输出 3840×2160@180Hz，**DPR 1.75（分数缩放）**，逻辑视图 2194.29×1234.29（非整数）。
- 引擎后端 **Impeller OpenGLES**；负向 render view 直接渲染进 compositor 持有的持久 FBO（backdrop 读取留在输出目标上）。
- Xwayland 在 `:0`。

### 引擎源码调查（fork checkout：`~/.cache/denial/flutter-engine/checkout/engine/src/flutter`，只读；可编辑的正典根是 `/mnt/exty/denial-flutter-fork-3.44.7`）

1. `FlutterFragCoord()` 是 varying（`impeller/compiler/shader_lib/flutter/runtime_effect.glsl:8-26` + `impeller/entity/shaders/runtime_effect.vert:16-21`），跨后端一致：输入纹理像素空间、左上原点、无半像素偏移。→ 排除该类原因。
2. 引擎会覆写第一个 vec2 uniform 为**输入快照纹理尺寸**（`impeller/entity/contents/filters/runtime_effect_filter_contents.cc:139-156`）。
3. **重栅格化分支（重点怀疑）**：`runtime_effect_filter_contents.cc:70-126`——当输入快照 `ShouldRasterizeForRuntimeEffects()`（带缩放的变换，**含负向/反射**；或 **blur halo padding**）时，输入被重栅格化为**裁剪到 filter coverage 的纹理**：`uTextureSize` 变成 coverage 尺寸、`FlutterFragCoord` 变成 coverage 局部坐标（`contents.cc:84,109` 的 `ISize::Ceil` + `MakeTranslation(coverage origin)` 保留小数原点）。我们的着色器用的是绝对原点模型（`uOrigin` = 控件在视图里的绝对物理位置）——若走此分支会错位几百像素（玻璃应完全消失），与观测不符，说明当前 blur=0 的路径没走；**但现有离屏测试全部 blurSigma=0，而 Lab 按钮默认 optics blurSigma=2（组合内层 blur）——blur halo 可能触发此分支，未验证**。
4. GLES 采样翻转是用户着色器的责任（引擎 fixture `runtime_stage_filter_circle.frag` 的 `#ifdef IMPELLER_TARGET_OPENGLES uv.y = 1.0 - uv.y;` 模式）；我们的 `glassUv` 已处理。
5. 本 fork 的 `impeller/display_list/canvas.cc` 有大量 Denial 专属 "backdrop plan" 代码：`FlipBackdrop`（3239-3321）返回当前 pass 的完整纹理；直接求值路径 entity transform = `MakeTranslation(-GetGlobalPassPosition())`（2332-2337）；子通道 `IRect::RoundOut` 且小数原点经 `coverage_origin_adjustment` 传递（2005-2020、2143、2493）——**反射变换下设备空间原点是 `height-(y+h)`，上下沿取整行为不对称（每边最多约 1px）**；另有 **GLES 独有的 `PendingBackdropComposite` deferred fusion 路径**（2386-2406、`backdrop_surface_contents.cc`）——Vulkan tester 上不存在，是设备独有偏移的头号嫌疑。

### 尝试过但未完成的复现路径

- `flutter_tester --enable-impeller` 默认 **Vulkan**（SwiftShader）；GLES 需要 `--impeller-backend=opengles`，走 Swangle（ANGLE-on-Vulkan + SwiftShader），且要求引擎 out 目录里有 `libEGL.so`、`libGLESv2.so`、`vk_swiftshader_icd.json`——最小 `flutter_tester` 目标不构建它们。已确认 ninja 目标存在（`ninja -C .../denial_host_debug -t targets all | grep -E '^libEGL|^libGLESv2'`），启动构建后被用户取消（卡住）。
- 独立 GLES 诊断脚本已写好：`/tmp/lg_gles_main.dart`（纯 dart:ui，翻转根下离屏渲染胶囊并打印亚像素上/下沿与镜像跨度差）。为防 /tmp 清理，全文附在本文件末尾。

### 嫌疑排序（设备上只有按钮异常的机制）

1. canvas.cc 的 GLES-only deferred composite / backdrop plan 使**合成结果**相对裁剪框偏移几像素（融合图形不受影响，按钮贴边可见）。
2. 默认 `blurSigma=2` 组合内层 blur 触发重栅格化分支 → `uTextureSize`/`FlutterFragCoord` 语义变化（现有测试全是 blur=0，盲区）。
3. 反射下 RoundOut 取整不对称（~1px）。

## 建议的下一步

1. **补齐 tester 的 GLES 后端并本地复现**（沙箱外执行，遵守 AGENTS.md 的 CPU/工具链约束）：
   ```sh
   cd ~/.cache/denial/flutter-engine/checkout/engine/src
   PATH="$PWD/flutter/third_party/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0 \
     /usr/bin/ninja -C ~/.cache/denial/flutter-engine/build/out/denial_host_debug \
     -j $(( $(nproc) - 2 )) libEGL.so libGLESv2.so vk_swiftshader_icd.json
   # 然后运行（可能还需把 ANGLE .so 所在目录放进 LD_LIBRARY_PATH）：
   ~/.cache/denial/flutter-engine/build/out/denial_host_debug/flutter_tester \
     --enable-impeller --impeller-backend=opengles \
     --packages=<repo>/dart_shell/.dart_tool/package_config.json \
     --flutter-assets-dir=<repo>/dart_shell/build/unit_test_assets \
     /tmp/lg_gles_main.dart
   ```
2. **给离屏契约测试加 blurSigma=2 变体**（现在的足迹/镜像/rim 测试全部 blur=0，与 Lab 按钮的真实 optics 不一致，也掩盖重栅格化分支）。
3. 本地复现失败则**部署一次性离屏数值自检到 agent 管理的远程主机**（.18/.183/.188，`tools/denial-lab-deploy`；读 deniald 日志拿数字）。注意 AGENTS.md：用户做全部视觉验证，不得截图、不得触发可见 UI 事件；本地会话不得重启。
4. **shell 侧稳健修法（无论机制为何都值得考虑）**：别让形状边缘与 ClipRect 重合——给 `LiquidGlassBlend`/`LiquidGlassLens` 的裁剪框外扩几像素，让着色器 `cover` alpha 独自定义可见边缘；±2px 的场/裁剪错位将不可见。代价是 backdrop 捕获区域稍大。这是设计决策，先与用户确认。
5. **引擎侧修法**（如确认是 canvas.cc 取整/deferred 路径）：在正典 fork `/mnt/exty/denial-flutter-fork-3.44.7` 提交修复（Denial 引擎提交用 `Doctor Logix <doctor.logix@gmail.com>` 身份），然后按 AGENTS.md 推进 `SOURCE_LOCK.json` + `tools/denial-flutter-engine refresh-metadata`，不要直接改 cache 里的 checkout。

## 验证与约束备忘

- `tools/denial-pc flutter-test --enable-impeller test/macos/liquid_glass_test.dart`（以及默认模式）——所有 `tools/denial-pc` 命令在沙箱外跑。
- 编辑被 include 的 `.glsl` 后要先 touch 入口 `.frag` 再验证/打包，避免陈旧着色器。
- `~/.cache/denial/flutter-engine/checkout` 是只读投影；正典可编辑根只有 `/mnt/exty/denial-flutter-fork-3.44.7`（Flutter）与对应 Skia。
- 建议技能：`diagnose`（复现→最小化→假设→修复的纪律循环）；需要并行调查时可用 workflow。

## 附：独立 GLES 诊断脚本（/tmp/lg_gles_main.dart 全文）

```dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:denial_dart_shell/liquid_glass_lab.dart';

Future<void> main() async {
  if (!ui.ImageFilter.isShaderFilterSupported) {
    print('shader image filters NOT supported in this backend');
    return;
  }
  await LiquidGlassPrograms.ensureLoaded();
  if (LiquidGlassPrograms.failure != null) {
    print('shader load failed: ${LiquidGlassPrograms.failure}');
    return;
  }
  const dpr = 1.75;
  const width = 900;
  const height = 700;
  const logical = Rect.fromLTWH(120, 140, 300, 96);
  final rect = Rect.fromLTWH(
    logical.left * dpr,
    logical.top * dpr,
    logical.width * dpr,
    logical.height * dpr,
  );
  final shader = LiquidGlassPrograms.metaball!.fragmentShader();
  const optics = LiquidGlassOptics(
    blurSigma: 0,
    tint: Color(0x00000000),
    saturation: 1,
    specular: 0,
  );
  final origin = logical.topLeft * dpr;
  var index = optics.apply(shader, logical.size, dpr, 0, origin: origin);
  final local = Offset.zero & logical.size;
  for (var i = 0; i < 4; i++) {
    final r = i == 0 ? local : null;
    shader
      ..setFloat(index++, (r?.center.dx ?? 0) * dpr)
      ..setFloat(index++, (r?.center.dy ?? 0) * dpr)
      ..setFloat(index++, (r?.width ?? 0) / 2 * dpr)
      ..setFloat(index++, (r?.height ?? 0) / 2 * dpr);
  }
  shader
    ..setFloat(index++, 0)
    ..setFloat(index, 1);
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, width * 1.0, height * 1.0),
    Paint()..color = const Color(0xff000000),
  );
  final background = recorder.endRecording();
  final childRecorder = ui.PictureRecorder();
  Canvas(childRecorder).drawRect(
    logical,
    Paint()..color = const Color(0x01000000),
  );
  final child = childRecorder.endRecording();
  final root = Float64List(16)
    ..[0] = dpr
    ..[5] = -dpr
    ..[10] = 1
    ..[13] = height.toDouble()
    ..[15] = 1;
  final builder = ui.SceneBuilder()..addPicture(Offset.zero, background);
  builder.pushTransform(root);
  builder.pushClipRect(logical);
  builder.pushBackdropFilter(optics.filterFor(shader, dpr)!);
  builder.addPicture(Offset.zero, child);
  builder.pop();
  builder.pop();
  builder.pop();
  final scene = builder.build();
  final image = await scene.toImage(width, height);
  final bytes =
      (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  scene.dispose();
  background.dispose();
  child.dispose();
  shader.dispose();

  double alpha(int x, int y) => bytes.getUint8((y * width + x) * 4 + 3) / 255;

  double centroid(int x, int yFrom, int yTo) {
    var sum = 0.0;
    var weight = 0.0;
    for (var y = yFrom; y <= yTo; y++) {
      final a = alpha(x, y);
      sum += y * a;
      weight += a;
    }
    return weight <= 0 ? -1 : sum / weight;
  }

  var topOut = 0.0;
  var bottomOut = 0.0;
  var n = 0;
  for (var x = (rect.left + 100).floor(); x < rect.right - 100; x += 7) {
    final t = centroid(x, 451, 459);
    final b = centroid(x, 283, 291);
    if (t > 0 && b > 0) {
      topOut += t;
      bottomOut += b;
      n++;
    }
  }
  topOut /= n;
  bottomOut /= n;
  final topScene = height - topOut;
  final bottomScene = height - bottomOut;
  print('SUBPIXEL top: out=$topOut scene=$topScene ideal=245.0 '
      'delta=${(topScene - 245).toStringAsFixed(3)}');
  print('SUBPIXEL bottom: out=$bottomOut scene=$bottomScene ideal=413.0 '
      'delta=${(bottomScene - 413).toStringAsFixed(3)}');
  print('SUBPIXEL height: ${(bottomScene - topScene).toStringAsFixed(3)} '
      'ideal=168.0');

  var worstDl = 0.0;
  for (var t = 6.0; t < 80; t += 6) {
    final yA = (height - (rect.center.dy + t)).round();
    final yB = (height - (rect.center.dy - t)).round();
    int? span(int y) {
      int? first;
      var last = -1;
      for (var x = 200; x < 745; x++) {
        if (alpha(x, y) > 0.5) {
          first ??= x;
          last = x;
        }
      }
      return first == null ? null : last - first;
    }
    final sa = span(yA);
    final sb = span(yB);
    if (sa != null && sb != null) {
      worstDl = math.max(worstDl, (sa - sb).abs());
    }
  }
  print('SPAN mirrored max width delta: $worstDl');
  print('DIAG DONE');
}
```
