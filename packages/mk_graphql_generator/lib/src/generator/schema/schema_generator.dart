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
  static Map<String, String> generateEnums(List<EnumTypeDefinitionNode> enums) {
    final result = <String, String>{};
    final enumExports = <String>[];

    for (final enumDef in enums) {
      final name = enumDef.name.value.pascalCase;
      final fileName = '${enumDef.name.value.snakeCase}_enum.dart';
      final buffer = StringBuffer();

      buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      buffer.writeln('// ignore_for_file: type=lint');
      buffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
      buffer.writeln();
      buffer.writeln(codegen.emitSpec(codegen.jsonEnum(
        name: name,
        values: {
          // e.g. ADMIN_USER (wire) -> adminUser (Dart)
          for (final val in enumDef.values)
            val.name.value: _toDartEnumValue(val.name.value),
        },
      )));

      result['enums/$fileName'] = buffer.toString();
      enumExports.add("export '$fileName';");
    }

    if (enumExports.isNotEmpty) {
      final barrelBuffer = StringBuffer();
      barrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      barrelBuffer.writeln('// ignore_for_file: type=lint');
      for (final exp in enumExports) {
        barrelBuffer.writeln(exp);
      }
      result['enums/enums.dart'] = barrelBuffer.toString();
    }

    return result;
  }

  static Map<String, String> generateInputs(
    List<InputObjectTypeDefinitionNode> inputs,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    final result = <String, String>{};
    final inputExports = <String>[];

    for (final inputDef in inputs) {
      final name = inputDef.name.value.pascalCase;
      final fileName = '${inputDef.name.value.snakeCase}.dart';
      final buffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      var needsEnumImport = false;
      var needsInputImport = false;
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
        if (inputNames.contains(baseType) && baseType != name)
          needsInputImport = true;
      }

      buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      buffer.writeln('// ignore_for_file: type=lint');
      buffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
      if (needsInputImport) {
        buffer.writeln("import '${resolveGeneratedImport(
          packageName: packageName,
          generatedDir: generatedDir,
          targetSubDir: 'inputs',
          targetFile: 'inputs.dart',
          fromSubDir: 'inputs',
        )}';");
      }
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
      buffer.writeln("part '${inputDef.name.value.snakeCase}.freezed.dart';");
      buffer.writeln("part '${inputDef.name.value.snakeCase}.g.dart';");
      buffer.writeln();

      _generateFreezedClass(
          className: name, fields: fields, buffer: buffer, isInput: true);

      result['inputs/$fileName'] = buffer.toString();
      inputExports.add("export '$fileName';");
    }

    if (inputExports.isNotEmpty) {
      final barrelBuffer = StringBuffer();
      barrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      barrelBuffer.writeln('// ignore_for_file: type=lint');
      for (final exp in inputExports) {
        barrelBuffer.writeln(exp);
      }
      result['inputs/inputs.dart'] = barrelBuffer.toString();
    }

    return result;
  }

  static Map<String, String> generateObjectTypes(
    List<ObjectTypeDefinitionNode> objects,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    final result = <String, String>{};
    final modelExports = <String>[];

    for (final obj in objects) {
      if (obj.name.value == 'Query' ||
          obj.name.value == 'Mutation' ||
          obj.name.value == 'Subscription') {
        continue;
      }

      final rawName = obj.name.value;
      final className = '${rawName.pascalCase}Model';
      final fileName = '${rawName.snakeCase}_model.dart';
      final buffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      var needsEnumImport = false;
      var needsInputImport = false;
      var needsModelImport = false;
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
        if (baseType.endsWith('Model') && baseType != className)
          needsModelImport = true;
      }

      buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      buffer.writeln('// ignore_for_file: type=lint');
      buffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
      if (needsModelImport) {
        buffer.writeln("import '${resolveGeneratedImport(
          packageName: packageName,
          generatedDir: generatedDir,
          targetSubDir: 'models',
          targetFile: 'models.dart',
          fromSubDir: 'models',
        )}';");
      }
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
      buffer.writeln("part '${rawName.snakeCase}_model.freezed.dart';");
      buffer.writeln("part '${rawName.snakeCase}_model.g.dart';");
      buffer.writeln();

      _generateFreezedClass(
          className: className, fields: fields, buffer: buffer);

      result['models/$fileName'] = buffer.toString();
      modelExports.add("export '$fileName';");
    }

    if (modelExports.isNotEmpty) {
      final barrelBuffer = StringBuffer();
      barrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      barrelBuffer.writeln('// ignore_for_file: type=lint');
      for (final exp in modelExports) {
        barrelBuffer.writeln(exp);
      }
      result['models/models.dart'] = barrelBuffer.toString();
    }

    return result;
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

  /// Every reserved/built-in/pseudo keyword Dart's own scanner recognizes
  /// (`package:_fe_analyzer_shared`'s `Keyword` table — reserved words like
  /// `class`/`for`, built-in identifiers like `late`/`required`, and pseudo
  /// keywords like `await`/`sealed`/`when`), lower-cased — `Function` is the
  /// only entry there that's capitalized, and since generated field names
  /// are always camelCased with a lowercase first letter they can never
  /// collide with it.
  ///
  /// Plus a handful of `dart:core` type names (`int`/`double`/`bool`/`num`)
  /// that aren't keywords at all but are just as unsafe as a field name:
  /// declaring `final double double;` shadows `double` the *type* for the
  /// rest of the enclosing class, breaking any other member that's actually
  /// typed `double`. `dynamic`/`void` are already covered above as true
  /// keywords; `String`/`List`/`Map`/etc. are capitalized and so never
  /// collide with a camelCased field name either.
  static const _dartKeywords = {
    'abstract',
    'as',
    'assert',
    'async',
    'augment',
    'await',
    'base',
    'bool',
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
    'double',
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
    'inout',
    'int',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'native',
    'new',
    'null',
    'num',
    'of',
    'on',
    'operator',
    'out',
    'part',
    'patch',
    'required',
    'rethrow',
    'return',
    'sealed',
    'set',
    'show',
    'source',
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
  };

  static String safeIdentifier(String name) {
    final camel = name.camelCase;
    return _dartKeywords.contains(camel) ? 'g${camel.pascalCase}' : camel;
  }

  /// Converts a SCREAMING_SNAKE_CASE GraphQL enum value to a Dart camelCase identifier.
  /// e.g. `ADMIN_USER` → `adminUser`, `ADMIN` → `admin`.
  static String _toDartEnumValue(String wireValue) {
    return safeIdentifier(wireValue);
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
        return '$cleanType.${safeIdentifier(val)}';
      }
      return safeIdentifier(val);
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
