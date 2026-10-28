import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:recase/recase.dart';
import 'package:dart_style/dart_style.dart';
import '../../cache/generator_cache.dart';
import '../../parser/graphql_parser.dart';
import '../dart_codegen.dart' as codegen;
import '../schema/schema_generator.dart';
import '../schema/schema_utility_generator.dart';

class GeneratedBundle {
  final Map<String, String> files; // relative path -> file content

  GeneratedBundle({required this.files});

  String get varCode =>
      files.values.where((c) => c.contains('Vars')).join('\n');
  String get modelCode => files.values
      .where((c) => c.contains('Model') || c.contains('enum '))
      .join('\n');
  String get reqCode => files.values
      .where((c) => c.contains('Req extends GraphQLRequest'))
      .join('\n');
  String get barrelCode => files.entries
      .where((e) => e.key.endsWith('.gql.dart'))
      .map((e) => e.value)
      .join('\n');
}

/// Everything derived once, up front, from [content]/[schemaContent] and
/// the builder's path options — shared read-only context for every stage
/// of [GeneratorOrchestrator.generateForGraphQLFile] below (schema shared
/// files, schema utilities, per-operation generation, and root barrel
/// assembly all need most of these same values).
typedef _GenContext = ({
  ParsedGraphQLDocument parsed,
  String fileName,
  bool isSchemaFile,
  String inputDir,
  String resolvedSharedDir,
  String schemaGeneratedDir,
  String sharedPrefix,
  ParsedGraphQLDocument? schemaParsed,
  Map<String, ObjectTypeDefinitionNode> schemaObjectTypesByName,
  Map<String, UnionTypeDefinitionNode> schemaUnionTypesByName,
  Map<String, InterfaceTypeDefinitionNode> schemaInterfaceTypesByName,
  Set<String> enumNames,
  Set<String> inputNames,
  Set<String> scalarNames,
  Set<String> sharedModelNames,
});

/// What [GeneratorOrchestrator._generateOperations] produced, in the shape
/// [GeneratorOrchestrator._generateRootBarrel] needs to assemble the root
/// barrel file around it.
typedef _OperationsResult = ({
  String fileOpExtensionsText,
  List<({String exportPath, List<String> modelClasses})> opExports,
  Set<String> fragmentClassNames,
  String fragmentsFilePath,
});

class GeneratorOrchestrator {
  static Future<GeneratedBundle> generateForGraphQLFile({
    required String content,
    required String inputPath,
    String? schemaPath,
    String? sharedDir,
    // Raw schema SDL content for AST scanning. When provided the generator
    // resolves selection-set types against the real schema instead of
    // falling back to name-based heuristics.
    String? schemaContent,
    // The consuming project's own pub package name. When provided, imports
    // between generated files are emitted as `package:$packageName/...`
    // instead of relative paths — stable regardless of nesting depth.
    String? packageName,
    Map<String, String> customScalars = const {},
    bool useCache = true,
    // Reuses an already-parsed document instead of parsing [content] again
    // on a [GeneratorCache] miss — see [computeOutputPaths]'s matching
    // parameter for why [MkGraphQLBuilder] has one available to pass here.
    ParsedGraphQLDocument? preParsed,
  }) async {
    // Only process .graphql or .gql files
    if (!inputPath.endsWith('.graphql') && !inputPath.endsWith('.gql')) {
      return GeneratedBundle(files: const {});
    }

    String? cacheKey;
    if (useCache) {
      cacheKey = GeneratorCache.computeKey(
        inputPath: inputPath,
        content: content,
        schemaContent: schemaContent,
        sharedDir: sharedDir,
        packageName: packageName,
        customScalars: customScalars,
      );
      final cached = GeneratorCache.get(cacheKey);
      if (cached != null) {
        return cached;
      }
    }

    final parsed = preParsed ?? ParsedGraphQLDocument.parse(content);
    final ctx = _resolveGenerationContext(
      parsed: parsed,
      inputPath: inputPath,
      schemaPath: schemaPath,
      sharedDir: sharedDir,
      schemaContent: schemaContent,
    );

    final files = <String, String>{};

    // 1-3. Schema-derived shared files → {sharedPrefix}enums|inputs|models
    _generateSchemaSharedFiles(ctx, files,
        packageName: packageName, customScalars: customScalars);

    // 4. Schema utilities (Req / Vars / extension from Query & Mutation fields)
    final schemaUtilCode =
        _generateSchemaUtilitiesCode(ctx, customScalars: customScalars);

    // 5. Operations from feature .graphql / .gql files
    final ops = _generateOperations(ctx, files,
        packageName: packageName, customScalars: customScalars);

    // 6. Root barrel file: generated/{fileName}.gql.dart
    _generateRootBarrel(
      ctx,
      files,
      schemaUtilCode: schemaUtilCode,
      ops: ops,
      packageName: packageName,
    );

    // Format all generated Dart code
    final formattedFiles = await _formatGeneratedFiles(files);

    final bundle = GeneratedBundle(files: formattedFiles);
    if (useCache && cacheKey != null) {
      GeneratorCache.put(cacheKey, bundle);
    }
    return bundle;
  }

  /// Resolves every path/name-set derived from [inputPath]'s location, the
  /// schema/shared-dir options, and (when this isn't the schema file
  /// itself) [schemaContent] — the read-only inputs every later generation
  /// stage needs.
  static _GenContext _resolveGenerationContext({
    required ParsedGraphQLDocument parsed,
    required String inputPath,
    String? schemaPath,
    String? sharedDir,
    String? schemaContent,
  }) {
    // A file is the schema when its path matches schemaPath or its basename is 'schema'
    final fileName = p.basenameWithoutExtension(inputPath);
    final resolvedSchemaPath =
        schemaPath ?? p.join(p.dirname(inputPath), 'schema.graphql');
    final isSchemaFile = (schemaPath != null &&
            p.normalize(inputPath) == p.normalize(schemaPath)) ||
        fileName == 'schema';

    final schemaDir = p.dirname(resolvedSchemaPath);
    final inputDir = p.dirname(inputPath);

    final resolvedSharedDir = sharedDir != null && sharedDir.trim().isNotEmpty
        ? p.normalize(sharedDir.trim())
        : p.normalize(p.join(schemaDir, 'generated'));
    final schemaGeneratedDir = resolvedSharedDir.replaceAll('\\', '/');

    final sharedRelPath = p
        .normalize(p.relative(resolvedSharedDir, from: inputDir))
        .replaceAll('\\', '/');
    final sharedPrefix = sharedRelPath == '.' ? '' : '$sharedRelPath/';

    // -----------------------------------------------------------------------
    // Parse schema AST for type resolution
    // -----------------------------------------------------------------------
    // For a schema file we use the parsed content itself.
    // For feature files we use the provided schemaContent (loaded by builder).
    ParsedGraphQLDocument? schemaParsed;
    if (isSchemaFile) {
      schemaParsed = parsed; // schema IS its own type source
    } else if (schemaContent != null && schemaContent.isNotEmpty) {
      try {
        schemaParsed = ParsedGraphQLDocument.parse(schemaContent);
      } catch (e) {
        stderr.writeln(
          'mk_graphql_generator: failed to parse schema for $inputPath '
          '($e) — generating without schema-derived types (utility '
          'selection sets, enums, custom scalars) for this file.',
        );
      }
    }

    // Fast-lookup maps keyed by GraphQL type name
    final schemaObjectTypesByName = <String, ObjectTypeDefinitionNode>{
      for (final t in schemaParsed?.objectTypes ?? <ObjectTypeDefinitionNode>[])
        t.name.value: t,
    };

    final schemaUnionTypesByName = <String, UnionTypeDefinitionNode>{
      for (final u in schemaParsed?.unionTypes ?? <UnionTypeDefinitionNode>[])
        u.name.value: u,
    };

    final schemaInterfaceTypesByName = <String, InterfaceTypeDefinitionNode>{
      for (final i
          in schemaParsed?.interfaceTypes ?? <InterfaceTypeDefinitionNode>[])
        i.name.value: i,
    };

    // Merged enum / input name sets (schema + feature file)
    final enumNames = <String>{
      ...parsed.enumTypes.map((e) => e.name.value.pascalCase),
      ...(schemaParsed?.enumTypes ?? <EnumTypeDefinitionNode>[])
          .map((e) => e.name.value.pascalCase),
    };
    final inputNames = <String>{
      ...parsed.inputTypes.map((i) => i.name.value.pascalCase),
      ...(schemaParsed?.inputTypes ?? <InputObjectTypeDefinitionNode>[])
          .map((i) => i.name.value.pascalCase),
    };
    final scalarNames = <String>{
      ...parsed.scalarTypes.map((s) => s.name.value),
      ...(schemaParsed?.scalarTypes ?? <ScalarTypeDefinitionNode>[])
          .map((s) => s.name.value),
    };

    // Names of the shared `{Type}Model` classes declared in the schema's
    // models.dart barrel (excludes root Query/Mutation/Subscription, which
    // never get their own generated model class). Only consumed by the
    // schema-driven client extension (_generateSchemaUtilitiesCode) —
    // per-operation response models (_generateOperations) are always
    // scoped to the operation's own selection.
    final sharedModelNames = <String>{
      for (final t in schemaObjectTypesByName.keys)
        if (t != 'Query' && t != 'Mutation' && t != 'Subscription')
          '${t.pascalCase}Model',
      for (final u in schemaParsed?.unionTypes ?? <UnionTypeDefinitionNode>[])
        '${u.name.value.pascalCase}Model',
      for (final i
          in schemaParsed?.interfaceTypes ?? <InterfaceTypeDefinitionNode>[])
        '${i.name.value.pascalCase}Model',
    };

    return (
      parsed: parsed,
      fileName: fileName,
      isSchemaFile: isSchemaFile,
      inputDir: inputDir,
      resolvedSharedDir: resolvedSharedDir,
      schemaGeneratedDir: schemaGeneratedDir,
      sharedPrefix: sharedPrefix,
      schemaParsed: schemaParsed,
      schemaObjectTypesByName: schemaObjectTypesByName,
      schemaUnionTypesByName: schemaUnionTypesByName,
      schemaInterfaceTypesByName: schemaInterfaceTypesByName,
      enumNames: enumNames,
      inputNames: inputNames,
      scalarNames: scalarNames,
      sharedModelNames: sharedModelNames,
    );
  }

