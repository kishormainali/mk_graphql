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

class GeneratorOrchestrator {
  static GeneratedBundle generateForGraphQLFile({
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
  }) {
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

    final parsed = ParsedGraphQLDocument.parse(content);

    // A file is the schema when its path matches schemaPath or its basename is 'schema'
    final fileName = p.basenameWithoutExtension(inputPath);
    final resolvedSchemaPath =
        schemaPath ?? p.join(p.dirname(inputPath), 'schema.graphql');
    final isSchemaFile = (schemaPath != null &&
            p.normalize(inputPath) == p.normalize(schemaPath)) ||
        fileName == 'schema';
    final files = <String, String>{};

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
      } catch (_) {}
    }

    // Fast-lookup maps keyed by GraphQL type name
    final schemaObjectTypesByName = <String, ObjectTypeDefinitionNode>{
      for (final t in schemaParsed?.objectTypes ?? <ObjectTypeDefinitionNode>[])
        t.name.value: t,
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

    // -----------------------------------------------------------------------
    // 1. Enums  → {sharedPrefix}enums/{snake}_enum.dart
    // -----------------------------------------------------------------------
    if (isSchemaFile && parsed.enumTypes.isNotEmpty) {
      final enumFilesMap = SchemaGenerator.generateEnums(parsed.enumTypes);
      enumFilesMap.forEach((path, code) {
        files['${sharedPrefix}$path'] = code;
      });
    }

    // -----------------------------------------------------------------------
    // 2. Inputs → {sharedPrefix}inputs/{snake}.dart
    // -----------------------------------------------------------------------
    if (isSchemaFile && parsed.inputTypes.isNotEmpty) {
      final inputFilesMap = SchemaGenerator.generateInputs(
        parsed.inputTypes,
        enumNames,
        inputNames,
        scalarNames: scalarNames,
        customScalars: customScalars,
        packageName: packageName,
        generatedDir: schemaGeneratedDir,
      );
      inputFilesMap.forEach((path, code) {
        files['${sharedPrefix}$path'] = code;
      });
    }

    // Names of the shared `{Type}Model` classes exported from the schema's
    // models.dart barrel (excludes root Query/Mutation/Subscription, which
    // never get their own generated model file). Only consumed by the
    // schema-driven client extension (item 4) — per-operation response
    // models (item 5) are always scoped to the operation's own selection.
    final sharedModelNames = <String>{
      for (final t in schemaObjectTypesByName.keys)
        if (t != 'Query' && t != 'Mutation' && t != 'Subscription')
          '${t.pascalCase}Model',
    };

    // -----------------------------------------------------------------------
    // 3. Object types → {sharedPrefix}models/{snake}_model.dart
    //
    // These full-schema `{Type}Model` classes are consumed only by the
    // schema-driven client extension below (item 4), which fetches an
    // entire type with no field selection to work from. Per-operation
    // response models (item 5) never reuse these — each .graphql selection
    // gets its own model scoped to exactly the fields it queried.
    // -----------------------------------------------------------------------
    if (isSchemaFile && parsed.objectTypes.isNotEmpty) {
      final objectFilesMap = SchemaGenerator.generateObjectTypes(
        parsed.objectTypes,
        enumNames,
        inputNames,
        scalarNames: scalarNames,
        customScalars: customScalars,
        packageName: packageName,
        generatedDir: schemaGeneratedDir,
      );
      objectFilesMap.forEach((path, code) {
        files['${sharedPrefix}$path'] = code;
      });
    }

    // -----------------------------------------------------------------------
    // 4. Schema utilities (Req / Vars / extension from Query & Mutation fields)
    // -----------------------------------------------------------------------
    final queryType = parsed.objectTypes.firstWhere(
      (o) => o.name.value == 'Query',
      orElse: () =>
          ObjectTypeDefinitionNode(name: NameNode(value: 'Query'), fields: []),
    );
    final mutationType = parsed.objectTypes.firstWhere(
      (o) => o.name.value == 'Mutation',
      orElse: () => ObjectTypeDefinitionNode(
          name: NameNode(value: 'Mutation'), fields: []),
    );

    String schemaUtilCode = '';
    if (queryType.fields.isNotEmpty || mutationType.fields.isNotEmpty) {
      schemaUtilCode = SchemaUtilityGenerator.generateSchemaUtilities(
        objectTypes: parsed.objectTypes,
        enumNames: enumNames,
        inputNames: inputNames,
        scalarNames: scalarNames,
        customScalars: customScalars,
        unionTypes: parsed.unionTypes,
        interfaceTypes: parsed.interfaceTypes,
      );
    }

    // -----------------------------------------------------------------------
    // 5. Operations from feature .graphql / .gql files
    // -----------------------------------------------------------------------
    final opExports = <({String exportPath, List<String> modelClasses})>[];
    final fileOpExtensions = StringBuffer();

    // Named fragments in this file are the only sanctioned way a response
    // model is shared across operations — generated once, on first use,
    // into generated/fragments/fragments.dart.
    final fragmentsByName = <String, FragmentDefinitionNode>{
      for (final f in parsed.fragments) f.name.value: f,
    };
    final fragmentModelCache = <String, String>{};
    final fragmentClassNames = <String>{};
    final fragmentsBuffer = StringBuffer();
    final fragmentsDirPath = p.join(inputDir, 'generated', 'fragments');
    final fragmentsFilePath = p.join(fragmentsDirPath, 'fragments.dart');

    if (parsed.operations.isNotEmpty) {
      final extClassName = '${fileName.pascalCase}GraphQLClientExtension';
      fileOpExtensions.writeln(
          '/// Auto-generated Client Extension for operations in $fileName');
      fileOpExtensions.writeln('extension $extClassName on GraphQLClient {');

      for (final op in parsed.operations) {
        final sharedClassNames = <String>{};

        final rawName = op.name?.value ?? 'AnonymousOperation';
        final name = rawName.pascalCase;
        final methodName = rawName.camelCase;
        final opDir = rawName.snakeCase;

        final varsClassName = '${name}Vars';
        final modelClassName = '${name}Model';
        final reqClassName = '${name}Req';

        // Paths for relative imports inside generated/{opDir}/
        final targetOpDir = p.join(inputDir, 'generated', opDir);
        final schemaInputsPath =
            p.join(resolvedSharedDir, 'inputs', 'inputs.dart');
        final schemaEnumsPath =
            p.join(resolvedSharedDir, 'enums', 'enums.dart');

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
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
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
        if (_referencesAny(varBody, inputNames))
          varBuffer.writeln("import '$sharedInputImport';");
        if (_referencesAny(varBody, enumNames))
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
        final isMutation = op.type == OperationType.mutation;
        final schemaRootTypeName = isMutation ? 'Mutation' : 'Query';
        final schemaRootType = schemaObjectTypesByName[schemaRootTypeName];

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
                  schemaObjectTypesByName.containsKey(schemaTypeName)) {
                final autoSel = SchemaUtilityGenerator.buildSelectionSetNode(
                  type: schemaFieldDef!.type,
                  objectTypesByName: schemaObjectTypesByName,
                  enumNames: enumNames,
                  inputNames: inputNames,
                  scalarNames: scalarNames,
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
              enumNames: enumNames,
              inputNames: inputNames,
              scalarNames: scalarNames,
              customScalars: customScalars,
              schemaObjectTypesByName: schemaObjectTypesByName,
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
                enumNames: enumNames,
                inputNames: inputNames,
                scalarNames: scalarNames,
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
          if (_referencesAny(modelBody, inputNames))
            modelBuffer.writeln("import '$sharedInputImport';");
          if (_referencesAny(modelBody, enumNames))
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
              enumNames: enumNames,
              inputNames: inputNames,
              scalarNames: scalarNames,
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
        final refetchMethodName = 'refetch${rawName.pascalCase}';

        for (final method in [
          codegen.clientExtensionMethod(
            kind: 'future',
            methodName: methodName,
            modelClassName: modelClassName,
            reqClassName: reqClassName,
            varsClassName: varsClassName,
            args: opArgs,
            docComment: 'Future execution for $methodName',
          ),
          codegen.clientExtensionMethod(
            kind: 'stream',
            methodName: '${methodName}Stream',
            modelClassName: modelClassName,
            reqClassName: reqClassName,
            varsClassName: varsClassName,
            args: opArgs,
            docComment: 'Stream execution for $methodName',
          ),
          codegen.clientExtensionMethod(
            kind: 'refetch',
            methodName: refetchMethodName,
            modelClassName: modelClassName,
            reqClassName: reqClassName,
            varsClassName: varsClassName,
            args: opArgs,
            docComment:
                'Refetch execution for $methodName (bypasses cache with FetchPolicy.networkOnly)',
          ),
        ]) {
          fileOpExtensions.writeln(codegen.emitSpec(method));
        }
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
            p.join(resolvedSharedDir, 'inputs', 'inputs.dart'),
            fragmentsDirPath);
        final fragEnumsImport = _importFor(packageName,
            p.join(resolvedSharedDir, 'enums', 'enums.dart'), fragmentsDirPath);
        if (_referencesAny(fragmentsBody, inputNames))
          fragmentsFileBuffer.writeln("import '$fragInputsImport';");
        if (_referencesAny(fragmentsBody, enumNames))
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

    // -----------------------------------------------------------------------
    // 6. Root barrel file: generated/{fileName}.gql.dart
    // -----------------------------------------------------------------------
    // Whether this barrel's own generated code (schema utilities + client
    // extension methods) actually references enum/input/model type names
    // directly — used to decide which imports (not exports, which stay
    // unconditional for barrel convenience) are actually needed.
    final rootUsageText = schemaUtilCode + fileOpExtensions.toString();

    final rootBarrelBuffer = StringBuffer();
    rootBarrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    rootBarrelBuffer.writeln('// ignore_for_file: type=lint');
    if (schemaUtilCode.isNotEmpty) {
      rootBarrelBuffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
    }
    if (schemaUtilCode.isNotEmpty || fileOpExtensions.isNotEmpty) {
      rootBarrelBuffer.writeln("import 'package:mk_graphql/mk_graphql.dart';");
    }

    final targetGeneratedDir =
        isSchemaFile ? resolvedSharedDir : p.join(inputDir, 'generated');
    final schemaModelsPath = p.join(resolvedSharedDir, 'models', 'models.dart');
    final schemaInputsPath = p.join(resolvedSharedDir, 'inputs', 'inputs.dart');
    final schemaEnumsPath = p.join(resolvedSharedDir, 'enums', 'enums.dart');

    final barrelModelImport =
        _importFor(packageName, schemaModelsPath, targetGeneratedDir);
    final barrelInputImport =
        _importFor(packageName, schemaInputsPath, targetGeneratedDir);
    final barrelEnumImport =
        _importFor(packageName, schemaEnumsPath, targetGeneratedDir);

    if (isSchemaFile) {
      if (parsed.enumTypes.isNotEmpty) {
        if (_referencesAny(rootUsageText, enumNames))
          rootBarrelBuffer.writeln("import '$barrelEnumImport';");
        rootBarrelBuffer.writeln("export 'enums/enums.dart';");
      }
      if (parsed.inputTypes.isNotEmpty) {
        if (_referencesAny(rootUsageText, inputNames))
          rootBarrelBuffer.writeln("import '$barrelInputImport';");
        rootBarrelBuffer.writeln("export 'inputs/inputs.dart';");
      }
      if (parsed.objectTypes
          .where((o) =>
              o.name.value != 'Query' &&
              o.name.value != 'Mutation' &&
              o.name.value != 'Subscription')
          .isNotEmpty) {
        if (_referencesAny(rootUsageText, sharedModelNames))
          rootBarrelBuffer.writeln("import '$barrelModelImport';");
        rootBarrelBuffer.writeln("export 'models/models.dart';");
      }
    } else {
      if (enumNames.isNotEmpty) {
        if (_referencesAny(rootUsageText, enumNames)) {
          rootBarrelBuffer.writeln("import '$barrelEnumImport';");
        }
        rootBarrelBuffer.writeln("export '$barrelEnumImport';");
      }
      if (inputNames.isNotEmpty) {
        if (_referencesAny(rootUsageText, inputNames)) {
          rootBarrelBuffer.writeln("import '$barrelInputImport';");
        }
        rootBarrelBuffer.writeln("export '$barrelInputImport';");
      }
      if (sharedModelNames.isNotEmpty) {
        if (_referencesAny(rootUsageText, sharedModelNames)) {
          rootBarrelBuffer.writeln("import '$barrelModelImport';");
        }
        rootBarrelBuffer.writeln("export '$barrelModelImport';");
      }
      if (fragmentClassNames.isNotEmpty) {
        final barrelFragmentsExport =
            _importFor(packageName, fragmentsFilePath, targetGeneratedDir);
        rootBarrelBuffer.writeln("export '$barrelFragmentsExport';");
      }
    }

    final exportedClassesSoFar = <String>{};
    for (final opExp in opExports) {
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
      rootBarrelBuffer.writeln("part '$fileName.gql.freezed.dart';");
      rootBarrelBuffer.writeln("part '$fileName.gql.g.dart';");
      rootBarrelBuffer.writeln();
      rootBarrelBuffer.writeln(schemaUtilCode);
    }

    if (fileOpExtensions.isNotEmpty) {
      rootBarrelBuffer.writeln(fileOpExtensions.toString());
    }

    final targetBarrelPath = isSchemaFile
        ? '${sharedPrefix}$fileName.gql.dart'
        : 'generated/$fileName.gql.dart';
    files[targetBarrelPath] = rootBarrelBuffer.toString();

    // -----------------------------------------------------------------------
    // Format all generated Dart code
    // -----------------------------------------------------------------------
    final formattedFiles = <String, String>{};
    final formatter =
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);
    files.forEach((path, unformattedCode) {
      try {
        formattedFiles[path] = formatter.format(unformattedCode);
      } catch (_) {
        formattedFiles[path] = unformattedCode;
      }
    });

    final bundle = GeneratedBundle(files: formattedFiles);
    if (useCache && cacheKey != null) {
      GeneratorCache.put(cacheKey, bundle);
    }
    return bundle;
  }

  /// Computes the list of expected output file paths (relative to [inputPath]'s directory)
  /// without running expensive code generation, string interpolation, or DartFormatter.
  static List<String> computeOutputPaths({
    required String content,
    required String inputPath,
    String? schemaPath,
    String? sharedDir,
  }) {
    if (!inputPath.endsWith('.graphql') && !inputPath.endsWith('.gql')) {
      return const [];
    }

    final parsed = ParsedGraphQLDocument.parse(content);
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
  }) {
    buffer.writeln(codegen.emitSpec(codegen.freezedDataClass(
      className: className,
      fields: fields,
      includeIfNull: includeIfNull,
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
    required Map<String, FragmentDefinitionNode> fragmentsByName,
    required Map<String, String> fragmentModelCache,
    required Set<String> fragmentClassNames,
    required StringBuffer fragmentsBuffer,
    String suffix = 'Model',
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

    final schemaType =
        schemaTypeName != null ? schemaObjectTypesByName[schemaTypeName] : null;
    final fields = <String, FieldTypeInfo>{};

    for (final child
        in _collectEffectiveFields(selectionSet, fragmentsByName)) {
      final childName = child.alias?.value ?? child.name.value;
      final childSchemaFieldDef = schemaType?.fields
          .where((f) => f.name.value == child.name.value)
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
    );

    return className;
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
  static bool _referencesAny(String code, Iterable<String> names) {
    for (final name in names) {
      if (name.isEmpty) continue;
      if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(code)) return true;
    }
    return false;
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
