import 'package:code_builder/code_builder.dart';
import 'schema/schema_generator.dart' show FieldTypeInfo, SchemaGenerator;

/// Structural (code_builder-based) emission for the freezed-class shapes
/// this generator produces in several places (schema inputs/models, request
/// variables, per-operation response models, request classes), so every
/// call site builds the same AST instead of hand-writing matching
/// StringBuffer output. A final `DartFormatter` pass (run once over the
/// whole generated file, same as before this module existed) is what makes
/// the output readable — this only needs to be structurally correct.
final _emitter = DartEmitter(useNullSafetySyntax: true);

String emitSpec(Spec spec) => spec.accept(_emitter).toString();

/// Wraps a raw Dart expression string as a lambda-renderable body
/// (`=> expr`), matching every getter/method this generator emits.
///
/// Goes through [refer] (not `CodeExpression(...).code`, which shadows
/// [Expression.code] with the plain, non-lambda-tagged [Code] it wraps) so
/// the emitter's lambda detection (`code is ToCodeExpression`) sees it.
Code _exprBody(String expr) => refer(expr).code;

Parameter _namedParam(
  String name, {
  required String type,
  bool required = false,
  List<Expression> annotations = const [],
}) {
  return Parameter((p) => p
    ..name = name
    ..named = true
    ..required = required
    ..type = refer(type)
    ..annotations.addAll(annotations));
}

/// `@freezed abstract class X with _$X { const factory X({...}) = _X;
/// factory X.fromJson(json) => _$XFromJson(json); }` — the shape shared by
/// every Vars/Model/Input class this generator emits, whatever field set
/// backs it.
///
/// [includeIfNull] mirrors freezed_annotation's `@JsonKey(includeIfNull:)`:
/// pass false so an unset optional field is omitted from `toJson()` instead
/// of serialized as an explicit `null` (used for Input/Vars classes sent to
/// the server; response Model classes default to true).
Class freezedDataClass({
  required String className,
  required Map<String, FieldTypeInfo> fields,
  bool includeIfNull = true,
}) {
  final params = <Parameter>[];
  fields.forEach((rawName, typeInfo) {
    final dartName = SchemaGenerator.safeIdentifier(rawName);
    final keyArgs = <String>[
      if (dartName != rawName) "name: '$rawName'",
      if (!includeIfNull &&
          !typeInfo.isRequired &&
          typeInfo.defaultValue == null)
        'includeIfNull: false',
    ];
    final isRequired = typeInfo.defaultValue == null && typeInfo.isRequired;
    final type = typeInfo.defaultValue != null || isRequired
        ? typeInfo.dartType
        : '${typeInfo.dartType}?';

    params.add(_namedParam(
      dartName,
      type: type,
      required: isRequired,
      annotations: [
        if (keyArgs.isNotEmpty)
          CodeExpression(Code('JsonKey(${keyArgs.join(', ')})')),
        if (typeInfo.defaultValue != null)
          CodeExpression(Code('Default(${typeInfo.defaultValue})')),
      ],
    ));
  });

  return Class((b) => b
    ..abstract = true
    ..name = className
    ..annotations.add(refer('freezed'))
    ..mixins.add(refer('_\$$className'))
    ..constructors.addAll([
      Constructor((c) => c
        ..constant = true
        ..factory = true
        ..redirect = refer('_$className')
        ..optionalParameters.addAll(params)),
      Constructor((c) => c
        ..factory = true
        ..name = 'fromJson'
        ..requiredParameters.add(Parameter((p) => p
          ..name = 'json'
          ..type = refer('Map<String, dynamic>')))
        ..body = _exprBody('_\$${className}FromJson(json)')),
    ]));
}