  /// Schema-only: emits `{sharedPrefix}enums/enums.dart`,
  /// `{sharedPrefix}inputs/inputs.dart`, and `{sharedPrefix}models/models.dart`
  /// (each only if the schema actually declares that kind of type) directly
  /// into [files]. A feature file contributes nothing here — its enum/input
  /// references resolve against these same shared barrels instead.
  static void _generateSchemaSharedFiles(
    _GenContext ctx,
    Map<String, String> files, {
    String? packageName,
    Map<String, String> customScalars = const {},
  }) {
    // 1. Enums  → {sharedPrefix}enums/enums.dart
    if (ctx.isSchemaFile && ctx.parsed.enumTypes.isNotEmpty) {
      final enumFilesMap = SchemaGenerator.generateEnums(ctx.parsed.enumTypes);
      enumFilesMap.forEach((path, code) {
        files['${ctx.sharedPrefix}$path'] = code;
      });
    }

    // 2. Inputs → {sharedPrefix}inputs/inputs.dart
    if (ctx.isSchemaFile && ctx.parsed.inputTypes.isNotEmpty) {
      final inputFilesMap = SchemaGenerator.generateInputs(
        ctx.parsed.inputTypes,
        ctx.enumNames,
        ctx.inputNames,
        scalarNames: ctx.scalarNames,
        customScalars: customScalars,
        packageName: packageName,
        generatedDir: ctx.schemaGeneratedDir,
      );
      inputFilesMap.forEach((path, code) {
        files['${ctx.sharedPrefix}$path'] = code;
      });
    }

    // 3. Object types → {sharedPrefix}models/models.dart
    //
    // These full-schema `{Type}Model` classes are consumed only by the
    // schema-driven client extension (_generateSchemaUtilitiesCode), which
    // fetches an entire type with no field selection to work from.
    // Per-operation response models (_generateOperations) never reuse
    // these — each .graphql selection gets its own model scoped to
    // exactly the fields it queried.
    if (ctx.isSchemaFile && ctx.parsed.objectTypes.isNotEmpty) {
      final objectFilesMap = SchemaGenerator.generateObjectTypes(
        ctx.parsed.objectTypes,
        ctx.enumNames,
        ctx.inputNames,
        scalarNames: ctx.scalarNames,
        customScalars: customScalars,
        packageName: packageName,
        generatedDir: ctx.schemaGeneratedDir,
        unions: ctx.parsed.unionTypes,
        interfaces: ctx.parsed.interfaceTypes,
      );
      objectFilesMap.forEach((path, code) {
        files['${ctx.sharedPrefix}$path'] = code;
      });
    }
  }

  /// Emits the `SchemaGraphQLClientExtension` (a Req/Vars/client-method
  /// triple per Query/Mutation field) — empty when the schema declares
  /// neither, so the root barrel knows to skip the freezed `part`
  /// directives entirely.
  static String _generateSchemaUtilitiesCode(
    _GenContext ctx, {
    Map<String, String> customScalars = const {},
  }) {
    final queryType = ctx.parsed.objectTypes.firstWhere(
      (o) => o.name.value == 'Query',
      orElse: () =>
          ObjectTypeDefinitionNode(name: NameNode(value: 'Query'), fields: []),
    );
    final mutationType = ctx.parsed.objectTypes.firstWhere(
      (o) => o.name.value == 'Mutation',
      orElse: () => ObjectTypeDefinitionNode(
          name: NameNode(value: 'Mutation'), fields: []),
    );

    if (queryType.fields.isEmpty && mutationType.fields.isEmpty) {
      return '';
    }

    return SchemaUtilityGenerator.generateSchemaUtilities(
      objectTypes: ctx.parsed.objectTypes,
      enumNames: ctx.enumNames,
      inputNames: ctx.inputNames,
      scalarNames: ctx.scalarNames,
      customScalars: customScalars,
      unionTypes: ctx.parsed.unionTypes,
      interfaceTypes: ctx.parsed.interfaceTypes,
    );
  }

