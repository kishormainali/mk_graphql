import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:recase/recase.dart';
import '../dart_codegen.dart' as codegen;
import 'schema_generator.dart';

class SchemaUtilityGenerator {
  static String generateSchemaUtilities({
    required List<ObjectTypeDefinitionNode> objectTypes,
    required Set<String> enumNames,
    required Set<String> inputNames,
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    List<UnionTypeDefinitionNode> unionTypes = const [],
    List<InterfaceTypeDefinitionNode> interfaceTypes = const [],
  }) {
    final buffer = StringBuffer();
    final queryType = objectTypes.firstWhere((o) => o.name.value == 'Query',
        orElse: () => ObjectTypeDefinitionNode(
            name: NameNode(value: 'Query'), fields: []));
    final mutationType = objectTypes.firstWhere(
        (o) => o.name.value == 'Mutation',
        orElse: () => ObjectTypeDefinitionNode(
            name: NameNode(value: 'Mutation'), fields: []));

    final subscriptionType = objectTypes.firstWhere(
        (o) => o.name.value == 'Subscription',
        orElse: () => ObjectTypeDefinitionNode(
            name: NameNode(value: 'Subscription'), fields: []));

    final allFields = [
      ...queryType.fields.map((f) => (field: f, opType: 'query')),
      ...mutationType.fields.map((f) => (field: f, opType: 'mutation')),
      ...subscriptionType.fields.map((f) => (field: f, opType: 'subscription')),
    ];

    if (allFields.isEmpty) {
      return '';
    }

    final objectTypeMap = {for (final o in objectTypes) o.name.value: o};
    final unionTypeMap = {for (final u in unionTypes) u.name.value: u};
    final interfaceTypeMap = {for (final i in interfaceTypes) i.name.value: i};

    // Memoizes buildSelectionSetNode's top-level result by return type name
    // across this loop — a CRUD-style schema commonly has several
    // query/mutation fields returning the same object type (e.g. `User`
    // from both `updateUser` and `createUser`), which would otherwise each
    // re-walk that type's whole subtree from scratch. Keyed by the
    // unwrapped type name (buildSelectionSetNode itself resolves `User`,
    // `User!`, and `[User!]!` to the same subtree), scoped to this one
    // generateSchemaUtilities call only.
    final selectionSetMemo = <String, SelectionSetNode?>{};

    // 1. Generate Vars & Req classes for each schema operation field
    for (final item in allFields) {
      final field = item.field;
      final opType = item.opType;
      final rawName = field.name.value;
      final name = rawName.pascalCase;
      final reqClassName = '${name}Req';
      final varsClassName = '${name}Vars';
      final returnTypeInfo = SchemaGenerator.parseFieldType(field.type,
          enumNames: enumNames,
          inputNames: inputNames,
          scalarNames: scalarNames,
          customScalars: customScalars);
      final modelClassName = returnTypeInfo.dartType;

      // 1a. Generate Vars Class
      final varFields = <String, FieldTypeInfo>{};
      for (final arg in field.args) {
        final argTypeInfo = SchemaGenerator.parseFieldType(arg.type,
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
            customScalars: customScalars);
        final defaultValueStr = SchemaGenerator.formatDefaultValue(
            arg.defaultValue,
            dartType: argTypeInfo.dartType);
        varFields[arg.name.value] = FieldTypeInfo(
          dartType: argTypeInfo.dartType,
          isRequired: defaultValueStr == null && argTypeInfo.isRequired,
          defaultValue: defaultValueStr,
        );
      }
      buffer.writeln(codegen.emitSpec(codegen.freezedDataClass(
        className: varsClassName,
        fields: varFields,
        includeIfNull: false,
      )));

      // 1b. Generate Request Class
      final argsStr = field.args
          .map((a) => '\$${a.name.value}: ${_typeToGql(a.type)}')
          .join(', ');
      final callArgsStr = field.args
          .map((a) => '${a.name.value}: \$${a.name.value}')
          .join(', ');

      final returnTypeName = SchemaGenerator.unwrapTypeName(field.type);
      final selSetNode = selectionSetMemo.containsKey(returnTypeName)
          ? selectionSetMemo[returnTypeName]
          : selectionSetMemo[returnTypeName] = buildSelectionSetNode(
              type: field.type,
              objectTypesByName: objectTypeMap,
              unionTypesByName: unionTypeMap,
              interfaceTypesByName: interfaceTypeMap,
              enumNames: enumNames,
              scalarNames: scalarNames,
              customScalars: customScalars,
            );
      final selSetStr = selSetNode != null
          ? ' ${printNode(selSetNode).replaceAll(RegExp(r'\s+'), ' ')}'
          : '';
      final docStr =
          '$opType $name${argsStr.isNotEmpty ? "($argsStr)" : ""} { $rawName${callArgsStr.isNotEmpty ? "($callArgsStr)" : ""}$selSetStr }';

      buffer.writeln(codegen.emitSpec(codegen.freezedRequestClass(
        reqClassName: reqClassName,
        varsClassName: varsClassName,
        modelClassName: modelClassName,
        docStr: docStr,
        operationName: name,
        parseDataExpr: _generateParseDataExpr(modelClassName, rawName,
            enumNames: enumNames),
      )));
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
          enumNames: enumNames,
          inputNames: inputNames,
          customScalars: customScalars);
      final returnTypeModel = returnTypeInfo.dartType;

      final fieldArgs = <String, FieldTypeInfo>{};
      for (final arg in field.args) {
        final argTypeInfo = SchemaGenerator.parseFieldType(arg.type,
            enumNames: enumNames,
            inputNames: inputNames,
            customScalars: customScalars);
        fieldArgs[arg.name.value] = FieldTypeInfo(
          dartType: argTypeInfo.dartType,
          isRequired: argTypeInfo.isRequired,
          defaultValue: SchemaGenerator.formatDefaultValue(arg.defaultValue,
              dartType: argTypeInfo.dartType),
        );
      }
      final emitMethods = item.opType == 'subscription'
          ? codegen.emitSubscriptionMethod
          : codegen.emitOperationMethodTriple;
      buffer.writeln(emitMethods(
        methodName: methodName,
        modelClassName: returnTypeModel,
        reqClassName: reqClassName,
        varsClassName: varsClassName,
        args: fieldArgs,
      ));
    }

