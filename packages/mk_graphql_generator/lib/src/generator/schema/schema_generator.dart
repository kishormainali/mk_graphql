import 'dart:convert';
import 'package:gql/ast.dart';
import 'package:recase/recase.dart';
import '../dart_codegen.dart' as codegen;

/// Builds an import for a file that lives at
/// `<generatedDir>/<targetSubDir>/<targetFile>`, importing it from a file
/// that lives at `<generatedDir>/<fromSubDir>/...`.
///
/// When [packageName] is known and [generatedDir] sits under `lib/`, this
/// returns a `package:` import (stable regardless of how deeply nested the
/// importing file is). Otherwise it falls back to a relative import between
/// the two sibling subdirectories.
String resolveGeneratedImport({
  required String? packageName,
  required String generatedDir,
  required String targetSubDir,
  required String targetFile,
  required String fromSubDir,
}) {
  final normalizedGeneratedDir = generatedDir.replaceAll('\\', '/');
  if (packageName != null && normalizedGeneratedDir.startsWith('lib/')) {
    final packageRelativeDir = normalizedGeneratedDir.substring('lib/'.length);
    return 'package:$packageName/$packageRelativeDir/$targetSubDir/$targetFile';
  }
  if (targetSubDir == fromSubDir) return targetFile;
  return '../$targetSubDir/$targetFile';
}

class FieldTypeInfo {
  final String dartType;
  final bool isRequired;
  final String? defaultValue;

  const FieldTypeInfo({
    required this.dartType,
    required this.isRequired,
    this.defaultValue,
  });
}

class SchemaGenerator {
  /// Every schema enum, declared inline in one `enums/enums.dart` — not one
  /// file per enum plus a barrel of exports. This keeps the schema file's
  /// declared build_runner outputs fixed regardless of how many enums the
  /// schema defines; see
  /// docs/superpowers/specs/2026-09-25-generator-barrel-file-merge-design.md.
  /// Enums need no `part` directive — `@JsonEnum()`/`@JsonValue(...)` are
  /// consumed at runtime by json_annotation and by *other* classes'
  /// generated `.g.dart`, never by a companion file of their own.
  static Map<String, String> generateEnums(List<EnumTypeDefinitionNode> enums) {
    if (enums.isEmpty) return const {};

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: type=lint');
    buffer.writeln(
        "import 'package:freezed_annotation/freezed_annotation.dart';");
    buffer.writeln();

    for (final enumDef in enums) {
      final name = enumDef.name.value.pascalCase;
      buffer.writeln(codegen.emitSpec(codegen.jsonEnum(
        name: name,
        values: {
          // e.g. ADMIN_USER (wire) -> adminUser (Dart)
          for (final val in enumDef.values)
            val.name.value: _toDartEnumValue(val.name.value),
        },
      )));
    }

    return {'enums/enums.dart': buffer.toString()};
  }

  /// Every schema input type, declared inline in one `inputs/inputs.dart`
  /// with a single shared `part 'inputs.freezed.dart'; part 'inputs.g.dart';`
  /// pair — not one file per input plus a barrel of exports. Same rationale
  /// as [generateEnums]. An input referencing another input type needs no
  /// import at all now — both live in this same file — unlike an input
  /// referencing an enum, which is still a genuine cross-file (cross-
  /// category) reference to `enums/enums.dart`.
  static Map<String, String> generateInputs(
    List<InputObjectTypeDefinitionNode> inputs,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    if (inputs.isEmpty) return const {};

    var needsEnumImport = false;
    final classBuffers = <StringBuffer>[];

    for (final inputDef in inputs) {
      final name = inputDef.name.value.pascalCase;
      final classBuffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      for (final field in inputDef.fields) {
        final rawFieldName = field.name.value;
        final typeInfo = parseFieldType(field.type,
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
            customScalars: customScalars);
        final defaultValueStr =
            formatDefaultValue(field.defaultValue, dartType: typeInfo.dartType);
        fields[rawFieldName] = FieldTypeInfo(
          dartType: typeInfo.dartType,
          isRequired: defaultValueStr == null && typeInfo.isRequired,
          defaultValue: defaultValueStr,
        );
        final baseType = _unwrapDartType(typeInfo.dartType);
        if (enumNames.contains(baseType)) needsEnumImport = true;
      }

      _generateFreezedClass(
          className: name, fields: fields, buffer: classBuffer, isInput: true);
      classBuffers.add(classBuffer);
    }

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: type=lint');
    buffer.writeln(
        "import 'package:freezed_annotation/freezed_annotation.dart';");
    if (needsEnumImport) {
      buffer.writeln("import '${resolveGeneratedImport(
        packageName: packageName,
        generatedDir: generatedDir,
        targetSubDir: 'enums',
        targetFile: 'enums.dart',
        fromSubDir: 'inputs',
      )}';");
    }
    buffer.writeln();
    buffer.writeln("part 'inputs.freezed.dart';");
    buffer.writeln("part 'inputs.g.dart';");
    buffer.writeln();
    for (final classBuffer in classBuffers) {
      buffer.write(classBuffer);
    }

