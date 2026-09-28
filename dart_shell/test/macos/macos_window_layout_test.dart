import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/macos/macos_desktop_scene.dart';
import 'package:denial_dart_shell/src/macos/macos_window_frame.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

DenialWindow testWindow(int objectId, Rect geometry) => DenialWindow(
  objectId: objectId,
  objectKind: 'xdg',
  surfaceId: objectId + 100,
  windowId: objectId + 200,
  textureId: objectId + 300,
  title: 'Window $objectId',
  appId: 'test.app.$objectId',
  width: geometry.width.round(),
  height: geometry.height.round(),
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: geometry.width,
  surfaceHeight: geometry.height,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: geometry.width,
  textureSourceHeight: geometry.height,
  geometryX: geometry.left,
  geometryY: geometry.top,
  geometryWidth: geometry.width,
  geometryHeight: geometry.height,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);

void main() {
  test('frame rect keeps the title bar above the routed content rect', () {
    const placement = DesktopWindowPlacement(
      objectId: 1,
      frame: Rect.fromLTWH(137, 83, 640, 480),
      z: 1,
      monitorId: 1,
    );

    final frameRect = macosWindowFrameRect(placement);

    expect(
      Rect.fromLTWH(
        frameRect.left,
        frameRect.top + MacosWindowFrame.titleBarHeight,
        frameRect.width,
        frameRect.height - MacosWindowFrame.titleBarHeight,
      ),
      placement.contentRect,
    );
    expect(
      frameRect.top,
      placement.contentRect.top - MacosWindowFrame.titleBarHeight,
    );
    expect(frameRect.left, placement.contentRect.left);
  });

  test('frame rect has no title strip when the server frame is hidden', () {
    const placement = DesktopWindowPlacement(
      objectId: 1,
      frame: Rect.fromLTWH(0, 0, 1920, 1080),
      z: 1,
      monitorId: 1,
      fullscreen: true,
    );

    expect(placement.drawsLiveServerFrame, isFalse);
    expect(macosWindowFrameRect(placement), placement.contentRect);
  });

  test('visible placements follow the routed stack order, not input order', () {
    final first = testWindow(1, const Rect.fromLTWH(700, 500, 800, 600));
    final second = testWindow(2, const Rect.fromLTWH(90, 120, 480, 360));
    const firstPlacement = DesktopWindowPlacement(
      objectId: 1,
      frame: Rect.fromLTWH(700, 500, 800, 600),
      z: 9,
      monitorId: 1,
    );
    const secondPlacement = DesktopWindowPlacement(
      objectId: 2,
      frame: Rect.fromLTWH(90, 120, 480, 360),
      z: 3,
      monitorId: 1,
    );
    final workspace = DesktopWorkspaceState(
      placements: const <int, DesktopWindowPlacement>{
        1: firstPlacement,
        2: secondPlacement,
      },
      nextZ: 10,
      viewSize: const Size(1920, 1080),
    );

    final visible = macosVisibleWindowPlacements(
      windows: <DenialWindow>[first, second],
      workspace: workspace,
    );

    expect(visible.map((entry) => entry.window.objectId), <int>[2, 1]);
    expect(visible[0].placement.contentRect, secondPlacement.contentRect);
    expect(visible[1].placement.contentRect, firstPlacement.contentRect);
  });

  test('minimized and inactive-workspace placements are excluded', () {
    final window = testWindow(1, const Rect.fromLTWH(320, 240, 640, 480));
    final workspace = DesktopWorkspaceState(
      placements: const <int, DesktopWindowPlacement>{
        1: DesktopWindowPlacement(
          objectId: 1,
          frame: Rect.fromLTWH(320, 240, 640, 480),
          z: 1,
          monitorId: 1,
          workspaceId: 1,
        ),
        2: DesktopWindowPlacement(
          objectId: 2,
          frame: Rect.fromLTWH(64, 64, 400, 300),
          z: 2,
          monitorId: 1,
          workspaceId: 1,
          minimized: true,
        ),
        3: DesktopWindowPlacement(
          objectId: 3,
          frame: Rect.fromLTWH(1200, 400, 500, 400),
          z: 3,
          monitorId: 1,
          workspaceId: 2,
        ),
        4: DesktopWindowPlacement(
          objectId: 4,
          frame: Rect.fromLTWH(40, 600, 300, 200),
          z: 4,
          monitorId: 1,
          workspaceId: 1,
        ),
      },
      nextZ: 5,
      viewSize: const Size(1920, 1080),
      workspacesEnabled: true,
      workspaceCount: 4,
      activeWorkspaces: const <int, int>{1: 1},
    );

    final visible = macosVisibleWindowPlacements(
      windows: <DenialWindow>[window],
      workspace: workspace,
    );

    expect(visible.map((entry) => entry.window.objectId), <int>[1]);
    expect(identical(visible.single.window, window), isTrue);
  });
}
