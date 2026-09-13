import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:mk_graphql_generator/src/formatter/graphql_formatter.dart';

/// Converts a GraphQL introspection JSON result map into standard GraphQL SDL string.
String introspectionToSdl(Map<String, dynamic> introspectionJson) {
  final dynamic root = introspectionJson['data'] ?? introspectionJson;
  final dynamic schemaData = root is Map ? (root['__schema'] ?? root) : root;

  if (schemaData is! Map<String, dynamic>) {
    throw ArgumentError(
        'Invalid introspection response: missing __schema in JSON.');
  }

  final definitions = <DefinitionNode>[];
  final rawTypes = (schemaData['types'] as List?)?.cast<dynamic>() ?? [];

  // 1. Check custom schema root operation types if non-standard
  final queryType = schemaData['queryType']?['name'] as String?;
  final mutationType = schemaData['mutationType']?['name'] as String?;
  final subscriptionType = schemaData['subscriptionType']?['name'] as String?;

  final hasNonStandardRoots = (queryType != null && queryType != 'Query') ||
      (mutationType != null && mutationType != 'Mutation') ||
      (subscriptionType != null && subscriptionType != 'Subscription');

  if (hasNonStandardRoots) {
    final ops = <OperationTypeDefinitionNode>[];
    if (queryType != null) {
      ops.add(OperationTypeDefinitionNode(
        operation: OperationType.query,
        type: NamedTypeNode(name: NameNode(value: queryType)),
      ));
    }
    if (mutationType != null) {
      ops.add(OperationTypeDefinitionNode(
        operation: OperationType.mutation,
        type: NamedTypeNode(name: NameNode(value: mutationType)),
      ));
    }
    if (subscriptionType != null) {
      ops.add(OperationTypeDefinitionNode(
        operation: OperationType.subscription,
        type: NamedTypeNode(name: NameNode(value: subscriptionType)),
      ));
    }
    if (ops.isNotEmpty) {
      definitions.add(SchemaDefinitionNode(operationTypes: ops));
    }
  }

  // 2. Types
  const builtInScalars = {'Int', 'Float', 'String', 'Boolean', 'ID'};

  for (final rawType in rawTypes) {
    if (rawType is! Map<String, dynamic>) continue;
    final name = rawType['name'] as String?;
    if (name == null || name.startsWith('__'))
      continue; // Skip introspection internals

    final kind = rawType['kind'] as String? ?? '';
    final description = _descriptionNode(rawType['description'] as String?);

    switch (kind) {
      case 'SCALAR':
        if (!builtInScalars.contains(name)) {
          definitions.add(ScalarTypeDefinitionNode(
            name: NameNode(value: name),
            description: description,
          ));
        }
        break;

      case 'OBJECT':
        definitions.add(ObjectTypeDefinitionNode(
          name: NameNode(value: name),
          description: description,
          interfaces: _buildInterfaces(rawType['interfaces'] as List?),
          fields: _buildFields(rawType['fields'] as List?),
        ));
        break;

      case 'INTERFACE':
        definitions.add(InterfaceTypeDefinitionNode(
          name: NameNode(value: name),
          description: description,
          fields: _buildFields(rawType['fields'] as List?),
        ));
        break;

      case 'UNION':
        definitions.add(UnionTypeDefinitionNode(
          name: NameNode(value: name),
          description: description,
          types: _buildUnionTypes(rawType['possibleTypes'] as List?),
        ));
        break;

      case 'ENUM':
        definitions.add(EnumTypeDefinitionNode(
          name: NameNode(value: name),
          description: description,
          values: _buildEnumValues(rawType['enumValues'] as List?),
        ));
        break;

      case 'INPUT_OBJECT':
        definitions.add(InputObjectTypeDefinitionNode(
          name: NameNode(value: name),
          description: description,
          fields: _buildInputFields(rawType['inputFields'] as List?),
        ));
        break;
    }
  }

  // 3. Custom Directives
  const builtInDirectives = {'skip', 'include', 'deprecated', 'specifiedBy'};
  final rawDirectives =
      (schemaData['directives'] as List?)?.cast<dynamic>() ?? [];

  for (final rawDir in rawDirectives) {
    if (rawDir is! Map<String, dynamic>) continue;
    final name = rawDir['name'] as String?;
    if (name == null || builtInDirectives.contains(name)) continue;

    final description = _descriptionNode(rawDir['description'] as String?);
    final rawLocations = (rawDir['locations'] as List?)?.cast<String>() ?? [];
    final locations = rawLocations.map(_parseDirectiveLocation).toList();
    final args = _buildInputFields(rawDir['args'] as List?);

    definitions.add(DirectiveDefinitionNode(
      name: NameNode(value: name),
      description: description,
      locations: locations,
      args: args,
    ));
  }

  final doc = DocumentNode(definitions: definitions);
  return formatGraphQL(doc);
}

StringValueNode? _descriptionNode(String? description) {
  if (description == null || description.trim().isEmpty) return null;
  return StringValueNode(
    value: description.trim(),
    isBlock: description.contains('\n'),
  );
}