    buffer.writeln('}');
    buffer.writeln();

    return buffer.toString();
  }

  static bool _isScalarOrEnum(
    String typeName, {
    required Set<String> enumNames,
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
  }) {
    if (customScalars.containsKey(typeName) ||
        customScalars.containsKey(typeName.pascalCase)) {
      return true;
    }
    switch (typeName) {
      case 'String':
      case 'Int':
      case 'Float':
      case 'Double':
      case 'Boolean':
      case 'ID':
      case 'ObjectID':
      case 'UUID':
      case 'DateTime':
      case 'Date':
      case 'Timestamp':
      case 'URI':
      case 'Url':
      case 'URL':
      case 'BigInt':
      case 'Upload':
      case 'JSON':
      case 'JsonObject':
        return true;
    }
    final pascal = typeName.pascalCase;
    if (scalarNames.contains(typeName) || scalarNames.contains(pascal)) {
      return true;
    }
    if (enumNames.contains(pascal) || enumNames.contains(typeName)) {
      return true;
    }
    return false;
  }

  /// Recursively builds an AST [SelectionSetNode] for a schema return type,
  /// skipping fields with required arguments and preventing cycle loops.
  static SelectionSetNode? buildSelectionSetNode({
    required TypeNode type,
    required Map<String, ObjectTypeDefinitionNode> objectTypesByName,
    Map<String, UnionTypeDefinitionNode> unionTypesByName = const {},
    Map<String, InterfaceTypeDefinitionNode> interfaceTypesByName = const {},
    Set<String> enumNames = const {},
    Set<String> inputNames = const {},
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    Set<String> ancestors = const {},
    int depth = 0,
    int maxDepth = 6,
  }) {
    final typeName = SchemaGenerator.unwrapTypeName(type);
    if (_isScalarOrEnum(
      typeName,
      enumNames: enumNames,
      scalarNames: scalarNames,
      customScalars: customScalars,
    )) {
      return null;
    }

    if (ancestors.contains(typeName) || depth >= maxDepth) {
      return null;
    }

    if (objectTypesByName.containsKey(typeName)) {
      if (typeName == 'Query' ||
          typeName == 'Mutation' ||
          typeName == 'Subscription') {
        return null;
      }
      final objType = objectTypesByName[typeName]!;
      final selections = <SelectionNode>[];
      final nextAncestors = {...ancestors, typeName};

      for (final field in objType.fields) {
        final hasRequiredArg =
            field.args.any((a) => a.type.isNonNull && a.defaultValue == null);
        if (hasRequiredArg) continue;

        final fieldName = field.name.value;
        final fieldTypeName = SchemaGenerator.unwrapTypeName(field.type);

        if (_isScalarOrEnum(
              fieldTypeName,
              enumNames: enumNames,
              scalarNames: scalarNames,
              customScalars: customScalars,
            ) ||
            (!objectTypesByName.containsKey(fieldTypeName) &&
                !unionTypesByName.containsKey(fieldTypeName) &&
                !interfaceTypesByName.containsKey(fieldTypeName))) {
          selections.add(FieldNode(name: NameNode(value: fieldName)));
        } else {
          final subSet = buildSelectionSetNode(
            type: field.type,
            objectTypesByName: objectTypesByName,
            unionTypesByName: unionTypesByName,
            interfaceTypesByName: interfaceTypesByName,
            enumNames: enumNames,
            scalarNames: scalarNames,
            customScalars: customScalars,
            ancestors: nextAncestors,
            depth: depth + 1,
            maxDepth: maxDepth,
          );
          if (subSet != null && subSet.selections.isNotEmpty) {
            selections.add(FieldNode(
              name: NameNode(value: fieldName),
              selectionSet: subSet,
            ));
          }
        }
      }

      if (selections.isEmpty) {
        selections.add(FieldNode(name: NameNode(value: '__typename')));
      }

      return SelectionSetNode(selections: selections);
    }

    if (interfaceTypesByName.containsKey(typeName)) {
      final ifaceType = interfaceTypesByName[typeName]!;
      final selections = <SelectionNode>[];
      final nextAncestors = {...ancestors, typeName};

      for (final field in ifaceType.fields) {
        final hasRequiredArg =
            field.args.any((a) => a.type.isNonNull && a.defaultValue == null);
        if (hasRequiredArg) continue;

        final fieldName = field.name.value;
        final fieldTypeName = SchemaGenerator.unwrapTypeName(field.type);

        if (_isScalarOrEnum(
              fieldTypeName,
              enumNames: enumNames,
              scalarNames: scalarNames,
              customScalars: customScalars,
            ) ||
            (!objectTypesByName.containsKey(fieldTypeName) &&
                !unionTypesByName.containsKey(fieldTypeName) &&
                !interfaceTypesByName.containsKey(fieldTypeName))) {
          selections.add(FieldNode(name: NameNode(value: fieldName)));
        } else {
          final subSet = buildSelectionSetNode(
            type: field.type,
            objectTypesByName: objectTypesByName,
            unionTypesByName: unionTypesByName,
            interfaceTypesByName: interfaceTypesByName,
            enumNames: enumNames,
            scalarNames: scalarNames,
            customScalars: customScalars,
            ancestors: nextAncestors,
            depth: depth + 1,
            maxDepth: maxDepth,
          );
          if (subSet != null && subSet.selections.isNotEmpty) {
            selections.add(FieldNode(
              name: NameNode(value: fieldName),
              selectionSet: subSet,
            ));
          }
        }
      }

      if (selections.isEmpty) {
        selections.add(FieldNode(name: NameNode(value: '__typename')));
      }

      return SelectionSetNode(selections: selections);
    }

    if (unionTypesByName.containsKey(typeName)) {
      final unionType = unionTypesByName[typeName]!;
      final selections = <SelectionNode>[
        FieldNode(name: NameNode(value: '__typename')),
      ];
      final nextAncestors = {...ancestors, typeName};

      for (final member in unionType.types) {
        final memberSet = buildSelectionSetNode(
          type: member,
          objectTypesByName: objectTypesByName,
          unionTypesByName: unionTypesByName,
          interfaceTypesByName: interfaceTypesByName,
          enumNames: enumNames,
          scalarNames: scalarNames,
          customScalars: customScalars,
          ancestors: nextAncestors,
          depth: depth + 1,
          maxDepth: maxDepth,
        );
        if (memberSet != null && memberSet.selections.isNotEmpty) {
          selections.add(InlineFragmentNode(
            typeCondition: TypeConditionNode(
              on: NamedTypeNode(name: NameNode(value: member.name.value)),
            ),
            selectionSet: memberSet,
          ));
        }
      }

      return SelectionSetNode(selections: selections);
    }

    return null;
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

  static String _generateParseDataExpr(
    String modelClassName,
    String rawName, {
    Set<String> enumNames = const {},
  }) {
    if (_isPrimitive(modelClassName)) {
      return '(json["$rawName"] ?? json) as $modelClassName';
    } else if (enumNames.contains(modelClassName)) {
      return '$modelClassName.values.firstWhere((e) => e.name.toLowerCase() == (json["$rawName"] as String? ?? "").toLowerCase(), orElse: () => $modelClassName.values.first)';
    } else if (modelClassName.startsWith('List<') &&
        modelClassName.endsWith('>')) {
      final inner =
          modelClassName.substring(5, modelClassName.length - 1).trim();
      if (_isPrimitive(inner)) {
        return '((json["$rawName"] as List<dynamic>?) ?? (json is List ? json as List<dynamic> : null))?.map((e) => e as $inner).toList() ?? <$inner>[]';
      } else if (enumNames.contains(inner)) {
        return '((json["$rawName"] as List<dynamic>?) ?? (json is List ? json as List<dynamic> : null))?.map((e) => $inner.values.firstWhere((val) => val.name.toLowerCase() == (e as String? ?? "").toLowerCase(), orElse: () => $inner.values.first)).toList() ?? <$inner>[]';
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
