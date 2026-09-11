import 'package:gql/ast.dart';
import 'package:recase/recase.dart';

class CombinerGenerator {
  static String? generateCombinerQueries({
    required DocumentNode documentAst,
    required List<OperationDefinitionNode> operations,
    required String fileName,
  }) {
    if (operations.isEmpty) return null;

    final buffer = StringBuffer();

    for (final op in operations) {
      if (op.selectionSet.selections.length > 1 &&
          op.selectionSet.selections
              .any((s) => s is FieldNode && s.name.value.startsWith('query'))) {
        _generateExplicitCombiner(op, buffer);
      }
    }

    if (operations.length > 1) {
      _generateAutoCombiner(operations, fileName, buffer);
    }

    return buffer.isEmpty ? null : buffer.toString();
  }

  static void _generateExplicitCombiner(
      OperationDefinitionNode op, StringBuffer buffer) {
    final name = (op.name?.value ?? 'CombinedQueries').pascalCase;
    final reqName = '${name}Req';
    final dataName = '${name}Model';

    buffer.writeln('class $dataName {');
    final fields = <String, String>{};
    for (final sel in op.selectionSet.selections) {
      if (sel is FieldNode) {
        final innerOpName = sel.name.value.pascalCase;
        final targetDataClass = '${innerOpName}Model';
        final propName = sel.name.value.camelCase;
        fields[propName] = targetDataClass;
        buffer.writeln('  final $targetDataClass? $propName;');
      }
    }
    buffer.writeln();
    buffer.writeln('  const $dataName({');
    fields.forEach((prop, type) => buffer.writeln('    this.$prop,'));
    buffer.writeln('  });');
    buffer.writeln();

    buffer.writeln(
        '  factory $dataName.fromJson(Map<String, dynamic> json) => $dataName(');
    fields.forEach((prop, type) => buffer.writeln(
        '        $prop: json["$prop"] != null ? $type.fromJson(json["$prop"] as Map<String, dynamic>) : null,'));
    buffer.writeln('      );');
    buffer.writeln();

    buffer.writeln('  Map<String, dynamic> toJson() => {');
    fields.forEach((prop, type) =>
        buffer.writeln('        if ($prop != null) "$prop": $prop!.toJson(),'));
    buffer.writeln('      };');
    buffer.writeln('}');
    buffer.writeln();

    buffer.writeln('class $reqName extends CompositeGraphQLRequest {');
    buffer.writeln(
        '  $reqName(List<GraphQLRequest> requests, {FetchPolicy? fetchPolicy, Map<String, String>? headers})');
    buffer.writeln(
        '      : super(requests, fetchPolicy: fetchPolicy, headers: headers);');
    buffer.writeln('}');
    buffer.writeln();
  }

  static void _generateAutoCombiner(
    List<OperationDefinitionNode> operations,
    String fileName,
    StringBuffer buffer,
  ) {
    final name = '${fileName.pascalCase}Combined';
    final reqName = '${name}Req';
    final dataName = '${name}Model';

    buffer.writeln('class $dataName {');
    final fields = <String, String>{};
    for (final op in operations) {
      final opName = (op.name?.value ?? 'Anonymous').pascalCase;
      final propName = opName.camelCase;
      final typeName = '${opName}Model';
      fields[propName] = typeName;
      buffer.writeln('  final $typeName? $propName;');
    }
    buffer.writeln();
    buffer.writeln('  const $dataName({');
    fields.forEach((prop, type) => buffer.writeln('    this.$prop,'));
    buffer.writeln('  });');
    buffer.writeln();

    buffer.writeln(
        '  factory $dataName.fromJson(Map<String, dynamic> json) => $dataName(');
    fields.forEach((prop, type) => buffer.writeln(
        '        $prop: json["$prop"] != null ? $type.fromJson(json["$prop"] as Map<String, dynamic>) : null,'));
    buffer.writeln('      );');
    buffer.writeln();

    buffer.writeln('  Map<String, dynamic> toJson() => {');
    fields.forEach((prop, type) =>
        buffer.writeln('        if ($prop != null) "$prop": $prop!.toJson(),'));
    buffer.writeln('      };');
    buffer.writeln('}');
    buffer.writeln();

    buffer.writeln('class $reqName extends CompositeGraphQLRequest {');
    buffer.writeln(
        '  $reqName(List<GraphQLRequest> requests, {FetchPolicy? fetchPolicy, Map<String, String>? headers})');
    buffer.writeln(
        '      : super(requests, fetchPolicy: fetchPolicy, headers: headers);');
    buffer.writeln('}');
    buffer.writeln();
  }
}
