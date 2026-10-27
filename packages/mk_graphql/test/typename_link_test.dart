import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:mk_graphql/mk_graphql.dart';

void main() {
  Future<String> sent(String doc) async {
    late DocumentNode out;
    await const TypenameLink().request(
      Request(operation: Operation(document: parseString(doc))),
      (req) {
        out = req.operation.document;
        return const Stream.empty();
      },
    ).drain<void>();
    return printNode(out).replaceAll(RegExp(r'\s+'), ' ');
  }

  test(
    'a subscription root gets no __typename, nested selections do',
    () async {
      final doc = await sent('subscription S { chat { id user { name } } }');
      expect(
        doc,
        'subscription S { chat { id user { name __typename } __typename } }',
      );
    },
  );
}
