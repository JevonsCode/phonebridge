import 'app_language.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design.dart';

/// The Android updater owns the download and the one-time installer launch.
/// This card only observes it and sends actions explicitly requested by the user.
class AppUpdateCard extends StatefulWidget {
  const AppUpdateCard({super.key});

  @override
  State<AppUpdateCard> createState() => _AppUpdateCardState();
}

class _AppUpdateCardState extends State<AppUpdateCard>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('dev.phonebridge/control');
  static const _events = EventChannel('dev.phonebridge/updates');
  Map<String, dynamic> _status = {};
  Timer? _timer;
  StreamSubscription<dynamic>? _subscription;
  final _firstEvent = Completer<void>();
  bool _requesting = false, _reading = false, _initializing = true;
  bool _observedExistingOperation = false;
  int _revision = 0;
  String? _error;
  String? _pendingAction;

  String get _phase => _status['phase'] as String? ?? 'idle';
  bool get _downloading => _phase == 'downloading';
  bool get _checking =>
      (_phase == 'checking' && _error == null) || _initializing;
  bool get _busy => _requesting || _checking || _downloading;
  String get _currentVersion => _status['currentVersion'] as String? ?? '';
  String get _latestVersion => _status['versionName'] as String? ?? '';
  String? get _errorMessage =>
      _error ??
      ((_status['errorMessage'] as String?)?.trim().isNotEmpty == true
          ? userError(
              _status['errorCode'] as String?,
              _status['errorMessage'] as String?,
              '更新失败，请重试',
            )
          : null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (!mounted) return;
        // A newer native event wins over an already pending snapshot/result.
        // It does not finish the local MethodChannel action or enable repeats.
        _revision++;
        _accept(Map<String, dynamic>.from(event as Map));
        if (!_firstEvent.isCompleted) _firstEvent.complete();
      },
      onError: (Object error) {
        if (!mounted) return;
        _revision++;
        setState(() {
          _error = error is PlatformException
              ? userError(error.code, error.message, '无法接收更新状态，请重试')
              : '无法接收更新状态，请重试';
        });
        if (!_firstEvent.isCompleted) _firstEvent.complete();
      },
    );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    // Native emits the snapshot on listen. Consume it before starting an
    // action so a queued initial snapshot cannot overwrite its newer result.
    await _firstEvent.future;
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    setState(() => _initializing = false);
    // Re-entering About observes existing work, including a check started by
    // the previous card. The event stream delivers its terminal state.
    if (!_observedExistingOperation &&
        !{
          'checking',
          'downloading',
          'ready',
          'permissionRequired',
          'installerOpened',
        }.contains(_phase)) {
      await _action('checkUpdate');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    if (!_firstEvent.isCompleted) _firstEvent.complete();
    super.dispose();
  }

  void _accept(Map<String, dynamic>? status) {
    if (!mounted) return;
    if (_initializing &&
        {
          'checking',
          'downloading',
          'ready',
          'permissionRequired',
          'installerOpened',
        }.contains(status?['phase'])) {
      _observedExistingOperation = true;
    }
    setState(() {
      if (status != null) _status = status;
      _error = status == null ? '无法读取更新状态，请重试' : null;
    });
    if (_downloading) {
      _timer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_refresh()),
      );
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _refresh() async {
    if (_reading || _requesting) return;
    _reading = true;
    final revision = _revision;
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'getUpdateStatus',
      );
      if (revision == _revision) _accept(status);
    } on PlatformException catch (e) {
      if (mounted && revision == _revision) {
        setState(() => _error = userError(e.code, e.message, '无法读取更新状态，请重试'));
      }
    } on MissingPluginException {
      if (mounted) setState(() => _error = '应用更新仅在 Android 上可用');
    } finally {
      _reading = false;
    }
  }

  Future<void> _action(String method) async {
    if (_requesting || _downloading) return;
    final revision = ++_revision;
    setState(() {
      _requesting = true;
      _pendingAction = method;
      _error = null;
      _status = {..._status, 'errorMessage': null};
    });
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(method);
      if (revision == _revision) _accept(status);
    } on PlatformException catch (e) {
      if (mounted && revision == _revision) {
        setState(() => _error = userError(e.code, e.message, '更新操作失败，请重试'));
      }
    } on MissingPluginException {
      if (mounted) setState(() => _error = '应用更新仅在 Android 上可用');
    } finally {
      if (mounted) {
        setState(() {
          _requesting = false;
          _pendingAction = null;
        });
      }
    }
  }

  String get _description {
    if (_errorMessage?.isNotEmpty == true) return _errorMessage!;
    if (_checking || _pendingAction == 'checkUpdate') return '正在检查更新…';
    if (_pendingAction == 'downloadUpdate') return '正在开始下载…';
    if (_pendingAction == 'installUpdate') return '正在打开系统安装界面…';
    return switch (_phase) {
      'current' => '已是最新版本',
      'available' => '新版本已就绪，下载后按提示安装',
      'downloading' => '正在下载，可继续使用手机控制',
      'ready' => 'APK 已下载，点击安装继续',
      'permissionRequired' => '请允许 PhoneBridge 安装应用，然后继续安装',
      'installerOpened' => '请在系统安装界面确认；取消后可再次安装',
      'error' => '更新失败，请重试',
      _ => '检查新版本或下载最新 APK',
    };
  }

  String _bytes(num value) =>
      '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final canInstall = _phase == 'ready' || _phase == 'permissionRequired';
    final hasRelease = _latestVersion.isNotEmpty;
    final progress = (_status['progress'] as num?)?.toDouble();
    final downloaded = _status['downloadedBytes'] as num? ?? 0;
    final total = _status['totalBytes'] as num? ?? 0;
    final isError = _errorMessage?.isNotEmpty == true || _phase == 'error';
    return SurfaceGroup(
      key: const Key('app-update-card'),
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F4FC),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.system_update_rounded, color: blue),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr(context, '应用更新'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          tr(
                            context,
                            _currentVersion.isEmpty
                                ? '正在读取安装版本…'
                                : '${tr(context, '当前版本')} $_currentVersion',
                          ),
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (hasRelease) ...[
                const SizedBox(height: 18),
                Text(
                  tr(context, '${tr(context, '最新版本')} $_latestVersion'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                tr(context, _description),
                key: const Key('update-description'),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: isError ? Theme.of(context).colorScheme.error : muted,
                ),
              ),
              if (_downloading) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    key: const Key('update-progress'),
                    value: total > 0 ? progress?.clamp(0.0, 1.0) : null,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    context,
                    total > 0
                        ? '${_bytes(downloaded)} / ${_bytes(total)}'
                        : '${tr(context, '已下载')} ${_bytes(downloaded)}',
                  ),
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
              ],
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton(
                    key: const Key('check-update'),
                    onPressed: _busy ? null : () => _action('checkUpdate'),
                    child: Text(
                      tr(context, isError && !hasRelease ? '重试检查' : '检查更新'),
                    ),
                  ),
                  if (canInstall)
                    FilledButton(
                      key: const Key('install-update'),
                      onPressed: _busy ? null : () => _action('installUpdate'),
                      child: Text(
                        tr(
                          context,
                          _phase == 'permissionRequired' ? '允许并安装' : '安装更新',
                        ),
                      ),
                    )
                  else if (hasRelease && _phase != 'installerOpened')
                    FilledButton(
                      key: const Key('download-update'),
                      onPressed: _busy ? null : () => _action('downloadUpdate'),
                      child: Text(
                        tr(
                          context,
                          _downloading
                              ? '正在下载…'
                              : isError
                              ? '重试下载'
                              : _status['updateAvailable'] == true
                              ? '下载更新'
                              : '下载 APK',
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
