import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/main.dart';
import 'package:phonebridge/app_access.dart';

// Synthetic MethodChannel fixtures; no device grants are changed by these tests.
void main() {
  const channel = MethodChannel('dev.phonebridge/control');
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var allowed = <String>['dev.phonebridge.phonebridge'];
  var failSave = false;
  var mismatchedReadBack = false;
  var extraApps = <Map<String, Object>>[];
  Map<String, Object> status() => {
    'accessibilityEnabled': true,
    'connected': true,
    'connecting': false,
    'hasSavedPairing': true,
    'activeComputerId': 'computer-a',
    'computerName': 'Test Mac',
    'actionsEnabled': true,
    'allowedPackages': allowed,
    'effectiveAllowedPackages': allowed,
    'permissionRevision': 7,
  };
  setUp(() {
    calls.clear();
    allowed = ['dev.phonebridge.phonebridge'];
    failSave = false;
    mismatchedReadBack = false;
    extraApps = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'status') return status();
          if (call.method == 'getAppAccess') {
            return {
              ...status(),
              'apps': [
                {
                  'packageName': 'dev.phonebridge.phonebridge',
                  'name': 'PhoneBridge',
                  'installed': true,
                },
                {
                  'packageName': 'com.android.chrome',
                  'name': 'Chrome',
                  'installed': true,
                },
                ...extraApps,
              ],
            };
          }
          if (call.method == 'setAllowedPackages') {
            if (failSave) throw PlatformException(code: 'POLICY_CHANGED');
            if (mismatchedReadBack) return status();
            allowed = List<String>.from(call.arguments['packages'] as List);
            return status();
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('home-app-access'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'owner can select Chrome by name and save native grant read-back',
    (tester) async {
      await open(tester);
      expect(find.text('Test Mac'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-com.android.chrome')));
      await tester.tap(find.byKey(const Key('save-app-access')));
      await tester.pumpAndSettle();
      final save = calls.singleWhere((c) => c.method == 'setAllowedPackages');
      expect(save.arguments['computerId'], 'computer-a');
      expect(save.arguments['expectedPackages'], [
        'dev.phonebridge.phonebridge',
      ]);
      expect(save.arguments['permissionRevision'], 7);
      expect(allowed, contains('com.android.chrome'));
      expect(find.byKey(const Key('save-app-access')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cancel discards edited grants without a native write', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('app-com.android.chrome')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setAllowedPackages'), isEmpty);
    expect(allowed, ['dev.phonebridge.phonebridge']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stale policy is shown and does not falsely close the editor', (
    tester,
  ) async {
    failSave = true;
    await open(tester);
    await tester.tap(find.byKey(const Key('app-com.android.chrome')));
    await tester.tap(find.byKey(const Key('save-app-access')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-access-error')), findsOneWidget);
    expect(find.byKey(const Key('save-app-access')), findsOneWidget);
    expect(allowed, ['dev.phonebridge.phonebridge']);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'save read-back mismatch stays visible instead of reporting success',
    (tester) async {
      mismatchedReadBack = true;
      await open(tester);
      await tester.tap(find.byKey(const Key('app-com.android.chrome')));
      await tester.tap(find.byKey(const Key('save-app-access')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-access-error')), findsOneWidget);
      expect(allowed, ['dev.phonebridge.phonebridge']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'search filters by package and cancel releases the native editor guard',
    (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('search-app-access')),
        'com.android.chrome',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-com.android.chrome')), findsOneWidget);
      expect(
        find.byKey(const Key('app-dev.phonebridge.phonebridge')),
        findsNothing,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'closeAppAccess').length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'large text and keyboard on a narrow screen keep the editor scrollable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
              viewInsets: EdgeInsets.only(bottom: 280),
            ),
            child: AppAccessPage(
              snapshot: {
                ...status(),
                'computerName':
                    'A very long computer name for layout verification',
                'apps': [
                  {
                    'name': 'Chrome',
                    'packageName': 'com.android.chrome',
                    'installed': true,
                  },
                ],
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('select all stays local and permits individual exclusions', (
    tester,
  ) async {
    extraApps = [
      {'packageName': 'com.example.other', 'name': 'Other', 'installed': true},
      {
        'packageName': 'com.android.settings',
        'name': 'Settings',
        'installed': true,
        'protected': true,
      },
      {
        'packageName': 'com.example.removed',
        'name': 'Removed',
        'installed': false,
      },
    ];
    await open(tester);
    await tester.tap(find.byKey(const Key('select-all-apps')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setAllowedPackages'), isEmpty);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('select-all-apps')))
          .onPressed,
      isNull,
    );
    final chrome = find.byKey(const Key('app-com.android.chrome'));
    await tester.ensureVisible(chrome);
    await tester.tap(chrome);
    await tester.tap(find.byKey(const Key('save-app-access')));
    await tester.pumpAndSettle();
    expect(
      allowed,
      unorderedEquals(['dev.phonebridge.phonebridge', 'com.example.other']),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search select all preserves grants outside results', (
    tester,
  ) async {
    extraApps = [
      {'packageName': 'com.example.other', 'name': 'Other', 'installed': true},
    ];
    await open(tester);
    await tester.enterText(
      find.byKey(const Key('search-app-access')),
      'Chrome',
    );
    await tester.pumpAndSettle();
    expect(find.text('Select all results'), findsOneWidget);
    await tester.tap(find.byKey(const Key('select-all-apps')));
    await tester.tap(find.byKey(const Key('save-app-access')));
    await tester.pumpAndSettle();
    expect(
      allowed,
      unorderedEquals(['dev.phonebridge.phonebridge', 'com.android.chrome']),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancel after select all does not persist any grant', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('select-all-apps')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setAllowedPackages'), isEmpty);
    expect(allowed, ['dev.phonebridge.phonebridge']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'over-limit select all is explicit and can be reduced before save',
    (tester) async {
      extraApps = List.generate(
        63,
        (i) => {
          'packageName': 'com.example.app$i',
          'name': 'App $i',
          'installed': true,
        },
      );
      await open(tester);
      await tester.tap(find.byKey(const Key('select-all-apps')));
      await tester.pumpAndSettle();
      expect(find.text('Selected 65 / 64'), findsOneWidget);
      expect(
        find.text('Up to 64 apps are allowed. Deselect some apps to continue.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('save-app-access')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'setAllowedPackages'), isEmpty);
      await tester.enterText(
        find.byKey(const Key('search-app-access')),
        'Chrome',
      );
      await tester.pumpAndSettle();
      final chrome = find.byKey(const Key('app-com.android.chrome'));
      await tester.ensureVisible(chrome);
      await tester.tap(chrome);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-access-error')), findsNothing);
      await tester.tap(find.byKey(const Key('save-app-access')));
      await tester.pumpAndSettle();
      expect(allowed.length, 64);
      expect(allowed, isNot(contains('com.android.chrome')));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
