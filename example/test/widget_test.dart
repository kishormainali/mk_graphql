import 'package:flutter_test/flutter_test.dart';
import 'package:example/main.dart';
import 'package:example/di/injection.dart';

void main() {
  setUpAll(() async {
    await configureDependencies();
  });

  testWidgets('CountriesApp mounts cleanly', (WidgetTester tester) async {
    await tester.pumpWidget(const CountriesApp());
    expect(find.byType(CountriesApp), findsOneWidget);
  });
}