  /// Feature-file work: for every operation in [ctx.parsed], emits its Vars
  /// file, selection-scoped response model(s), Req file, and per-operation
  /// barrel directly into [files], and accumulates the shared fragments
  /// file (if any named fragment was actually spread) plus everything
  /// [_generateRootBarrel] needs to wire the root barrel around all of it.
  static _OperationsResult _generateOperations(
    _GenContext ctx,
    Map<String, String> files, {
    String? packageName,
    Map<String, String> customScalars = const {},
  }) {
    final opExports = <({String exportPath, List<String> modelClasses})>[];
    final fileOpExtensions = StringBuffer();

    // Named fragments in this file are the only sanctioned way a response
    // model is shared across operations — generated once, on first use,
    // into generated/fragments/fragments.dart.
    final fragmentsByName = <String, FragmentDefinitionNode>{
      for (final f in ctx.parsed.fragments) f.name.value: f,
    };
    final fragmentModelCache = <String, String>{};
    final fragmentClassNames = <String>{};
    final fragmentsBuffer = StringBuffer();
    final fragmentsDirPath = p.join(ctx.inputDir, 'generated', 'fragments');
    final fragmentsFilePath = p.join(fragmentsDirPath, 'fragments.dart');

    if (ctx.parsed.operations.isNotEmpty) {
      final extClassName = '${ctx.fileName.pascalCase}GraphQLClientExtension';
      fileOpExtensions.writeln(
          '/// Auto-generated Client Extension for operations in ${ctx.fileName}');
      fileOpExtensions.writeln('extension $extClassName on GraphQLClient {');

      for (final op in ctx.parsed.operations) {
        final sharedClassNames = <String>{};

        final rawName = op.name?.value ?? 'AnonymousOperation';
        final name = rawName.pascalCase;
        final methodName = rawName.camelCase;
        final opDir = rawName.snakeCase;

        final varsClassName = '${name}Vars';
        final modelClassName = '${name}Model';
        final reqClassName = '${name}Req';

        // Paths for relative imports inside generated/{opDir}/
        final targetOpDir = p.join(ctx.inputDir, 'generated', opDir);
        final schemaInputsPath =
            p.join(ctx.resolvedSharedDir, 'inputs', 'inputs.dart');
        final schemaEnumsPath =
            p.join(ctx.resolvedSharedDir, 'enums', 'enums.dart');

        final sharedInputImport =
            _importFor(packageName, schemaInputsPath, targetOpDir);
        final sharedEnumImport =
            _importFor(packageName, schemaEnumsPath, targetOpDir);
        final fragmentsImport =
            _importFor(packageName, fragmentsFilePath, targetOpDir);

        // 5a. Vars file
        final varFields = <String, FieldTypeInfo>{};
        for (final v in op.variableDefinitions) {
          final rawVarName = v.variable.name.value;
          final typeInfo = SchemaGenerator.parseFieldType(
            v.type,
            enumNames: ctx.enumNames,
            inputNames: ctx.inputNames,
            scalarNames: ctx.scalarNames,
            customScalars: customScalars,
          );
          final defVal = SchemaGenerator.formatDefaultValue(
            v.defaultValue?.value,
            dartType: typeInfo.dartType,
          );
          varFields[rawVarName] = FieldTypeInfo(
            dartType: typeInfo.dartType,
            isRequired: defVal == null && typeInfo.isRequired,
            defaultValue: defVal,
          );
        }
        final varBodyBuffer = StringBuffer();
        _generateFreezedClassWithTypes(
          className: varsClassName,
          fields: varFields,
          buffer: varBodyBuffer,
          includeIfNull: false,
        );
        final varBody = varBodyBuffer.toString();

        final varBuffer = StringBuffer();
        varBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
        varBuffer.writeln('// ignore_for_file: type=lint');
        varBuffer.writeln(
            "import 'package:freezed_annotation/freezed_annotation.dart';");
        if (_referencesAny(varBody, ctx.inputNames))
          varBuffer.writeln("import '$sharedInputImport';");
        if (_referencesAny(varBody, ctx.enumNames))
          varBuffer.writeln("import '$sharedEnumImport';");
        varBuffer.writeln();
        varBuffer.writeln("part '${opDir}_var.freezed.dart';");
        varBuffer.writeln("part '${opDir}_var.g.dart';");
        varBuffer.writeln();
        varBuffer.write(varBody);
        files['generated/$opDir/${opDir}_var.dart'] = varBuffer.toString();

        // 5b. Selection models + root operation model
        //
        // Every selection gets a class scoped to exactly the fields this
        // operation queried, named by its path from the operation root
        // (e.g. GetCountryDetailsCountryModel) — never a schema-wide
        // {Type}Model. The only exception is a selection that is nothing
        // but a single fragment spread (`{ ...UserFields }`), which reuses
        // the shared `{Fragment}Fragment` class instead.
        final schemaRootTypeName = switch (op.type) {
          OperationType.mutation => 'Mutation',
          OperationType.subscription => 'Subscription',
          _ => 'Query',
        };
        final schemaRootType = ctx.schemaObjectTypesByName[schemaRootTypeName];

        // If an operation root field has no selection set but returns an object type,
        // auto-synthesize the selection set so neither the query nor the client extension fails.
        var effectiveOp = op;
        if (schemaRootType != null) {
          final updatedSelections = <SelectionNode>[];
          var opUpdated = false;
          for (final sel in op.selectionSet.selections) {
            if (sel is FieldNode && sel.selectionSet == null) {
              final schemaFieldDef = schemaRootType.fields
                  .where((f) => f.name.value == sel.name.value)
                  .firstOrNull;
              final schemaTypeName = schemaFieldDef != null
                  ? SchemaGenerator.unwrapTypeName(schemaFieldDef.type)
                  : null;
              if (schemaTypeName != null &&
                  (ctx.schemaObjectTypesByName.containsKey(schemaTypeName) ||
                      ctx.schemaUnionTypesByName.containsKey(schemaTypeName) ||
                      ctx.schemaInterfaceTypesByName
                          .containsKey(schemaTypeName))) {
                final autoSel = SchemaUtilityGenerator.buildSelectionSetNode(
                  type: schemaFieldDef!.type,
                  objectTypesByName: ctx.schemaObjectTypesByName,
                  unionTypesByName: ctx.schemaUnionTypesByName,
                  interfaceTypesByName: ctx.schemaInterfaceTypesByName,
                  enumNames: ctx.enumNames,
                  inputNames: ctx.inputNames,
                  scalarNames: ctx.scalarNames,
                  customScalars: customScalars,
                );
                if (autoSel != null) {
                  updatedSelections.add(FieldNode(
                    name: sel.name,
                    alias: sel.alias,
                    arguments: sel.arguments,
                    directives: sel.directives,
                    selectionSet: autoSel,
                  ));
                  opUpdated = true;
                  continue;
                }
              }
            }
            updatedSelections.add(sel);
          }
          if (opUpdated) {
            effectiveOp = OperationDefinitionNode(
              type: op.type,
              name: op.name,
              variableDefinitions: op.variableDefinitions,
              directives: op.directives,
              selectionSet: SelectionSetNode(selections: updatedSelections),
            );
          }
        }

        final selectionBuffer = StringBuffer();
        final rootFields = <String, FieldTypeInfo>{};

        for (final sel in _collectEffectiveFields(
            effectiveOp.selectionSet, fragmentsByName)) {
          final fieldName = sel.alias?.value ?? sel.name.value;
          final schemaFieldDef = schemaRootType?.fields
              .where((f) => f.name.value == sel.name.value)
              .firstOrNull;
          final hasConditionalDirective = sel.directives
              .any((d) => d.name.value == 'include' || d.name.value == 'skip');

          if (sel.selectionSet != null) {
            final schemaTypeName = schemaFieldDef != null
                ? SchemaGenerator.unwrapTypeName(schemaFieldDef.type)
                : null;

            final targetModelName = _resolveSelectionModel(
              baseName: '$name${fieldName.pascalCase}',
              selectionSet: sel.selectionSet!,
              schemaTypeName: schemaTypeName,
              buffer: selectionBuffer,
              sharedClassNames: sharedClassNames,
              enumNames: ctx.enumNames,
              inputNames: ctx.inputNames,
              scalarNames: ctx.scalarNames,
              customScalars: customScalars,
              schemaObjectTypesByName: ctx.schemaObjectTypesByName,
              unionTypesByName: ctx.schemaUnionTypesByName,
              interfaceTypesByName: ctx.schemaInterfaceTypesByName,
              fragmentsByName: fragmentsByName,
              fragmentModelCache: fragmentModelCache,
              fragmentClassNames: fragmentClassNames,
              fragmentsBuffer: fragmentsBuffer,
            );

            final isRequired = !hasConditionalDirective &&
                (schemaFieldDef?.type.isNonNull ?? false);
            final dartType = schemaFieldDef != null
                ? _formatTypeStructure(schemaFieldDef.type, targetModelName)
                : targetModelName;

            rootFields[fieldName] =
                FieldTypeInfo(dartType: dartType, isRequired: isRequired);
          } else {
            // Scalar / enum field at root level
            if (schemaFieldDef != null) {
              final parsed = SchemaGenerator.parseFieldType(
                schemaFieldDef.type,
                enumNames: ctx.enumNames,
                inputNames: ctx.inputNames,
                scalarNames: ctx.scalarNames,
                customScalars: customScalars,
              );
              rootFields[fieldName] = hasConditionalDirective
                  ? FieldTypeInfo(dartType: parsed.dartType, isRequired: false)
                  : parsed;
            } else {
              rootFields[fieldName] = FieldTypeInfo(
                  dartType: _inferScalarType(fieldName), isRequired: false);
            }
          }
        }

        // Always generate the operation-level data class (e.g. GetUserModel)
        sharedClassNames.add(modelClassName);
        _generateFreezedClassWithTypes(
          className: modelClassName,
          fields: rootFields,
          buffer: selectionBuffer,
        );

        final hasOpModel = selectionBuffer.isNotEmpty;
        if (hasOpModel) {
          final modelBody = selectionBuffer.toString();
          final modelBuffer = StringBuffer();
          modelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
          modelBuffer.writeln('// ignore_for_file: type=lint');
          modelBuffer.writeln(
              "import 'package:freezed_annotation/freezed_annotation.dart';");
          if (_referencesAny(modelBody, ctx.inputNames))
            modelBuffer.writeln("import '$sharedInputImport';");
          if (_referencesAny(modelBody, ctx.enumNames))
            modelBuffer.writeln("import '$sharedEnumImport';");
          if (_referencesAny(modelBody, fragmentClassNames))
            modelBuffer.writeln("import '$fragmentsImport';");
          modelBuffer.writeln();
          modelBuffer.writeln("part '${opDir}_model.freezed.dart';");
          modelBuffer.writeln("part '${opDir}_model.g.dart';");
          modelBuffer.writeln();
          modelBuffer.writeln(modelBody);
          files['generated/$opDir/${opDir}_model.dart'] =
              modelBuffer.toString();
        }

        // 5c. Request file
        // Req classes only reference the local VarsClassName/ModelClassName
        // (imported below) — never the shared models/inputs/enums barrels
        // directly — so those barrel imports are never needed here.
        final reqBuffer = StringBuffer();
        reqBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
        reqBuffer.writeln('// ignore_for_file: type=lint');
        reqBuffer.writeln(
            "import 'package:freezed_annotation/freezed_annotation.dart';");
        reqBuffer.writeln("import 'package:mk_graphql/mk_graphql.dart';");
        reqBuffer.writeln(
            "import '${_importFor(packageName, p.join(targetOpDir, '${opDir}_var.dart'), targetOpDir)}';");
        if (hasOpModel) {
          reqBuffer.writeln(
              "import '${_importFor(packageName, p.join(targetOpDir, '${opDir}_model.dart'), targetOpDir)}';");
        }
        reqBuffer.writeln();
        reqBuffer.writeln("part '${opDir}_req.freezed.dart';");
        reqBuffer.writeln();

        // The request document sent over the wire must also carry the text
        // of every fragment this operation (transitively) spreads — the
        // server has no idea what `...ContinentBasic` means otherwise.
        final usedFragmentNames = _collectUsedFragmentNames(
            effectiveOp.selectionSet, fragmentsByName);
        final opDoc = [
          printNode(effectiveOp),
          for (final fragName in usedFragmentNames)
            printNode(fragmentsByName[fragName]!),
        ].join('\n\n');
        _generateFreezedRequest(
          reqClassName: reqClassName,
          varsClassName: varsClassName,
          modelClassName: modelClassName,
          docStr: opDoc,
          operationName: rawName,
          parseDataExpr: '$modelClassName.fromJson(json)',
          buffer: reqBuffer,
        );
        files['generated/$opDir/${opDir}_req.dart'] = reqBuffer.toString();

        // 5d. Operation barrel
        final opBarrelBuffer = StringBuffer();
        opBarrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
        opBarrelBuffer.writeln('// ignore_for_file: type=lint');
        opBarrelBuffer.writeln("export '${opDir}_var.dart';");
        if (hasOpModel) opBarrelBuffer.writeln("export '${opDir}_model.dart';");
        opBarrelBuffer.writeln("export '${opDir}_req.dart';");
        files['generated/$opDir/$opDir.dart'] = opBarrelBuffer.toString();

        final modelClasses = hasOpModel
            ? RegExp(r'abstract class\s+([A-Za-z0-9_]+)')
                .allMatches(selectionBuffer.toString())
                .map((m) => m.group(1)!)
                .toList()
            : <String>[];
        opExports.add((
          exportPath: "export '$opDir/$opDir.dart';",
          modelClasses: modelClasses,
        ));

        // 5e. Client extension methods
        final opArgs = <String, FieldTypeInfo>{};
        for (final v in op.variableDefinitions) {
          final typeInfo = SchemaGenerator.parseFieldType(v.type,
              enumNames: ctx.enumNames,
              inputNames: ctx.inputNames,
              scalarNames: ctx.scalarNames,
              customScalars: customScalars);
          opArgs[v.variable.name.value] = FieldTypeInfo(
            dartType: typeInfo.dartType,
            isRequired: typeInfo.isRequired,
            defaultValue: SchemaGenerator.formatDefaultValue(
              v.defaultValue?.value,
              dartType: typeInfo.dartType,
            ),
          );
        }
        final emitMethods = op.type == OperationType.subscription
            ? codegen.emitSubscriptionMethod
            : codegen.emitOperationMethodTriple;
        fileOpExtensions.writeln(emitMethods(
          methodName: methodName,
          modelClassName: modelClassName,
          reqClassName: reqClassName,
          varsClassName: varsClassName,
          args: opArgs,
        ));
      }

      fileOpExtensions.writeln('}');
      fileOpExtensions.writeln();

      // Emit the shared fragments file, if any named fragment was actually
      // spread by one of this file's operations.
      if (fragmentClassNames.isNotEmpty) {
        final fragmentsBody = fragmentsBuffer.toString();
        final fragmentsFileBuffer = StringBuffer();
        fragmentsFileBuffer
            .writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
        fragmentsFileBuffer.writeln('// ignore_for_file: type=lint');
        fragmentsFileBuffer.writeln(
            "import 'package:freezed_annotation/freezed_annotation.dart';");
        final fragInputsImport = _importFor(
            packageName,
            p.join(ctx.resolvedSharedDir, 'inputs', 'inputs.dart'),
            fragmentsDirPath);
        final fragEnumsImport = _importFor(
            packageName,
            p.join(ctx.resolvedSharedDir, 'enums', 'enums.dart'),
            fragmentsDirPath);
        if (_referencesAny(fragmentsBody, ctx.inputNames))
          fragmentsFileBuffer.writeln("import '$fragInputsImport';");
        if (_referencesAny(fragmentsBody, ctx.enumNames))
          fragmentsFileBuffer.writeln("import '$fragEnumsImport';");
        fragmentsFileBuffer.writeln();
        fragmentsFileBuffer.writeln("part 'fragments.freezed.dart';");
        fragmentsFileBuffer.writeln("part 'fragments.g.dart';");
        fragmentsFileBuffer.writeln();
        fragmentsFileBuffer.write(fragmentsBody);
        files['generated/fragments/fragments.dart'] =
            fragmentsFileBuffer.toString();
      }
    }

    return (
      fileOpExtensionsText: fileOpExtensions.toString(),
      opExports: opExports,
      fragmentClassNames: fragmentClassNames,
      fragmentsFilePath: fragmentsFilePath,
    );
  }

