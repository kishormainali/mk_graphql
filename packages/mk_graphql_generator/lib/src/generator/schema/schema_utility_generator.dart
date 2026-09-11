import 'package:gql/ast.dart';
import 'package:recase/recase.dart';
import 'schema_generator.dart';

class SchemaUtilityGenerator {
  static String generateSchemaUtilities({
    required List<ObjectTypeDefinitionNode> objectTypes,
    required Set<String> enumNames,
    required Set<String> inputNames,
  }) {
    final buffer = StringBuffer();
    final queryType = objectTypes.firstWhere((o) => o.name.value == 'Query',
        orElse: () => ObjectTypeDefinitionNode(
            name: NameNode(value: 'Query'), fields: []));
    final mutationType = objectTypes.firstWhere(
        (o) => o.name.value == 'Mutation',
        orElse: () => ObjectTypeDefinitionNode(
            name: NameNode(value: 'Mutation'), fields: []));

    final allFields = [
      ...queryType.fields.map((f) => (field: f, isMutation: false)),
      ...mutationType.fields.map((f) => (field: f, isMutation: true)),
    ];

    if (allFields.isEmpty) {
      return '';
    }

    // 1. Generate Vars & Req classes for each schema operation field
    for (final item in allFields) {
      final field = item.field;
      final isMutation = item.isMutation;
      final rawName = field.name.value;
      final name = rawName.pascalCase;
      final reqClassName = '${name}Req';
      final varsClassName = '${name}Vars';
      final returnTypeInfo = SchemaGenerator.parseFieldType(field.type,
          enumNames: enumNames, inputNames: inputNames);
      final modelClassName = returnTypeInfo.dartType;
      final opType = isMutation ? 'mutation' : 'query';

      // 1a. Generate Vars Class
      buffer.writeln('@freezed');
      buffer.writeln('abstract class $varsClassName with _\$$varsClassName {');
      if (field.args.isEmpty) {
        buffer.writeln('  const factory $varsClassName() = _$varsClassName;');
      } else {
        buffer.writeln('  const factory $varsClassName({');
        for (final arg in field.args) {
          final argTypeInfo = SchemaGenerator.parseFieldType(arg.type,
              enumNames: enumNames, inputNames: inputNames);
          final argName = arg.name.value.camelCase;
          if (argTypeInfo.isRequired) {
            buffer.writeln('    required ${argTypeInfo.dartType} $argName,');
          } else {
            // Omit unset optional args from toJson() rather than sending
            // them as explicit `null` — some GraphQL servers treat the two
            // differently (e.g. an omitted filter returns everything, an
            // explicit `filter: null` can resolve to no results).
            buffer.writeln('    @JsonKey(includeIfNull: false)');
            buffer.writeln('    ${argTypeInfo.dartType}? $argName,');
          }
        }
        buffer.writeln('  }) = _$varsClassName;');
      }
      buffer.writeln();
      buffer.writeln(
          '  factory $varsClassName.fromJson(Map<String, dynamic> json) => _\$${varsClassName}FromJson(json);');
      buffer.writeln('}');
      buffer.writeln();

      // 1b. Generate Request Class
      final argsStr = field.args
          .map((a) => '\$${a.name.value}: ${_typeToGql(a.type)}')
          .join(', ');
      final callArgsStr = field.args
          .map((a) => '${a.name.value}: \$${a.name.value}')
          .join(', ');
      final docStr =
          '$opType $name${argsStr.isNotEmpty ? "($argsStr)" : ""} { $rawName${callArgsStr.isNotEmpty ? "($callArgsStr)" : ""} }';

      buffer.writeln('@freezed');
      buffer.writeln(
          'abstract class $reqClassName extends GraphQLRequest<$modelClassName, $varsClassName> with _\$$reqClassName {');
      buffer.writeln('  const factory $reqClassName({');
      buffer.writeln('    required $varsClassName variables,');
      buffer.writeln('    FetchPolicy? fetchPolicy,');
      buffer.writeln('    Map<String, String>? headers,');
      buffer.writeln('    CancelToken? cancelToken,');
      buffer.writeln('    $modelClassName? optimisticResponse,');
      buffer.writeln('  }) = _$reqClassName;');
      buffer.writeln();
      buffer.writeln('  const $reqClassName._();');
      buffer.writeln();
      buffer.writeln('  @override');
      buffer.writeln('  String get document => r"""$docStr""";');
      buffer.writeln();
      buffer.writeln('  @override');
      buffer.writeln('  String get operationName => "$name";');
      buffer.writeln();
      buffer.writeln('  @override');
      buffer.writeln(
          '  Map<String, dynamic> toJsonVars($varsClassName vars) => (vars as dynamic).toJson();');
      buffer.writeln();
      buffer.writeln('  @override');
      buffer
          .writeln('  $modelClassName parseData(Map<String, dynamic> json) =>');
      buffer
          .writeln('      ${_generateParseDataExpr(modelClassName, rawName)};');
      buffer.writeln();
      buffer.writeln('  @override');
      buffer.writeln('  $reqClassName copyWithRequest({');
      buffer.writeln('    $varsClassName? variables,');
      buffer.writeln('    FetchPolicy? fetchPolicy,');
      buffer.writeln('    Map<String, String>? headers,');
      buffer.writeln('    CancelToken? cancelToken,');
      buffer.writeln('    $modelClassName? optimisticResponse,');
      buffer.writeln('  }) =>');
      buffer.writeln('      copyWith(');
      buffer.writeln('        variables: variables ?? this.variables,');
      buffer.writeln('        fetchPolicy: fetchPolicy ?? this.fetchPolicy,');
      buffer.writeln('        headers: headers ?? this.headers,');
      buffer.writeln('        cancelToken: cancelToken ?? this.cancelToken,');
      buffer.writeln(
          '        optimisticResponse: optimisticResponse ?? this.optimisticResponse,');
      buffer.writeln('      );');
      buffer.writeln('}');
      buffer.writeln();
    }

    // 2. Generate GraphQLClient Extension with Future and Stream methods
    buffer.writeln(
        '/// Auto-generated type-safe Schema Client Extension for GraphQLClient');
    buffer.writeln('extension SchemaGraphQLClientExtension on GraphQLClient {');

    for (final item in allFields) {
      final field = item.field;
      final methodName = field.name.value.camelCase;
      final opName = field.name.value.pascalCase;
      final reqClassName = '${opName}Req';
      final varsClassName = '${opName}Vars';
      final returnTypeInfo = SchemaGenerator.parseFieldType(field.type,
          enumNames: enumNames, inputNames: inputNames);
      final returnTypeModel = returnTypeInfo.dartType;
      final hasArgs = field.args.isNotEmpty;

      // Future method
      buffer.writeln('  /// Future execution for $methodName');
      buffer.writeln('  Future<$returnTypeModel> $methodName({');
      for (final arg in field.args) {
        final argTypeInfo = SchemaGenerator.parseFieldType(arg.type,
            enumNames: enumNames, inputNames: inputNames);
        final argName = arg.name.value.camelCase;
        if (argTypeInfo.isRequired) {
          buffer.writeln('    required ${argTypeInfo.dartType} $argName,');
        } else {
          buffer.writeln('    ${argTypeInfo.dartType}? $argName,');
        }
      }
      buffer.writeln('    FetchPolicy? fetchPolicy,');
      buffer.writeln('    Map<String, String>? headers,');
      buffer.writeln('    CancelToken? cancelToken,');
      buffer.writeln('  }) {');
      buffer.writeln('    return future($reqClassName(');
      if (hasArgs) {
        buffer.writeln('      variables: $varsClassName(');
        for (final arg in field.args) {
          final argName = arg.name.value.camelCase;
          buffer.writeln('        $argName: $argName,');
        }
        buffer.writeln('      ),');
      } else {
        buffer.writeln('      variables: const $varsClassName(),');
      }
      buffer.writeln('      fetchPolicy: fetchPolicy,');
      buffer.writeln('      headers: headers,');
      buffer.writeln('      cancelToken: cancelToken,');
      buffer.writeln('    ));');
      buffer.writeln('  }');
      buffer.writeln();

      // Stream method
      buffer.writeln('  /// Stream execution for $methodName');
      buffer.writeln('  Stream<$returnTypeModel> ${methodName}Stream({');
      for (final arg in field.args) {
        final argTypeInfo = SchemaGenerator.parseFieldType(arg.type,
            enumNames: enumNames, inputNames: inputNames);
        final argName = arg.name.value.camelCase;
        if (argTypeInfo.isRequired) {
          buffer.writeln('    required ${argTypeInfo.dartType} $argName,');
        } else {
          buffer.writeln('    ${argTypeInfo.dartType}? $argName,');
        }
      }
      buffer.writeln('    FetchPolicy? fetchPolicy,');
      buffer.writeln('    Map<String, String>? headers,');
      buffer.writeln('    CancelToken? cancelToken,');
      buffer.writeln('  }) {');
      buffer.writeln('    return stream($reqClassName(');
      if (hasArgs) {
        buffer.writeln('      variables: $varsClassName(');
        for (final arg in field.args) {
          final argName = arg.name.value.camelCase;
          buffer.writeln('        $argName: $argName,');
        }
        buffer.writeln('      ),');
      } else {
        buffer.writeln('      variables: const $varsClassName(),');
      }
      buffer.writeln('      fetchPolicy: fetchPolicy,');
      buffer.writeln('      headers: headers,');
      buffer.writeln('      cancelToken: cancelToken,');
      buffer.writeln('    ));');
      buffer.writeln('  }');
      buffer.writeln();

      // Refetch method
      final refetchMethodName = 'refetch$opName';
      buffer.writeln(
          '  /// Refetch execution for $methodName (bypasses cache with FetchPolicy.networkOnly)');
      buffer.writeln('  Future<$returnTypeModel> $refetchMethodName({');
      for (final arg in field.args) {
        final argTypeInfo = SchemaGenerator.parseFieldType(arg.type,
            enumNames: enumNames, inputNames: inputNames);
        final argName = arg.name.value.camelCase;
        if (argTypeInfo.isRequired) {
          buffer.writeln('    required ${argTypeInfo.dartType} $argName,');
        } else {
          buffer.writeln('    ${argTypeInfo.dartType}? $argName,');
        }
      }
      buffer.writeln('    Map<String, String>? headers,');
      buffer.writeln('    CancelToken? cancelToken,');
      buffer.writeln('  }) {');
      buffer.writeln('    return refetch($reqClassName(');
      if (hasArgs) {
        buffer.writeln('      variables: $varsClassName(');
        for (final arg in field.args) {
          final argName = arg.name.value.camelCase;
          buffer.writeln('        $argName: $argName,');
        }
        buffer.writeln('      ),');
      } else {
        buffer.writeln('      variables: const $varsClassName(),');
      }
      buffer.writeln('      headers: headers,');
      buffer.writeln('      cancelToken: cancelToken,');
      buffer.writeln('    ));');
      buffer.writeln('  }');
      buffer.writeln();
    }

    buffer.writeln('}');
    buffer.writeln();

    return buffer.toString();
  }

