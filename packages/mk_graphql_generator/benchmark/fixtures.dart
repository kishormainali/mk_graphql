/// Synthetic GraphQL schema + feature-file fixtures for
/// generator_benchmark.dart — sized to exercise a realistic mix (shared
/// return types across many operation fields, so buildSelectionSetNode's
/// memoization actually has repeats to reuse).
library;

const enumCount = 30;
const inputCount = 30;
const typeCount = 30;
const sharedReturnTypeCount = 5; // deliberately small: many fields return the same few types
const queryFieldCount = 30;
const mutationFieldCount = 30;

String buildSchema() {
  final buf = StringBuffer();
  for (var i = 0; i < enumCount; i++) {
    buf.writeln('enum Enum$i { A, B, C }');
  }
  for (var i = 0; i < inputCount; i++) {
    buf.writeln(
        'input Input$i { fieldA: String fieldB: Int fieldC: Enum${i % enumCount} }');
  }
  for (var i = 0; i < typeCount; i++) {
    buf.writeln('type Type$i {');
    buf.writeln('  id: ID!');
    for (var f = 0; f < 6; f++) {
      buf.writeln('  field$f: String');
    }
    buf.writeln('  relatedEnum: Enum${i % enumCount}');
    buf.writeln('  relatedType: Type${(i + 1) % typeCount}');
    buf.writeln('}');
  }
  buf.writeln('type Query {');
  for (var i = 0; i < queryFieldCount; i++) {
    final t = 'Type${i % sharedReturnTypeCount}';
    buf.writeln('  query$i(id: ID!): $t');
  }
  buf.writeln('}');
  buf.writeln('type Mutation {');
  for (var i = 0; i < mutationFieldCount; i++) {
    final t = 'Type${i % sharedReturnTypeCount}';
    buf.writeln('  mutation$i(id: ID!, input: Input${i % inputCount}!): $t');
  }
  buf.writeln('}');
  return buf.toString();
}

String buildOperationsFile() {
  final buf = StringBuffer();
  for (var i = 0; i < 20; i++) {
    buf.writeln('query GetType$i(\$id: ID!) {');
    buf.writeln('  query${i % queryFieldCount}(id: \$id) {');
    buf.writeln('    id');
    buf.writeln('    field0');
    buf.writeln('    field1');
    buf.writeln('    relatedEnum');
    buf.writeln('    relatedType { id field0 }');
    buf.writeln('  }');
    buf.writeln('}');
  }
  return buf.toString();
}