  /// Assembles the root barrel file (`generated/{fileName}.gql.dart`, or
  /// `{sharedPrefix}{fileName}.gql.dart` for the schema file itself) —
  /// schema-type exports, per-operation exports (with duplicate-symbol
  /// `hide` clauses when two operations both reused the same fragment
  /// class), the schema utilities `part`s, and the client extension —
  /// directly into [files].
  static void _generateRootBarrel(
    _GenContext ctx,
    Map<String, String> files, {
    required String schemaUtilCode,
    required _OperationsResult ops,
    String? packageName,
  }) {
    // Whether this barrel's own generated code (schema utilities + client
    // extension methods) actually references enum/input/model type names
    // directly — used to decide which imports (not exports, which stay
    // unconditional for barrel convenience) are actually needed.
    final rootUsageText = schemaUtilCode + ops.fileOpExtensionsText;

    final rootBarrelBuffer = StringBuffer();
    rootBarrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    rootBarrelBuffer.writeln('// ignore_for_file: type=lint');
    if (schemaUtilCode.isNotEmpty) {
      rootBarrelBuffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
    }
    if (schemaUtilCode.isNotEmpty || ops.fileOpExtensionsText.isNotEmpty) {
      rootBarrelBuffer.writeln("import 'package:mk_graphql/mk_graphql.dart';");
    }

    final targetGeneratedDir = ctx.isSchemaFile
        ? ctx.resolvedSharedDir
        : p.join(ctx.inputDir, 'generated');
    final schemaModelsPath =
        p.join(ctx.resolvedSharedDir, 'models', 'models.dart');
    final schemaInputsPath =
        p.join(ctx.resolvedSharedDir, 'inputs', 'inputs.dart');
    final schemaEnumsPath =
        p.join(ctx.resolvedSharedDir, 'enums', 'enums.dart');

    final barrelModelImport =
        _importFor(packageName, schemaModelsPath, targetGeneratedDir);
    final barrelInputImport =
        _importFor(packageName, schemaInputsPath, targetGeneratedDir);
    final barrelEnumImport =
        _importFor(packageName, schemaEnumsPath, targetGeneratedDir);

    if (ctx.isSchemaFile) {
      if (ctx.parsed.enumTypes.isNotEmpty) {
        if (_referencesAny(rootUsageText, ctx.enumNames))
          rootBarrelBuffer.writeln("import '$barrelEnumImport';");
        rootBarrelBuffer.writeln("export 'enums/enums.dart';");
      }
      if (ctx.parsed.inputTypes.isNotEmpty) {
        if (_referencesAny(rootUsageText, ctx.inputNames))
          rootBarrelBuffer.writeln("import '$barrelInputImport';");
        rootBarrelBuffer.writeln("export 'inputs/inputs.dart';");
      }
      if (ctx.parsed.objectTypes
          .where((o) =>
              o.name.value != 'Query' &&
              o.name.value != 'Mutation' &&
              o.name.value != 'Subscription')
          .isNotEmpty) {
        if (_referencesAny(rootUsageText, ctx.sharedModelNames))
          rootBarrelBuffer.writeln("import '$barrelModelImport';");
        rootBarrelBuffer.writeln("export 'models/models.dart';");
      }
    } else {
      if (ctx.enumNames.isNotEmpty) {
        if (_referencesAny(rootUsageText, ctx.enumNames)) {
          rootBarrelBuffer.writeln("import '$barrelEnumImport';");
        }
        rootBarrelBuffer.writeln("export '$barrelEnumImport';");
      }
      if (ctx.inputNames.isNotEmpty) {
        if (_referencesAny(rootUsageText, ctx.inputNames)) {
          rootBarrelBuffer.writeln("import '$barrelInputImport';");
        }
        rootBarrelBuffer.writeln("export '$barrelInputImport';");
      }
      if (ctx.sharedModelNames.isNotEmpty) {
        if (_referencesAny(rootUsageText, ctx.sharedModelNames)) {
          rootBarrelBuffer.writeln("import '$barrelModelImport';");
        }
        rootBarrelBuffer.writeln("export '$barrelModelImport';");
      }
      if (ops.fragmentClassNames.isNotEmpty) {
        final barrelFragmentsExport =
            _importFor(packageName, ops.fragmentsFilePath, targetGeneratedDir);
        rootBarrelBuffer.writeln("export '$barrelFragmentsExport';");
      }
    }

    final exportedClassesSoFar = <String>{};
    for (final opExp in ops.opExports) {
      final opRelPath = opExp.exportPath
          .replaceAll('export ', '')
          .replaceAll(';', '')
          .replaceAll("'", '')
          .trim();
      final opImport = _importFor(packageName,
          p.join(targetGeneratedDir, opRelPath), targetGeneratedDir);
      rootBarrelBuffer.writeln("import '$opImport';");

      final duplicates = opExp.modelClasses
          .where((c) => exportedClassesSoFar.contains(c))
          .toList();
      exportedClassesSoFar.addAll(opExp.modelClasses);

      if (duplicates.isNotEmpty) {
        final hideSymbols = <String>[
          for (final c in duplicates) ...[
            c,
            '\$${c}CopyWith',
            '${c}Patterns',
          ],
        ];
        rootBarrelBuffer
            .writeln("export '$opRelPath' hide ${hideSymbols.join(', ')};");
      } else {
        rootBarrelBuffer.writeln("export '$opRelPath';");
      }
    }

    rootBarrelBuffer.writeln();
    if (schemaUtilCode.isNotEmpty) {
      rootBarrelBuffer.writeln("part '${ctx.fileName}.gql.freezed.dart';");
      rootBarrelBuffer.writeln("part '${ctx.fileName}.gql.g.dart';");
      rootBarrelBuffer.writeln();
      rootBarrelBuffer.writeln(schemaUtilCode);
    }

    if (ops.fileOpExtensionsText.isNotEmpty) {
      rootBarrelBuffer.writeln(ops.fileOpExtensionsText);
    }

    final targetBarrelPath = ctx.isSchemaFile
        ? '${ctx.sharedPrefix}${ctx.fileName}.gql.dart'
        : 'generated/${ctx.fileName}.gql.dart';
    files[targetBarrelPath] = rootBarrelBuffer.toString();
  }

