import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:example/main.dart';
import 'package:example/di/injection.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    // configureDependencies() opens a HiveCache box, which needs Hive
    // initialized with a storage path — main() does this via
    // Hive.initFlutter(), which isn't available/needed outside a real app,
    // so point it at a throwaway temp dir instead.
    hiveDir = await Directory.systemTemp.createTemp('example_widget_test_');
    Hive.init(hiveDir.path);
    await configureDependencies();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
    if (hiveDir.existsSync()) hiveDir.deleteSync(recursive: true);
  });

  testWidgets('AniListApp mounts cleanly', (WidgetTester tester) async {
    await tester.pumpWidget(const AniListApp());
    expect(find.byType(AniListApp), findsOneWidget);
  });
}
