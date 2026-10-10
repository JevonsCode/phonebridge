import 'app_language.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'pairing.dart';

class PairingScannerPage extends StatefulWidget {
  const PairingScannerPage({super.key});

  @override
  State<PairingScannerPage> createState() => _PairingScannerPageState();
}

class _PairingScannerPageState extends State<PairingScannerPage>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    returnImage: false,
  );
  bool _starting = false;
  bool _closing = false;
  String? _scanError;
  MobileScannerErrorCode? _cameraError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    if (_starting || _closing || !mounted) return;
    _starting = true;
    setState(() => _cameraError = null);
    try {
      await _controller.start();
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (_closing ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
        await _stop();
      }
    } on MobileScannerException catch (error) {
      if (mounted) setState(() => _cameraError = error.errorCode);
    } catch (_) {
      if (mounted) {
        setState(() => _cameraError = MobileScannerErrorCode.genericError);
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    try {
      await _controller.stop();
    } catch (_) {
      // Disposal also releases the camera; never log scanner payloads/errors.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A camera permission dialog itself can interrupt the Activity.
    if (_starting || _closing || !_controller.value.hasCameraPermission) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    } else {
      unawaited(_stop());
    }
  }

  Future<void> _detected(BarcodeCapture capture) async {
    if (_closing || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final PairingData pairing;
      try {
        pairing = PairingData.parse(raw);
      } on FormatException catch (error) {
        setState(() => _scanError = error.message);
        continue;
      }
      _closing = true;
      await _stop();
      if (mounted) Navigator.of(context).pop(pairing);
      return;
    }
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose().catchError((Object _) {}));
    super.dispose();
  }

  Widget _errorPanel(MobileScannerErrorCode code) => PairingCameraError(
    permissionDenied: code == MobileScannerErrorCode.permissionDenied,
    onRetry: () => unawaited(_start()),
    onBack: () => Navigator.of(context).pop(),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, '扫描电脑端配对码'))),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              tr(
                context,
                '对准电脑上 PhoneBridge 显示的二维码。扫码只填写连接信息，之后仍需你确认并连接。\n相机画面不会上传或保存。',
              ),
              style: TextStyle(height: 1.6),
            ),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  useAppLifecycleState: false,
                  onDetect: (capture) => unawaited(_detected(capture)),
                  onDetectError: (_, _) {
                    if (mounted && !_closing) {
                      setState(() => _scanError = '暂时无法识别，请调整距离后重试。');
                    }
                  },
                  errorBuilder: (_, error) => _errorPanel(error.errorCode),
                ),
                if (_cameraError != null) _errorPanel(_cameraError!),
              ],
            ),
          ),
          if (_scanError != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                tr(context, _scanError!),
                key: const Key('scan-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(tr(context, '请勿扫描陌生人提供的配对码。返回后核对电脑地址。')),
          ),
        ],
      ),
    ),
  );
}

class PairingCameraError extends StatelessWidget {
  const PairingCameraError({
    required this.permissionDenied,
    required this.onRetry,
    required this.onBack,
    super.key,
  });

  final bool permissionDenied;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 44),
            const SizedBox(height: 16),
            Text(
              tr(context, permissionDenied ? '需要相机权限才能扫码' : '相机暂时不可用'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                context,
                permissionDenied
                    ? '请在手机系统设置中允许 PhoneBridge 使用相机，再返回重试。也可以返回手动填写连接信息。'
                    : '请关闭正在使用相机的其他应用后重试，或返回手动填写连接信息。',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(tr(context, '重试'))),
            TextButton(onPressed: onBack, child: Text(tr(context, '返回手动填写'))),
          ],
        ),
      ),
    ),
  );
}