  /// Caps how many isolates [_formatGeneratedFiles] spawns — profiling
  /// found the actual parallel work available is usually dominated by just
  /// one or two large files (a root barrel bundling every schema utility
  /// and client extension method), so beyond ~4 workers there's nothing
  /// left to parallelize and more isolates only adds spawn/message-passing
  /// overhead. Also caps at the machine's own core count, so this never
  /// oversubscribes a small or already-busy machine.
  static const _maxFormatWorkers = 4;

  /// Runs every generated file body through `DartFormatter`, falling back
  /// to the unformatted source for any single file that fails to format
  /// (never letting one bad file abort the whole bundle).
  ///
  /// `DartFormatter.format` re-parses and pretty-prints each file — cheap
  /// per call, but profiling a medium schema found it dominates total
  /// generation time (a root barrel bundling every schema utility and
  /// client extension method into one file is disproportionately
  /// expensive to format). Since each call is a pure, independent,
  /// CPU-bound function with no shared state, this fans the work out
  /// across a small pool of isolates instead of running every file
  /// sequentially on one core — measured ~40% faster wall-clock on a
  /// representative schema. Files are bin-packed onto workers by content
  /// length (longest-processing-time-first), the best available proxy for
  /// format cost, so the large dominant files each land on their own
  /// worker instead of being split evenly by count.
  static Future<Map<String, String>> _formatGeneratedFiles(
    Map<String, String> files,
  ) async {
    // Not worth spawning isolates for a single file, or on a single-core
    // machine (spawn overhead with no other core to actually run on).
    if (files.length <= 1 || Platform.numberOfProcessors <= 1) {
      return _formatFilesOnThisIsolate(files.entries);
    }

    final entries = files.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    final workerCount = _maxFormatWorkers
        .clamp(1, Platform.numberOfProcessors)
        .clamp(1, entries.length);
    final buckets = List.generate(
        workerCount, (_) => <MapEntry<String, String>>[],
        growable: false);
    final bucketCost = List.filled(workerCount, 0);
    for (final entry in entries) {
      var lightest = 0;
      for (var i = 1; i < workerCount; i++) {
        if (bucketCost[i] < bucketCost[lightest]) lightest = i;
      }
      buckets[lightest].add(entry);
      bucketCost[lightest] += entry.value.length;
    }

    final results = await Future.wait([
      for (final bucket in buckets)
        if (bucket.isNotEmpty)
          Isolate.run(() => _formatFilesOnThisIsolate(bucket)),
    ]);

    final formattedFiles = <String, String>{};
    for (final result in results) {
      formattedFiles.addAll(result);
    }
    return formattedFiles;
  }