    return {'inputs/inputs.dart': buffer.toString()};
  }

  /// Every non-root (`Query`/`Mutation`/`Subscription` excluded) schema
  /// object type, declared inline in one `models/models.dart` with a single
  /// shared `part 'models.freezed.dart'; part 'models.g.dart';` pair — not
  /// one file per type plus a barrel of exports. Same rationale as
  /// [generateEnums]. A model referencing another model type — including
  /// itself, e.g. `type User { friend: User }` — needs no import at all
  /// now: every model lives in this same file, so the old
  /// `baseType != className` self-reference guard (and the whole
  /// models.dart-importing-itself case it guarded against) no longer
  /// applies to anything and is removed rather than kept as dead code.
  static Map<String, String> generateObjectTypes(
    List<ObjectTypeDefinitionNode> objects,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    final filtered = objects
        .where((o) =>
            o.name.value != 'Query' &&
            o.name.value != 'Mutation' &&
            o.name.value != 'Subscription')
        .toList();
    if (filtered.isEmpty) return const {};

    var needsEnumImport = false;
    var needsInputImport = false;
    final classBuffers = <StringBuffer>[];

    for (final obj in filtered) {
      final rawName = obj.name.value;
      final className = '${rawName.pascalCase}Model';
      final classBuffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      for (final field in obj.fields) {
        final rawFieldName = field.name.value;
        final typeInfo = parseFieldType(field.type,
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
            customScalars: customScalars);
        fields[rawFieldName] = typeInfo;
        final baseType = _unwrapDartType(typeInfo.dartType);
        if (enumNames.contains(baseType)) needsEnumImport = true;
        if (inputNames.contains(baseType)) needsInputImport = true;
      }

      _generateFreezedClass(
          className: className, fields: fields, buffer: classBuffer);
      classBuffers.add(classBuffer);
    }

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: type=lint');
    buffer.writeln(
        "import 'package:freezed_annotation/freezed_annotation.dart';");
    if (needsEnumImport) {
      buffer.writeln("import '${resolveGeneratedImport(
        packageName: packageName,
        generatedDir: generatedDir,
        targetSubDir: 'enums',
        targetFile: 'enums.dart',
        fromSubDir: 'models',
      )}';");
    }
    if (needsInputImport) {
      buffer.writeln("import '${resolveGeneratedImport(
        packageName: packageName,
        generatedDir: generatedDir,
        targetSubDir: 'inputs',
        targetFile: 'inputs.dart',
        fromSubDir: 'models',
      )}';");
    }
    buffer.writeln();
    buffer.writeln("part 'models.freezed.dart';");
    buffer.writeln("part 'models.g.dart';");
    buffer.writeln();
    for (final classBuffer in classBuffers) {
      buffer.write(classBuffer);
    }

    return {'models/models.dart': buffer.toString()};
  }

  static FieldTypeInfo parseFieldType(
    TypeNode type, {
    required Set<String> enumNames,
    required Set<String> inputNames,
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
  }) {
    final isRequired = type.isNonNull;
    final innerType = _formatTypeNode(type,
        enumNames: enumNames,
        inputNames: inputNames,
        scalarNames: scalarNames,
        customScalars: customScalars);
    return FieldTypeInfo(dartType: innerType, isRequired: isRequired);
  }

  static String _formatTypeNode(
    TypeNode type, {
    required Set<String> enumNames,
    required Set<String> inputNames,
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
  }) {
    if (type is NamedTypeNode) {
      return formatNamedType(type.name.value,
          enumNames: enumNames,
          inputNames: inputNames,
          scalarNames: scalarNames,
          customScalars: customScalars);
    } else if (type is ListTypeNode) {
      final elementType = type.type;
      final inner = _formatTypeNode(elementType,
          enumNames: enumNames,
          inputNames: inputNames,
          scalarNames: scalarNames,
          customScalars: customScalars);
      return 'List<$inner>';
    }
    return 'dynamic';
  }

  /// Public — also used by [GeneratorOrchestrator] for schema-aware type resolution.
  static String formatNamedType(
    String rawName, {
    required Set<String> enumNames,
    required Set<String> inputNames,
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
  }) {
    if (customScalars.containsKey(rawName)) {
      return customScalars[rawName]!;
    }
    if (customScalars.containsKey(rawName.pascalCase)) {
      return customScalars[rawName.pascalCase]!;
    }

    switch (rawName) {
      case 'String':
      case 'ID':
      case 'ObjectID':
      case 'UUID':
        return 'String';
      case 'Int':
        return 'int';
      case 'Float':
      case 'Double':
        return 'double';
      case 'Boolean':
        return 'bool';
      case 'DateTime':
      case 'Date':
      case 'Timestamp':
        return 'DateTime';
      case 'URI':
      case 'Url':
      case 'URL':
        return 'Uri';
      case 'BigInt':
        return 'BigInt';
      case 'Upload':
        return 'MultipartFile';
      case 'JSON':
      case 'JsonObject':
        return 'Map<String, dynamic>';
      default:
        final pascal = rawName.pascalCase;
        if (scalarNames.contains(rawName) || scalarNames.contains(pascal)) {
          return 'String';
        }
        if (enumNames.contains(pascal) ||
            inputNames.contains(pascal) ||
            pascal.endsWith('Input') ||
            pascal.endsWith('Model') ||
            _isPrimitive(pascal)) {
          return pascal;
        }
        return '${pascal}Model';
    }
  }

  /// Unwraps NonNull and List wrappers to get the base named type (e.g. `[User!]!` → `'User'`).
  static String unwrapTypeName(TypeNode type) {
    if (type is NamedTypeNode) return type.name.value;
    if (type is ListTypeNode) return unwrapTypeName(type.type);
    return 'dynamic';
  }

  /// Returns true if the outermost (after stripping NonNull) type node is a list.
  static bool isListType(TypeNode type) => type is ListTypeNode;

  /// Reserved words, built-ins, and contextual keywords Dart's scanner
  /// recognizes, plus `dart:core` type names that are just as unsafe as a
  /// field name (e.g. `final double double;` shadows the *type* `double`
  /// for the rest of the enclosing class). Lower-cased to match against
  /// `name.camelCase`, which always lowercases the first letter — so e.g.
  /// `Function`/`String`/`List` here are the lower-cased forms `function`/
  /// `string`/`list`.
  static const _dartKeywords = {
    // Reserved words, built-ins, and contextual keywords
    'abstract',
    'as',
    'assert',
    'async',
    'augment',
    'await',
    'base',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'sealed',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'when',
    'while',
    'with',
    'yield',

    // Core Data Types
    'bigInt',
    'bool',
    'double',
    'int',
    'list',
    'map',
    'never',
    'num',
    'object',
    'record',
    'runes',
    'string',
    'symbol',
  };

  static String safeIdentifier(String name) {
    final camel = name.camelCase;
    return _dartKeywords.contains(camel) ? 'g${camel.pascalCase}' : camel;
  }

  /// Converts a SCREAMING_SNAKE_CASE GraphQL enum value to a Dart camelCase identifier.
  /// e.g. `ADMIN_USER` → `adminUser`, `ADMIN` → `admin`.
  /// Also escapes `value`/`fromString`, which would clash with the members
  /// [codegen.jsonEnum] adds to every enum (`g` prefix, like keywords).
  static String _toDartEnumValue(String wireValue) {
    final id = safeIdentifier(wireValue);
    return id == 'value' || id == 'fromString' ? 'g${id.pascalCase}' : id;
  }

  static String? formatDefaultValue(ValueNode? node, {String? dartType}) {
    if (node == null) return null;
    if (node is IntValueNode) return node.value;
    if (node is FloatValueNode) return node.value;
    if (node is StringValueNode) return jsonEncode(node.value);
    if (node is BooleanValueNode) return node.value ? 'true' : 'false';
    if (node is EnumValueNode) {
      final val = node.name.value;
      if (dartType != null && dartType.isNotEmpty) {
        final cleanType = dartType.endsWith('?')
            ? dartType.substring(0, dartType.length - 1)
            : dartType;
        return '$cleanType.${_toDartEnumValue(val)}';
      }
      return _toDartEnumValue(val);
    }
    if (node is NullValueNode) return 'null';
    if (node is ListValueNode) {
      final items = node.values.map((v) => formatDefaultValue(v)).join(', ');
      return 'const [$items]';
    }
    return null;
  }

  // Input objects are sent to the server, so an unset optional field must be
  // omitted from toJson() rather than sent as explicit `null` — some servers
  // treat the two differently (e.g. an omitted filter field is ignored, an
  // explicit `field: null` can exclude matches). Response Model classes have
  // no such concern, so they default to serializing `null` explicitly.
  static void _generateFreezedClass({
    required String className,
    required Map<String, FieldTypeInfo> fields,
    required StringBuffer buffer,
    bool isInput = false,
  }) {
    buffer.writeln(codegen.emitSpec(codegen.freezedDataClass(
      className: className,
      fields: fields,
      includeIfNull: !isInput,
    )));
  }

  /// Strips `List<...>` wrappers and a trailing `?` to get the base type
  /// name, e.g. `List<UserRole?>` → `UserRole`.
  static String _unwrapDartType(String dartType) {
    var t = dartType;
    while (t.startsWith('List<') && t.endsWith('>')) {
      t = t.substring(5, t.length - 1);
    }
    if (t.endsWith('?')) t = t.substring(0, t.length - 1);
    return t;
  }

  static bool _isPrimitive(String type) {
    return type == 'String' ||
        type == 'int' ||
        type == 'double' ||
        type == 'bool' ||
        type == 'DateTime' ||
        type == 'MultipartFile' ||
        type == 'Map<String, dynamic>' ||
        type == 'dynamic';
  }
}
