import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/design.dart';

void main() {
  testWidgets('pressed feedback stays inside every rounded group', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: phoneTheme(),
        home: RepaintBoundary(
          key: boundaryKey,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: SurfaceGroup(
                  children: [
                    SettingsRow(
                      icon: Icons.computer,
                      title: '电脑',
                      onTap: () {},
                    ),
                    SettingsRow(
                      icon: Icons.language,
                      title: '官网',
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byType(SurfaceGroup));
    final clip = RRect.fromRectAndRadius(bounds, const Radius.circular(24));
    Future<List<int>> pixels() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final result = bytes!.buffer.asUint8List().toList();
      image.dispose();
      return result;
    }

    final before = (await tester.runAsync(pixels))!;
    for (final label in ['电脑', '官网']) {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(label)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 100));
      final pressed = (await tester.runAsync(pixels))!;
      var changedInside = 0;
      for (var y = 0; y < 400; y++) {
        for (var x = 0; x < 400; x++) {
          final i = (y * 400 + x) * 4;
          final changed = List.generate(
            4,
            (c) => before[i + c] != pressed[i + c],
          ).any((v) => v);
          if (clip.contains(Offset(x + .5, y + .5))) {
            if (changed) changedInside++;
          } else if (!clip.inflate(1).contains(Offset(x + .5, y + .5))) {
            expect(changed, false, reason: '$label feedback escaped at $x,$y');
          }
        }
      }
      expect(
        changedInside,
        greaterThan(0),
        reason: 'Pressed feedback must still be visible',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }
  });
}