  /// The actual formatting work — run either directly (small/single-core
  /// case) or once per isolate in [_formatGeneratedFiles]'s worker pool.
  static Map<String, String> _formatFilesOnThisIsolate(
    Iterable<MapEntry<String, String>> files,
  ) {
    final formattedFiles = <String, String>{};
    final formatter =
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);
    for (final entry in files) {
      try {
        formattedFiles[entry.key] = formatter.format(entry.value);
      } catch (_) {
        formattedFiles[entry.key] = entry.value;
      }
    }
    return formattedFiles;
  }

  /// Computes the list of expected output file paths (relative to [inputPath]'s directory)
  /// without running expensive code generation, string interpolation, or DartFormatter.
  static List<String> computeOutputPaths({
    required String content,
    required String inputPath,
    String? schemaPath,
    String? sharedDir,
    // Reuses an already-parsed document instead of parsing [content] again —
    // [MkGraphQLBuilder]'s factory calls this for every `.graphql`/`.gql`
    // file up front (build_runner requires `buildExtensions` before any
    // `build()` runs), so passing the parse it already did through to the
    // later `generateForGraphQLFile` call for the same content avoids
    // parsing every file twice on every build.
    ParsedGraphQLDocument? preParsed,
  }) {
    if (!inputPath.endsWith('.graphql') && !inputPath.endsWith('.gql')) {
      return const [];
    }

    final parsed = preParsed ?? ParsedGraphQLDocument.parse(content);
    final fileName = p.basenameWithoutExtension(inputPath);
    final resolvedSchemaPath =
        schemaPath ?? p.join(p.dirname(inputPath), 'schema.graphql');
    final isSchemaFile = (schemaPath != null &&
            p.normalize(inputPath) == p.normalize(schemaPath)) ||
        fileName == 'schema';

    final schemaDir = p.dirname(resolvedSchemaPath);
    final inputDir = p.dirname(inputPath);
    final resolvedSharedDir = sharedDir != null && sharedDir.trim().isNotEmpty
        ? p.normalize(sharedDir.trim())
        : p.normalize(p.join(schemaDir, 'generated'));
    final sharedRelPath = p
        .normalize(p.relative(resolvedSharedDir, from: inputDir))
        .replaceAll('\\', '/');
    final sharedPrefix = sharedRelPath == '.' ? '' : '$sharedRelPath/';

    final outputs = <String>[];

    if (isSchemaFile) {
      // One fixed path per category — never one per type — so this
      // schema file's declared build_runner outputs stop depending on how
      // many enums/inputs/objects it defines. See generateEnums/
      // generateInputs/generateObjectTypes in schema_generator.dart, which
      // this must keep matching exactly.
      if (parsed.enumTypes.isNotEmpty) {
        outputs.add('${sharedPrefix}enums/enums.dart');
      }
      if (parsed.inputTypes.isNotEmpty) {
        outputs.add('${sharedPrefix}inputs/inputs.dart');
      }
      final objectTypes = parsed.objectTypes.where((o) =>
          o.name.value != 'Query' &&
          o.name.value != 'Mutation' &&
          o.name.value != 'Subscription');
      if (objectTypes.isNotEmpty) {
        outputs.add('${sharedPrefix}models/models.dart');
      }
      outputs.add('${sharedPrefix}$fileName.gql.dart');
    } else {
      for (final op in parsed.operations) {
        final rawName = op.name?.value ?? 'AnonymousOperation';
        final opDir = rawName.snakeCase;
        outputs.add('generated/$opDir/${opDir}_var.dart');
        if (op.selectionSet.selections.isNotEmpty) {
          outputs.add('generated/$opDir/${opDir}_model.dart');
        }
        outputs.add('generated/$opDir/${opDir}_req.dart');
        outputs.add('generated/$opDir/$opDir.dart');
      }
      if (parsed.fragments.isNotEmpty) {
        outputs.add('generated/fragments/fragments.dart');
      }
      outputs.add('generated/$fileName.gql.dart');
    }

    return outputs;
  }

  // ---------------------------------------------------------------------------
  // Code generation helpers
  // ---------------------------------------------------------------------------

  static void _generateFreezedClassWithTypes({
    required String className,
    required Map<String, FieldTypeInfo> fields,
    required StringBuffer buffer,
    // Variables classes must omit unset optional fields from toJson() rather
    // than sending them as explicit `null` — some GraphQL servers treat an
    // explicit null argument differently from an omitted one (e.g. an
    // omitted filter returns everything, an explicit `filter: null` can
    // resolve to no results). Applied per-field (not as a class-level
    // @JsonSerializable) since stacking that on these freezed 4.x classes
    // breaks fromJson generation for required fields.
    bool includeIfNull = true,
    List<String> implementsTypes = const [],
  }) {
    buffer.writeln(codegen.emitSpec(codegen.freezedDataClass(
      className: className,
      fields: fields,
      includeIfNull: includeIfNull,
      implementsTypes: implementsTypes,
    )));
  }

  static void _generateFreezedRequest({
    required String reqClassName,
    required String varsClassName,
    required String modelClassName,
    required String docStr,
    required String operationName,
    required String parseDataExpr,
    required StringBuffer buffer,
  }) {
    buffer.writeln(codegen.emitSpec(codegen.freezedRequestClass(
      reqClassName: reqClassName,
      varsClassName: varsClassName,
      modelClassName: modelClassName,
      docStr: docStr,
      operationName: operationName,
      parseDataExpr: parseDataExpr,
    )));
  }

  // ---------------------------------------------------------------------------
  // Selection-scoped response model generator
  // ---------------------------------------------------------------------------

  static String _formatTypeStructure(TypeNode type, String customNamedType) {
    if (type is NamedTypeNode) {
      return customNamedType;
    } else if (type is ListTypeNode) {
      return 'List<${_formatTypeStructure(type.type, customNamedType)}>';
    }
    return customNamedType;
  }

  /// Returns the sole [FragmentSpreadNode] in [selectionSet] if that spread
  /// is the *only* selection (i.e. the selection is exactly `{ ...Frag }`),
  /// or `null` otherwise.
  static FragmentSpreadNode? _asSoleFragmentSpread(
      SelectionSetNode selectionSet) {
    if (selectionSet.selections.length == 1 &&
        selectionSet.selections.first is FragmentSpreadNode) {
      return selectionSet.selections.first as FragmentSpreadNode;
    }
    return null;
  }

  /// Flattens fragment spreads and inline fragments into their constituent
  /// fields so a query using `...SomeFragment` never silently loses fields.
  /// A field selected directly at a given level overrides one contributed
  /// by a spread at the same level. Interface/union type conditions are not
  /// distinguished — this generator doesn't support polymorphic selections.
  static List<FieldNode> _collectEffectiveFields(
    SelectionSetNode selectionSet,
    Map<String, FragmentDefinitionNode> fragmentsByName,
  ) {
    final byName = <String, FieldNode>{};

    void visit(SelectionSetNode selSet) {
      for (final sel in selSet.selections) {
        if (sel is FieldNode) {
          byName[sel.alias?.value ?? sel.name.value] = sel;
        } else if (sel is FragmentSpreadNode) {
          final fragment = fragmentsByName[sel.name.value];
          if (fragment != null) visit(fragment.selectionSet);
        } else if (sel is InlineFragmentNode) {
          visit(sel.selectionSet);
        }
      }
    }

    visit(selectionSet);
    return byName.values.toList();
  }

  /// Transitively collects the names of every named fragment spread inside
  /// [selectionSet] — including fragments spread by other used fragments —
  /// so the operation's printed document can carry their definitions too.
  static Set<String> _collectUsedFragmentNames(
    SelectionSetNode selectionSet,
    Map<String, FragmentDefinitionNode> fragmentsByName,
  ) {
    final used = <String>{};

    void visit(SelectionSetNode selSet) {
      for (final sel in selSet.selections) {
        if (sel is FragmentSpreadNode) {
          if (used.add(sel.name.value)) {
            final fragment = fragmentsByName[sel.name.value];
            if (fragment != null) visit(fragment.selectionSet);
          }
        } else if (sel is FieldNode && sel.selectionSet != null) {
          visit(sel.selectionSet!);
        } else if (sel is InlineFragmentNode) {
          visit(sel.selectionSet);
        }
      }
    }

    visit(selectionSet);
    return used;
  }

  /// Generates (or reuses) the Dart class for [selectionSet], named by its
  /// path from the operation root (e.g. `GetCountryDetailsCountryModel`) so
  /// it can never collide with another operation's classes and is always
  /// scoped to exactly the fields that operation selected — never a
  /// schema-wide `{Type}Model`.
  ///
  /// The one exception: if [selectionSet] is nothing but a single fragment
  /// spread (`{ ...UserFields }`), the shared `{Fragment}Fragment` class is
  /// reused instead — named fragments are the only sanctioned way a
  /// response model is shared across operations.
  static String _resolveSelectionModel({
    required String baseName,
    required SelectionSetNode selectionSet,
    required String? schemaTypeName,
    required StringBuffer buffer,
    required Set<String> sharedClassNames,
    required Set<String> enumNames,
    required Set<String> inputNames,
    required Set<String> scalarNames,
    Map<String, String> customScalars = const {},
    required Map<String, ObjectTypeDefinitionNode> schemaObjectTypesByName,
    required Map<String, UnionTypeDefinitionNode> unionTypesByName,
    required Map<String, InterfaceTypeDefinitionNode> interfaceTypesByName,
    required Map<String, FragmentDefinitionNode> fragmentsByName,
    required Map<String, String> fragmentModelCache,
    required Set<String> fragmentClassNames,
    required StringBuffer fragmentsBuffer,
    String suffix = 'Model',
    List<String> implementsTypes = const [],
  }) {
    final soleSpread = _asSoleFragmentSpread(selectionSet);
    if (soleSpread != null) {
      final fragmentDef = fragmentsByName[soleSpread.name.value];
      if (fragmentDef != null) {
        return _getOrGenerateFragmentModel(
          fragmentDef: fragmentDef,
          enumNames: enumNames,
          inputNames: inputNames,
          scalarNames: scalarNames,
          customScalars: customScalars,
          schemaObjectTypesByName: schemaObjectTypesByName,
          unionTypesByName: unionTypesByName,
          interfaceTypesByName: interfaceTypesByName,
          fragmentsByName: fragmentsByName,
          fragmentModelCache: fragmentModelCache,
          fragmentClassNames: fragmentClassNames,
          fragmentsBuffer: fragmentsBuffer,
        );
      }
    }

    final className = '$baseName$suffix';
    if (sharedClassNames.contains(className)) return className;
    sharedClassNames.add(className);

    final abstractMembers = _abstractMembers(
      schemaTypeName,
      unionTypesByName: unionTypesByName,
      interfaceTypesByName: interfaceTypesByName,
      schemaObjectTypesByName: schemaObjectTypesByName,
    );
    if (abstractMembers != null &&
        (unionTypesByName.containsKey(schemaTypeName) ||
            _hasTypeConditionedSelections(
                selectionSet, fragmentsByName, abstractMembers))) {
      _generateAbstractSelectionModel(
        abstractName: schemaTypeName!,
        memberNames: abstractMembers,
        className: className,
        baseName: baseName,
        suffix: suffix,
        selectionSet: selectionSet,
        buffer: buffer,
        sharedClassNames: sharedClassNames,
        enumNames: enumNames,
        inputNames: inputNames,
        scalarNames: scalarNames,
        customScalars: customScalars,
        schemaObjectTypesByName: schemaObjectTypesByName,
        unionTypesByName: unionTypesByName,
        interfaceTypesByName: interfaceTypesByName,
        fragmentsByName: fragmentsByName,
        fragmentModelCache: fragmentModelCache,
        fragmentClassNames: fragmentClassNames,
        fragmentsBuffer: fragmentsBuffer,
      );
      return className;
    }

    final schemaFields = schemaTypeName == null
        ? null
        : (schemaObjectTypesByName[schemaTypeName]?.fields ??
            interfaceTypesByName[schemaTypeName]?.fields);
    final fields = <String, FieldTypeInfo>{};

    for (final child
        in _collectEffectiveFields(selectionSet, fragmentsByName)) {
      final childName = child.alias?.value ?? child.name.value;
      final childSchemaFieldDef = schemaFields
          ?.where((f) => f.name.value == child.name.value)
          .firstOrNull;
      final hasConditionalDirective = child.directives
          .any((d) => d.name.value == 'include' || d.name.value == 'skip');

      if (child.selectionSet != null) {
        final childSchemaTypeName = childSchemaFieldDef != null
            ? SchemaGenerator.unwrapTypeName(childSchemaFieldDef.type)
            : null;
        final childModel = _resolveSelectionModel(
          baseName: '$baseName${childName.pascalCase}',
          selectionSet: child.selectionSet!,
          schemaTypeName: childSchemaTypeName,
          buffer: buffer,
          sharedClassNames: sharedClassNames,
          enumNames: enumNames,
          inputNames: inputNames,
          scalarNames: scalarNames,
          customScalars: customScalars,
          schemaObjectTypesByName: schemaObjectTypesByName,
          unionTypesByName: unionTypesByName,
          interfaceTypesByName: interfaceTypesByName,
          fragmentsByName: fragmentsByName,
          fragmentModelCache: fragmentModelCache,
          fragmentClassNames: fragmentClassNames,
          fragmentsBuffer: fragmentsBuffer,
        );
        final isRequired = !hasConditionalDirective &&
            (childSchemaFieldDef?.type.isNonNull ?? false);
        final dartType = childSchemaFieldDef != null
            ? _formatTypeStructure(childSchemaFieldDef.type, childModel)
            : childModel;
        fields[childName] =
            FieldTypeInfo(dartType: dartType, isRequired: isRequired);
      } else if (childSchemaFieldDef != null) {
        final parsed = SchemaGenerator.parseFieldType(
          childSchemaFieldDef.type,
          enumNames: enumNames,
          inputNames: inputNames,
          scalarNames: scalarNames,
          customScalars: customScalars,
        );
        fields[childName] = hasConditionalDirective
            ? FieldTypeInfo(dartType: parsed.dartType, isRequired: false)
            : parsed;
      } else {
        fields[childName] = FieldTypeInfo(
            dartType: _inferScalarType(childName), isRequired: false);
      }
    }

    _generateFreezedClassWithTypes(
      className: className,
      fields: fields,
      buffer: buffer,
      implementsTypes: implementsTypes,
    );

    return className;
  }

  /// Concrete member type names of a union, or of an interface (the schema
  /// object types implementing it); null if [typeName] is neither.
  static Set<String>? _abstractMembers(
    String? typeName, {
    required Map<String, UnionTypeDefinitionNode> unionTypesByName,
    required Map<String, InterfaceTypeDefinitionNode> interfaceTypesByName,
    required Map<String, ObjectTypeDefinitionNode> schemaObjectTypesByName,
  }) {
    if (typeName == null) return null;
    final union = unionTypesByName[typeName];
    if (union != null) return {for (final m in union.types) m.name.value};
    if (!interfaceTypesByName.containsKey(typeName)) return null;
    return {
      for (final o in schemaObjectTypesByName.values)
        if (o.interfaces.any((i) => i.name.value == typeName)) o.name.value,
    };
  }

  /// True if [selectionSet] narrows to a concrete member via an inline
  /// fragment or fragment spread (`... on Member`).
  static bool _hasTypeConditionedSelections(
    SelectionSetNode selectionSet,
    Map<String, FragmentDefinitionNode> fragmentsByName,
    Set<String> memberNames,
  ) {
    for (final sel in selectionSet.selections) {
      if (sel is InlineFragmentNode) {
        final on = sel.typeCondition?.on.name.value;
        if ((on != null && memberNames.contains(on)) ||
            _hasTypeConditionedSelections(
                sel.selectionSet, fragmentsByName, memberNames)) {
          return true;
        }
      } else if (sel is FragmentSpreadNode) {
        final f = fragmentsByName[sel.name.value];
        if (f != null &&
            (memberNames.contains(f.typeCondition.on.name.value) ||
                _hasTypeConditionedSelections(
                    f.selectionSet, fragmentsByName, memberNames))) {
          return true;
        }
      }
    }
    return false;
  }

  /// A selection on a union- or interface-typed field
  /// (`blocks { ... on A {..} ... on B {..} }`): emits a sealed [className]
  /// plus one model per selected member, each scoped to that member's own
  /// inline-fragment / fragment-spread fields plus any fields selected on the
  /// abstract type itself (interface common fields). Members not selected
  /// parse to an `Unknown` model carrying just the common fields, rather
  /// than throwing.
  static void _generateAbstractSelectionModel({
    required String abstractName,
    required Set<String> memberNames,
    required String className,
    required String baseName,
    required String suffix,
    required SelectionSetNode selectionSet,
    required StringBuffer buffer,
    required Set<String> sharedClassNames,
    required Set<String> enumNames,
    required Set<String> inputNames,
    required Set<String> scalarNames,
    required Map<String, String> customScalars,
    required Map<String, ObjectTypeDefinitionNode> schemaObjectTypesByName,
    required Map<String, UnionTypeDefinitionNode> unionTypesByName,
    required Map<String, InterfaceTypeDefinitionNode> interfaceTypesByName,
    required Map<String, FragmentDefinitionNode> fragmentsByName,
    required Map<String, String> fragmentModelCache,
    required Set<String> fragmentClassNames,
    required StringBuffer fragmentsBuffer,
  }) {
    final common = <SelectionNode>[];
    final byMember = <String, List<SelectionNode>>{};

    void visit(SelectionSetNode selSet, String? onType) {
      for (final sel in selSet.selections) {
        if (sel is InlineFragmentNode) {
          visit(sel.selectionSet, sel.typeCondition?.on.name.value ?? onType);
        } else if (sel is FragmentSpreadNode) {
          final f = fragmentsByName[sel.name.value];
          if (f != null) visit(f.selectionSet, f.typeCondition.on.name.value);
        } else if (onType == null || onType == abstractName) {
          common.add(sel);
        } else if (memberNames.contains(onType)) {
          byMember.putIfAbsent(onType, () => []).add(sel);
        }
      }
    }

    visit(selectionSet, null);

    final isInterface = interfaceTypesByName.containsKey(abstractName);
    String resolve(String base, SelectionSetNode sel, String? type) =>
        _resolveSelectionModel(
          baseName: base,
          selectionSet: sel,
          schemaTypeName: type,
          buffer: buffer,
          sharedClassNames: sharedClassNames,
          enumNames: enumNames,
          inputNames: inputNames,
          scalarNames: scalarNames,
          customScalars: customScalars,
          schemaObjectTypesByName: schemaObjectTypesByName,
          unionTypesByName: unionTypesByName,
          interfaceTypesByName: interfaceTypesByName,
          fragmentsByName: fragmentsByName,
          fragmentModelCache: fragmentModelCache,
          fragmentClassNames: fragmentClassNames,
          fragmentsBuffer: fragmentsBuffer,
          suffix: suffix,
          implementsTypes: [className],
        );

    final members = <String, String>{};
    for (final member in memberNames.where(byMember.containsKey)) {
      members[member] = resolve(
        '$baseName${member.pascalCase}',
        SelectionSetNode(selections: [...common, ...byMember[member]!]),
        member,
      );
    }

    String? fallback;
    if (members.length < memberNames.length) {
      fallback = resolve(
        '${baseName}Unknown',
        SelectionSetNode(selections: common),
        isInterface ? abstractName : null,
      );
    }

    buffer.writeln(codegen.emitSpec(codegen.sealedUnion(
      className: className,
      members: members,
      fallback: fallback,
    )));
  }

  /// Generates the single shared class for a named fragment the first time
  /// it's spread anywhere in the file; every later spread just reuses it.
  static String _getOrGenerateFragmentModel({
    required FragmentDefinitionNode fragmentDef,
    required Set<String> enumNames,
    required Set<String> inputNames,
    required Set<String> scalarNames,
    Map<String, String> customScalars = const {},
    required Map<String, ObjectTypeDefinitionNode> schemaObjectTypesByName,
    required Map<String, UnionTypeDefinitionNode> unionTypesByName,
    required Map<String, InterfaceTypeDefinitionNode> interfaceTypesByName,
    required Map<String, FragmentDefinitionNode> fragmentsByName,
    required Map<String, String> fragmentModelCache,
    required Set<String> fragmentClassNames,
    required StringBuffer fragmentsBuffer,
  }) {
    final fragmentName = fragmentDef.name.value;
    final cached = fragmentModelCache[fragmentName];
    if (cached != null) return cached;

    final className = '${fragmentName.pascalCase}Fragment';
    // Reserve the name before recursing into the fragment's own fields so a
    // (spec-invalid) self-referential fragment can't recurse forever.
    fragmentModelCache[fragmentName] = className;

    _resolveSelectionModel(
      baseName: fragmentName.pascalCase,
      selectionSet: fragmentDef.selectionSet,
      schemaTypeName: fragmentDef.typeCondition.on.name.value,
      buffer: fragmentsBuffer,
      sharedClassNames: fragmentClassNames,
      enumNames: enumNames,
      inputNames: inputNames,
      scalarNames: scalarNames,
      customScalars: customScalars,
      schemaObjectTypesByName: schemaObjectTypesByName,
      unionTypesByName: unionTypesByName,
      interfaceTypesByName: interfaceTypesByName,
      fragmentsByName: fragmentsByName,
      fragmentModelCache: fragmentModelCache,
      fragmentClassNames: fragmentClassNames,
      fragmentsBuffer: fragmentsBuffer,
      suffix: 'Fragment',
    );

    return className;
  }

  /// Builds an import for the generated file at [targetPath] (a project-root
  /// relative path, e.g. `lib/graphql/generated/models/models.dart`) from a
  /// file that lives in [fromDir].
  ///
  /// When [packageName] is known and [targetPath] sits under `lib/`, this
  /// returns a stable `package:` import regardless of how deeply nested
  /// [fromDir] is. Otherwise it falls back to a relative import.
  static String _importFor(
      String? packageName, String targetPath, String fromDir) {
    final normalized = targetPath.replaceAll('\\', '/');
    if (packageName != null && normalized.startsWith('lib/')) {
      return 'package:$packageName/${normalized.substring('lib/'.length)}';
    }
    return p.posix
        .normalize(p.relative(targetPath, from: fromDir).replaceAll('\\', '/'));
  }

  /// True if any of [names] appears as a whole-word match in [code].
  /// Used to decide, after generating a file's body, which shared barrel
  /// imports (models.dart / inputs.dart / enums.dart) it actually needs.
  ///
  /// Compiles one alternation regex and runs a single scan over [code],
  /// rather than compiling and scanning once per candidate name — called
  /// once per generated file, so with hundreds of enums/models in a large
  /// schema this turns an O(names) regex compile+scan into one of each.
  static bool _referencesAny(String code, Iterable<String> names) {
    final nonEmpty = names.where((n) => n.isNotEmpty);
    if (nonEmpty.isEmpty) return false;
    final pattern = '\\b(?:${nonEmpty.map(RegExp.escape).join('|')})\\b';
    return RegExp(pattern).hasMatch(code);
  }

  /// Name-based scalar type heuristic — used only when schema is unavailable.
  static String _inferScalarType(String fieldName) {
    if (fieldName == 'id' ||
        fieldName == 'email' ||
        fieldName == 'name' ||
        fieldName == 'title' ||
        fieldName == 'slug' ||
        fieldName == 'token' ||
        fieldName == 'message' ||
        fieldName == 'description' ||
        fieldName == 'url') {
      return 'String';
    }
    if (fieldName == 'age' ||
        fieldName == 'count' ||
        fieldName == 'index' ||
        fieldName == 'total' ||
        fieldName == 'page' ||
        fieldName == 'limit' ||
        fieldName == 'offset' ||
        fieldName == 'size') {
      return 'int';
    }
    if (fieldName == 'price' ||
        fieldName == 'amount' ||
        fieldName == 'rating') {
      return 'double';
    }
    if (fieldName == 'isDone' ||
        fieldName == 'active' ||
        fieldName == 'enabled' ||
        fieldName == 'isActive' ||
        fieldName == 'isVerified' ||
        fieldName == 'isDeleted') {
      return 'bool';
    }
    if (fieldName == 'createdAt' ||
        fieldName == 'updatedAt' ||
        fieldName == 'deletedAt' ||
        fieldName == 'publishedAt' ||
        fieldName == 'expiresAt') {
      return 'DateTime';
    }
    return 'String';
  }
}
