// The QR reader both pairing pages use: the camera on Android (with a photo
// fallback), the system scan page on HarmonyOS. Kept out of any one page, so a
// page never depends on another page's file.
//
// Neither reader owns the pairing: they report the text of one code and stop.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../l10n/l10n.dart';
import '../../../state/android_features.dart' show operatingSystemProvider;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// What the reader said when it could not start, so a page can offer the ways
/// in that need no camera.
enum ScanBoxTrouble {
  /// The system refused the camera to this app.
  permissionDenied,

  /// The camera or the shared scanning SDK could not start.
  unavailable,
}

/// Builds the live reader for the current platform; tests swap in a stand-in.
/// [onTrouble] is told once when the reader cannot run at all.
typedef ScanBoxBuilder =
    Widget Function(BuildContext context, ValueChanged<String> onCode, {ValueChanged<ScanBoxTrouble>? onTrouble});

/// The reader this platform has: the camera on Android, the system scan page
/// on HarmonyOS.
final scanBoxProvider = Provider<ScanBoxBuilder>((ref) {
  // HarmonyOS has no mobile_scanner: its system scan page reads the code.
  if (ref.watch(operatingSystemProvider) == 'ohos') {
    return (context, onCode, {onTrouble}) => _SystemScanner(onCode: onCode, onTrouble: onTrouble);
  }
  return (context, onCode, {onTrouble}) => _CameraScanner(onCode: onCode, onTrouble: onTrouble);
});

// ── Android: the camera ─────────────────────────────────────────────────────

class _CameraScanner extends StatefulWidget {
  const _CameraScanner({required this.onCode, this.onTrouble});

  final ValueChanged<String> onCode;
  final ValueChanged<ScanBoxTrouble>? onTrouble;

  @override
  State<_CameraScanner> createState() => _CameraScannerState();
}

class _CameraScannerState extends State<_CameraScanner> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _reported = false;
  late final Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    // Android disables ML Kit's eager provider for OCR privacy. Both the camera
    // and the photo decoder need the shared SDK before mobile_scanner uses it.
    _initialization = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const MethodChannel('dsh/app').invokeMethod<void>('initializePairingScanner')
        : Future<void>.value();
    // A refused camera is the phone's answer, not this widget's state: say it
    // once, and let the page offer the ways in that need none.
    unawaited(_initialization.then((_) {}, onError: (_) => _reportTrouble(ScanBoxTrouble.unavailable)));
  }

  ScanBoxTrouble? _trouble;

  void _reportTrouble(ScanBoxTrouble trouble) {
    if (!mounted || _trouble == trouble) return;
    _trouble = trouble;
    widget.onTrouble?.call(trouble);
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _report(BarcodeCapture capture) {
    if (!mounted || _reported) return;
    for (final code in capture.barcodes) {
      final text = code.rawValue;
      if (text == null || text.isEmpty) continue;
      _reported = true;
      unawaited(_controller.stop());
      widget.onCode(text);
      return;
    }
  }

  /// A screenshot of the code instead of the camera (no camera permission).
  Future<void> _fromImage() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.remotePairImageNoCode)));
      return;
    }
    if (picked == null || !mounted) return;
    BarcodeCapture? capture;
    try {
      await _initialization;
      if (!mounted) return;
      capture = await _controller.analyzeImage(picked.path, formats: const [BarcodeFormat.qrCode]);
    } catch (_) {
      if (mounted) messenger?.showSnackBar(SnackBar(content: Text(l10n.remotePairScannerFailed)));
      return;
    }
    if (!mounted) return;
    if (capture == null || capture.barcodes.every((b) => (b.rawValue ?? '').isEmpty)) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.remotePairImageNoCode)));
      return;
    }
    _report(capture);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<void>(
          future: _initialization,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _CameraUnavailable(message: l10n.remotePairScannerFailed, onShown: () => _reportTrouble(ScanBoxTrouble.unavailable));
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            return MobileScanner(
              controller: _controller,
              onDetect: _report,
              errorBuilder: (context, error) {
                final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
                // The preview failing is not a rebuild: report it off the build.
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _reportTrouble(denied ? ScanBoxTrouble.permissionDenied : ScanBoxTrouble.unavailable),
                );
                return _CameraUnavailable(
                  message: denied ? l10n.remotePairCameraDenied : l10n.remotePairCameraFailed,
                );
              },
            );
          },
        ),
        const IgnorePointer(child: CustomPaint(painter: _FramePainter())),
        Positioned(
          right: 10,
          bottom: 10,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => unawaited(_fromImage()),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(AppIcons.gallery, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(l10n.remotePairFromImage, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── HarmonyOS: the system scan page ─────────────────────────────────────────

/// A button that opens the system scan page (Scan Kit, through
/// `dsh/app.scanQrCode`). That page owns the camera and has its own album
/// entry, so there is no camera permission and no 从相册识别 here. Closing it
/// does nothing.
class _SystemScanner extends StatefulWidget {
  const _SystemScanner({required this.onCode, this.onTrouble});

  final ValueChanged<String> onCode;
  final ValueChanged<ScanBoxTrouble>? onTrouble;

  @override
  State<_SystemScanner> createState() => _SystemScannerState();
}

class _SystemScannerState extends State<_SystemScanner> {
  static const _app = MethodChannel('dsh/app');
  bool _scanning = false;
  bool _failed = false;

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _failed = false;
    });
    String? text;
    var failed = false;
    try {
      text = await _app.invokeMethod<String>('scanQrCode');
    } on PlatformException catch (e) {
      // 'busy': a scan page is already open and will answer for itself.
      failed = e.code != 'busy';
    } on MissingPluginException {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _failed = failed;
    });
    if (failed) widget.onTrouble?.call(ScanBoxTrouble.unavailable);
    if (text != null && text.isNotEmpty) widget.onCode(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return ColoredBox(
      color: colors.codeWellBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: _scanning ? null : () => unawaited(_scan()),
                style: FilledButton.styleFrom(minimumSize: const Size(168, 56), textStyle: theme.textTheme.titleMedium),
                icon: const Icon(AppIcons.qrCode, size: 24),
                label: Text(l10n.remotePairSystemScan),
              ),
              const SizedBox(height: 16),
              Text(
                _failed ? l10n.remotePairScannerFailed : l10n.remotePairSystemScanHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _failed ? colors.danger : theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message, this.onShown});

  final String message;

  /// Called once, after the first frame that shows what went wrong.
  final VoidCallback? onShown;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    if (onShown case final shown?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => shown());
    }
    return ColoredBox(
      color: colors.codeWellBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.qrCode, size: 36, color: colors.textTertiary),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Four corner brackets around the middle of the preview.
class _FramePainter extends CustomPainter {
  const _FramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.64;
    final rect = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final arm = side * 0.16;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final (corner, dx, dy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomLeft, 1.0, -1.0),
      (rect.bottomRight, -1.0, -1.0),
    ]) {
      canvas
        ..drawLine(corner, corner.translate(arm * dx, 0), paint)
        ..drawLine(corner, corner.translate(0, arm * dy), paint);
    }
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => false;
}
