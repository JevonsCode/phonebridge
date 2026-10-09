import 'package:flutter/material.dart';

const ink = Color(0xFF202124);
const muted = Color(0xFF626870);
const blue = Color(0xFF1967D2);
const canvas = Color(0xFFF6F8FC);

ThemeData phoneTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: blue, surface: Colors.white);
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSansSC',
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w500,
        height: 1.25,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w500,
        height: 1.3,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: muted),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: canvas,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 20,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFEDF0F5),
      space: 1,
      thickness: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF1F4F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: blue, width: 1.5),
      ),
      labelStyle: const TextStyle(color: muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: blue,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 52),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 50),
        side: const BorderSide(color: Color(0xFFD8DEE8)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : const Color(0xFF747B85),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? blue
            : const Color(0xFFE1E5EB),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: canvas,
      surfaceTintColor: Colors.transparent,
      indicatorColor: const Color(0xFFDCE8FC),
      height: 74,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w500
              : FontWeight.w400,
          color: states.contains(WidgetState.selected) ? ink : muted,
        ),
      ),
    ),
  );
}

class SurfaceGroup extends StatelessWidget {
  const SurfaceGroup({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 0,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    super.key,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
    minLeadingWidth: 24,
    horizontalTitleGap: 16,
    leading: Icon(icon, size: 23, color: muted),
    title: Text(title, style: Theme.of(context).textTheme.titleMedium),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle!,
            style: const TextStyle(fontSize: 12, color: muted, height: 1.6),
          ),
    trailing:
        trailing ??
        (onTap != null
            ? const Icon(
                Icons.chevron_right_rounded,
                color: Color(0xFF9AA0A6),
                size: 20,
              )
            : null),
    onTap: onTap,
  );
}

class ConnectionIllustration extends StatelessWidget {
  const ConnectionIllustration({required this.connected, super.key});
  final bool connected;
  @override
  Widget build(BuildContext context) => Semantics(
    label: connected ? '手机与电脑已连接' : '手机等待连接电脑',
    child: ExcludeSemantics(
      child: SizedBox(
        height: 128,
        width: 280,
        child: CustomPaint(painter: _ConnectionPainter(connected)),
      ),
    ),
  );
}

class _ConnectionPainter extends CustomPainter {
  const _ConnectionPainter(this.connected);
  final bool connected;
  @override
  void paint(Canvas c, Size s) {
    final line = Paint()
      ..color = const Color(0xFF424B57)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = const Color(0xFFE8EEF8);
    final offset = (s.width - 280) / 2;
    c.save();
    c.translate(offset, 0);
    c.drawCircle(
      const Offset(69, 61),
      57,
      Paint()..color = const Color(0xFFF0F4FC),
    );
    c.drawCircle(
      const Offset(217, 65),
      62,
      Paint()..color = const Color(0xFFF0F4FC),
    );
    final phone = RRect.fromRectAndRadius(
      const Rect.fromLTWH(43, 18, 49, 87),
      const Radius.circular(10),
    );
    c.drawRRect(phone, Paint()..color = Colors.white);
    c.drawRRect(phone, line);
    c.drawLine(const Offset(61, 27), const Offset(74, 27), line);
    c.drawLine(const Offset(60, 97), const Offset(75, 97), line);
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(50, 40, 35, 42),
        const Radius.circular(4),
      ),
      fill,
    );
    final computer = RRect.fromRectAndRadius(
      const Rect.fromLTWH(174, 30, 91, 61),
      const Radius.circular(6),
    );
    c.drawRRect(computer, Paint()..color = Colors.white);
    c.drawRRect(computer, line);
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(182, 38, 75, 45),
        const Radius.circular(2),
      ),
      fill,
    );
    c.drawLine(const Offset(218, 91), const Offset(218, 102), line);
    c.drawLine(const Offset(202, 103), const Offset(234, 103), line);
    for (final x in [113.0, 131.0, 149.0]) {
      c.drawCircle(
        Offset(x, 61),
        3,
        Paint()..color = connected ? blue : const Color(0xFFBBC3D0),
      );
    }
    if (connected) {
      c.drawCircle(
        const Offset(91, 97),
        12,
        Paint()..color = const Color(0xFF18845A),
      );
      c.drawPath(
        Path()
          ..moveTo(86, 97)
          ..lineTo(90, 101)
          ..lineTo(97, 93),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    c.restore();
  }

  @override
  bool shouldRepaint(_ConnectionPainter oldDelegate) =>
      oldDelegate.connected != connected;
}