  static bool _isPrimitive(String type) {
    return type == 'String' ||
        type == 'int' ||
        type == 'double' ||
        type == 'bool' ||
        type == 'DateTime' ||
        type == 'Map<String, dynamic>' ||
        type == 'dynamic';
  }

  static String _generateParseDataExpr(String modelClassName, String rawName) {
    if (_isPrimitive(modelClassName)) {
      return '(json["$rawName"] ?? json) as $modelClassName';
    } else if (modelClassName.startsWith('List<') &&
        modelClassName.endsWith('>')) {
      final inner =
          modelClassName.substring(5, modelClassName.length - 1).trim();
      if (_isPrimitive(inner)) {
        return '((json["$rawName"] as List<dynamic>?) ?? (json is List ? json as List<dynamic> : null))?.map((e) => e as $inner).toList() ?? <$inner>[]';
      } else {
        return '((json["$rawName"] as List<dynamic>?) ?? (json is List ? json as List<dynamic> : null))?.map((e) => $inner.fromJson(e as Map<String, dynamic>)).toList() ?? <$inner>[]';
      }
    } else {
      return '$modelClassName.fromJson(json["$rawName"] as Map<String, dynamic>? ?? json)';
    }
  }

  static String _typeToGql(TypeNode type) {
    String base = '';
    if (type is NamedTypeNode) {
      base = type.name.value;
    } else if (type is ListTypeNode) {
      base = '[${_typeToGql(type.type)}]';
    } else {
      base = 'String';
    }
    return type.isNonNull ? '$base!' : base;
  }
}
