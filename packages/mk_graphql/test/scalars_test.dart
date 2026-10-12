import 'package:mk_graphql/mk_graphql.dart';
import 'package:test/test.dart';

void main() {
  test('DateTimeScalarConverter: response -> local, request -> UTC', () {
    final parsed = DateTimeScalarConverter.fromJson('2026-01-01T10:00:00Z');
    expect(parsed.isUtc, isFalse);
    expect(parsed.toUtc(), DateTime.utc(2026, 1, 1, 10));

    final local = DateTime(2026, 1, 1, 10);
    final json = DateTimeScalarConverter.toJson(local);
    expect(json, endsWith('Z'));
    expect(DateTime.parse(json), local.toUtc());
  });

  test('toJson leaves an already-UTC date unchanged', () {
    final utc = DateTime.utc(2026, 1, 1, 10);
    expect(DateTimeScalarConverter.toJson(utc), '2026-01-01T10:00:00.000Z');
  });
}