/// `@freezed abstract class XReq extends GraphQLRequest<Model, Vars> with
/// _$XReq { ... }` — the request-class shape shared by every generated
/// operation (both `.graphql`-file operations and schema-derived Query /
/// Mutation fields): standard request fields, a single `_document` source
/// of truth for the query text, and a `_documentNode` parsed once per
/// class.
Class freezedRequestClass({
  required String reqClassName,
  required String varsClassName,
  required String modelClassName,
  required String docStr,
  required String operationName,
  required String parseDataExpr,
}) {
  Method getter(String name, String returns, String expr) => Method((m) => m
    ..annotations.add(refer('override'))
    ..type = MethodType.getter
    ..returns = refer(returns)
    ..name = name
    ..body = _exprBody(expr));

  return Class((b) => b
    ..abstract = true
    ..name = reqClassName
    ..annotations.add(refer('freezed'))
    ..extend = refer('GraphQLRequest<$modelClassName, $varsClassName>')
    ..mixins.add(refer('_\$$reqClassName'))
    ..constructors.addAll([
      Constructor((c) => c
        ..constant = true
        ..factory = true
        ..redirect = refer('_$reqClassName')
        ..optionalParameters.addAll([
          _namedParam('variables', type: varsClassName, required: true),
          _namedParam('fetchPolicy', type: 'FetchPolicy?'),
          _namedParam('errorPolicy', type: 'ErrorPolicy?'),
          _namedParam('headers', type: 'Map<String, String>?'),
          _namedParam('cancelToken', type: 'CancelToken?'),
          _namedParam('optimisticResponse', type: '$modelClassName?'),
          _namedParam('staleTime', type: 'Duration?'),
          _namedParam('cacheTime', type: 'Duration?'),
          _namedParam('retry', type: 'RetryOptions?'),
          _namedParam('refetchInterval', type: 'Duration?'),
        ])),
      Constructor((c) => c
        ..constant = true
        ..name = '_'),
    ])
    ..fields.addAll([
      // Single source of truth for the query text — document and
      // documentNode both read from this instead of embedding it twice.
      Field((f) => f
        ..static = true
        ..modifier = FieldModifier.constant
        ..type = refer('String')
        ..name = '_document'
        ..assignment = Code('r"""$docStr"""')),
      // Parsed once per class, skipping even the string-keyed cache lookup
      // GraphQLRequest.documentNode's default falls back to.
      Field((f) => f
        ..static = true
        ..modifier = FieldModifier.final$
        ..type = refer('DocumentNode')
        ..name = '_documentNode'
        ..assignment = Code('GraphQLClient.getParsedDocument(_document)')),
    ])
    ..methods.addAll([
      getter('document', 'String', '_document'),
      getter('documentNode', 'DocumentNode', '_documentNode'),
      getter('operationName', 'String', '"$operationName"'),
      Method((m) => m
        ..annotations.add(refer('override'))
        ..returns = refer('Map<String, dynamic>')
        ..name = 'toJsonVars'
        ..requiredParameters.add(Parameter((p) => p
          ..name = 'vars'
          ..type = refer(varsClassName)))
        ..body = _exprBody('(vars as dynamic).toJson()')),
      Method((m) => m
        ..annotations.add(refer('override'))
        ..returns = refer(modelClassName)
        ..name = 'parseData'
        ..requiredParameters.add(Parameter((p) => p
          ..name = 'json'
          ..type = refer('Map<String, dynamic>')))
        ..body = _exprBody(parseDataExpr)),
      Method((m) => m
        ..annotations.add(refer('override'))
        ..returns = refer(reqClassName)
        ..name = 'copyWithRequest'
        ..optionalParameters.addAll([
          _namedParam('variables', type: '$varsClassName?'),
          _namedParam('fetchPolicy', type: 'FetchPolicy?'),
          _namedParam('errorPolicy', type: 'ErrorPolicy?'),
          _namedParam('headers', type: 'Map<String, String>?'),
          _namedParam('cancelToken', type: 'CancelToken?'),
          _namedParam('optimisticResponse', type: '$modelClassName?'),
        ])
        ..body = _exprBody('''copyWith(
          variables: variables ?? this.variables,
          fetchPolicy: fetchPolicy ?? this.fetchPolicy,
          errorPolicy: errorPolicy ?? this.errorPolicy,
          headers: headers ?? this.headers,
          cancelToken: cancelToken ?? this.cancelToken,
          optimisticResponse: optimisticResponse ?? this.optimisticResponse,
          staleTime: staleTime ?? this.staleTime,
          cacheTime: cacheTime ?? this.cacheTime,
          retry: retry ?? this.retry,
          refetchInterval: refetchInterval ?? this.refetchInterval,
        )''')),
    ]));
}