List<NamedTypeNode> _buildInterfaces(List? rawInterfaces) {
  if (rawInterfaces == null) return const [];
  final list = <NamedTypeNode>[];
  for (final item in rawInterfaces) {
    if (item is Map<String, dynamic> && item['name'] != null) {
      list.add(NamedTypeNode(name: NameNode(value: item['name'] as String)));
    }
  }
  return list;
}

List<NamedTypeNode> _buildUnionTypes(List? rawPossibleTypes) {
  if (rawPossibleTypes == null) return const [];
  final list = <NamedTypeNode>[];
  for (final item in rawPossibleTypes) {
    if (item is Map<String, dynamic> && item['name'] != null) {
      list.add(NamedTypeNode(name: NameNode(value: item['name'] as String)));
    }
  }
  return list;
}

List<EnumValueDefinitionNode> _buildEnumValues(List? rawEnumValues) {
  if (rawEnumValues == null) return const [];
  final list = <EnumValueDefinitionNode>[];
  for (final val in rawEnumValues) {
    if (val is Map<String, dynamic> && val['name'] != null) {
      final directives = <DirectiveNode>[];
      if (val['isDeprecated'] == true) {
        final reason = val['deprecationReason'] as String?;
        directives.add(DirectiveNode(
          name: NameNode(value: 'deprecated'),
          arguments: reason != null
              ? [
                  ArgumentNode(
                    name: NameNode(value: 'reason'),
                    value: StringValueNode(value: reason, isBlock: false),
                  )
                ]
              : const [],
        ));
      }

      list.add(EnumValueDefinitionNode(
        name: NameNode(value: val['name'] as String),
        description: _descriptionNode(val['description'] as String?),
        directives: directives,
      ));
    }
  }
  return list;
}

List<FieldDefinitionNode> _buildFields(List? rawFields) {
  if (rawFields == null) return const [];
  final list = <FieldDefinitionNode>[];
  for (final f in rawFields) {
    if (f is Map<String, dynamic> && f['name'] != null && f['type'] != null) {
      final directives = <DirectiveNode>[];
      if (f['isDeprecated'] == true) {
        final reason = f['deprecationReason'] as String?;
        directives.add(DirectiveNode(
          name: NameNode(value: 'deprecated'),
          arguments: reason != null
              ? [
                  ArgumentNode(
                    name: NameNode(value: 'reason'),
                    value: StringValueNode(value: reason, isBlock: false),
                  )
                ]
              : const [],
        ));
      }

      list.add(FieldDefinitionNode(
        name: NameNode(value: f['name'] as String),
        description: _descriptionNode(f['description'] as String?),
        type: _buildTypeNode(f['type'] as Map<String, dynamic>),
        args: _buildInputFields(f['args'] as List?),
        directives: directives,
      ));
    }
  }
  return list;
}

List<InputValueDefinitionNode> _buildInputFields(List? rawInputFields) {
  if (rawInputFields == null) return const [];
  final list = <InputValueDefinitionNode>[];
  for (final f in rawInputFields) {
    if (f is Map<String, dynamic> && f['name'] != null && f['type'] != null) {
      list.add(InputValueDefinitionNode(
        name: NameNode(value: f['name'] as String),
        description: _descriptionNode(f['description'] as String?),
        type: _buildTypeNode(f['type'] as Map<String, dynamic>),
        defaultValue: _parseDefaultValue(f['defaultValue'] as String?),
      ));
    }
  }
  return list;
}

TypeNode _buildTypeNode(Map<String, dynamic> typeRef,
    {bool isNonNull = false}) {
  final kind = typeRef['kind'] as String;
  if (kind == 'NON_NULL') {
    final ofType = typeRef['ofType'] as Map<String, dynamic>;
    return _buildTypeNode(ofType, isNonNull: true);
  } else if (kind == 'LIST') {
    final ofType = typeRef['ofType'] as Map<String, dynamic>;
    return ListTypeNode(
      type: _buildTypeNode(ofType),
      isNonNull: isNonNull,
    );
  } else {
    final name = typeRef['name'] as String? ?? 'String';
    return NamedTypeNode(
      name: NameNode(value: name),
      isNonNull: isNonNull,
    );
  }
}

ValueNode? _parseDefaultValue(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed == 'null') return null;
  try {
    final doc = parseString('query { f(x: $trimmed) }');
    final op = doc.definitions.first as OperationDefinitionNode;
    final f = op.selectionSet.selections.first as FieldNode;
    return f.arguments.first.value;
  } catch (_) {
    // If not parseable as a literal, fallback to string
    return StringValueNode(value: trimmed, isBlock: false);
  }
}

DirectiveLocation _parseDirectiveLocation(String loc) {
  for (final value in DirectiveLocation.values) {
    if (value.name.toUpperCase() == loc.toUpperCase()) {
      return value;
    }
  }
  return DirectiveLocation.field;
}
