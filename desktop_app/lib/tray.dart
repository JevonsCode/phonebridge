import 'dart:async';
import 'dart:io';
import 'package:tray_manager/tray_manager.dart';
import 'backend.dart';

/// The tray choice lives beside the language choice in the user profile, so it
/// survives restarts and upgrades of the versioned application bundle.
class TrayPreference {
  const TrayPreference(this.file);
  final File? file;

  /// The icon is shown unless the user explicitly turned it off.
  Future<bool> load() async {
    try {
      return (await file!.readAsString()).trim() != 'off';
    } catch (_) {
      return true;
    }
  }

  Future<void> save(bool enabled) async {
    try {
      await file?.parent.create(recursive: true);
      await file?.writeAsString(enabled ? 'on' : 'off', flush: true);
    } catch (_) {}
  }
}

/// The same headline the connection page shows, for places outside the window.
String connectionTitle(DesktopController c, bool zh) {
  String t(String cn, String en) => zh ? cn : en;
  final s = c.status;
  return c.starting
      ? t('正在准备连接', 'Getting ready')
      : c.connectionFailed
      ? t('连接已中断', 'Connection interrupted')
      : s?.unavailable == true
      ? t('服务暂不可用', 'Service unavailable')
      : s?.connected == true
      ? t('手机已连接', 'Your phone is connected')
      : t('等待手机连接', 'Waiting for your phone');
}

/// Notification-area (Windows) or menu-bar (macOS) icon. Clicking it brings
/// back the window with the pairing code; its menu reports the connection.
class DesktopTray with TrayListener {
  DesktopTray({
    required this.controller,
    required bool chinese,
    required this.showWindow,
    required this.quit,
    TrayManager? manager,
  }) : _chinese = chinese,
       _tray = manager ?? trayManager;
  final DesktopController controller;
  final Future<void> Function() showWindow, quit;
  final TrayManager _tray;
  bool _chinese;
  bool _visible = false;
  String? _shownStatus;
  Future<void> _pending = Future.value();

  /// Whether the icon is currently in the tray, so closing should only hide.
  bool get visible => _visible;
  String t(String cn, String en) => _chinese ? cn : en;

  set chinese(bool zh) {
    _chinese = zh;
    if (_visible) unawaited(_serial(() => _update(force: true)));
  }

  /// Applies the setting immediately. Calls run in order, so fast toggling
  /// never leaves a stale icon behind.
  Future<void> setVisible(bool visible) =>
      _serial(() => visible ? _show() : _hide());

  Future<void> _serial(Future<void> Function() action) =>
      _pending = _pending.then((_) => action()).catchError((Object _) {});

  Future<void> _show() async {
    if (_visible) return;
    _tray.addListener(this);
    controller.addListener(_onStatus);
    try {
      await _tray.setIcon(
        Platform.isWindows ? 'assets/brand/tray.ico' : 'assets/brand/logo.png',
      );
      _visible = true;
      await _update(force: true);
    } catch (_) {
      await _hide(force: true);
    }
  }

  Future<void> _hide({bool force = false}) async {
    if (!_visible && !force) return;
    _visible = false;
    _shownStatus = null;
    _tray.removeListener(this);
    controller.removeListener(_onStatus);
    await _tray.destroy();
  }

  void _onStatus() {
    if (_visible && connectionTitle(controller, _chinese) != _shownStatus) {
      unawaited(_serial(_update));
    }
  }

  Future<void> _update({bool force = false}) async {
    final status = connectionTitle(controller, _chinese);
    if (!_visible || (!force && status == _shownStatus)) return;
    _shownStatus = status;
    await _tray.setToolTip('PhoneBridge · $status');
    await _tray.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'open', label: t('打开 PhoneBridge', 'Open PhoneBridge')),
          MenuItem.separator(),
          MenuItem(
            key: 'status',
            label: t('状态：$status', 'Status: $status'),
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'quit',
            label: t(
              '退出窗口（后台服务继续运行）',
              'Quit window (background service keeps running)',
            ),
          ),
        ],
      ),
    );
  }

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() =>
      // Windows needs the app in front so the menu closes on an outside click.
      // ignore: deprecated_member_use
      unawaited(_tray.popUpContextMenu(bringAppToFront: true));

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') unawaited(showWindow());
    if (menuItem.key == 'quit') unawaited(quit());
  }
}