/// `@JsonEnum() enum Name { @JsonValue("WIRE_VALUE") dartName, ... }` — every
/// schema enum this generator emits. [values] maps each wire value (e.g.
/// `ADMIN_USER`) to its Dart identifier (e.g. `adminUser`).
Enum jsonEnum({
  required String name,
  required Map<String, String> values,
}) {
  return Enum((b) => b
    ..name = name
    ..annotations.add(CodeExpression(Code('JsonEnum()')))
    ..values.addAll(values.entries.map((e) => EnumValue((v) => v
      ..name = e.value
      ..annotations.add(CodeExpression(Code('JsonValue("${e.key}")')))))));
}

Parameter _operationParam(String rawName, FieldTypeInfo info) {
  final dartName = SchemaGenerator.safeIdentifier(rawName);
  return Parameter((p) {
    p
      ..name = dartName
      ..named = true;
    if (info.defaultValue != null) {
      p
        ..type = refer(info.dartType)
        ..defaultTo = Code(info.defaultValue!);
    } else if (info.isRequired) {
      p
        ..type = refer(info.dartType)
        ..required = true;
    } else {
      p.type = refer('${info.dartType}?');
    }
  });
}

/// One `future`/`stream`/`refetch` execution method on a generated
/// `GraphQLClient` extension, e.g.:
/// ```dart
/// Future<Model> methodName({...args, fetchPolicy, errorPolicy, headers, cancelToken}) {
///   return future(ReqClassName(variables: VarsClassName(...args), fetchPolicy: ..., ...));
/// }
/// ```
/// [kind] is `'future'`, `'stream'`, or `'refetch'` — it picks the
/// `GraphQLClient` method called, the return type wrapper (`Future`/
/// `Stream`), and two call-shape quirks matched from the pre-code_builder
/// implementation: refetch has no `fetchPolicy` param (it always forces
/// `FetchPolicy.networkOnly` internally), and stream declares but never
/// forwards `cancelToken` (unchanged here — not this migration's job to fix).
Method clientExtensionMethod({
  required String kind,
  required String methodName,
  required String modelClassName,
  required String reqClassName,
  required String varsClassName,
  required Map<String, FieldTypeInfo> args,
  String? docComment,
}) {
  final isRefetch = kind == 'refetch';
  final isStream = kind == 'stream';

  final varNames = args.keys.map(SchemaGenerator.safeIdentifier);
  final varsArg = args.isEmpty
      ? 'const $varsClassName()'
      : '$varsClassName(${varNames.map((n) => '$n: $n,').join()})';

  final callArgs = [
    'variables: $varsArg,',
    if (!isRefetch) 'fetchPolicy: fetchPolicy,',
    'errorPolicy: errorPolicy,',
    'headers: headers,',
    if (!isStream) 'cancelToken: cancelToken,',
  ].join();

  return Method((m) => m
    ..docs.addAll([if (docComment != null) '/// $docComment'])
    ..returns = refer('${isStream ? 'Stream' : 'Future'}<$modelClassName>')
    ..name = methodName
    ..optionalParameters.addAll([
      for (final entry in args.entries) _operationParam(entry.key, entry.value),
      if (!isRefetch) _namedParam('fetchPolicy', type: 'FetchPolicy?'),
      _namedParam('errorPolicy', type: 'ErrorPolicy?'),
      _namedParam('headers', type: 'Map<String, String>?'),
      _namedParam('cancelToken', type: 'CancelToken?'),
    ])
    ..body = Code('return $kind($reqClassName($callArgs));'));
}
