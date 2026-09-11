# Generator Architecture

For contributors working on `mk_graphql_generator` itself. See [Generated Output](generated-output.md) first for the *output* contract this architecture produces.

## Pipeline

```
builder.dart (MkGraphQLBuilder)
  └─ GeneratorOrchestrator.generateForGraphQLFile(...)
       ├─ ParsedGraphQLDocument.parse(content)     [parser/graphql_parser.dart]
       ├─ SchemaGenerator.*                        [generator/schema/schema_generator.dart]
       │    ├─ generateEnums
       │    ├─ generateInputs
       │    └─ generateObjectTypes
       ├─ SchemaUtilityGenerator.generateSchemaUtilities  [generator/schema/schema_utility_generator.dart]
       └─ per-operation generation (inline in the orchestrator)
            ├─ _resolveSelectionModel / _collectEffectiveFields / _collectUsedFragmentNames
            └─ _generateFreezedClassWithTypes / _generateFreezedRequest
```

`MkGraphQLBuilder` (`lib/builder.dart`) is the `build_runner` entry point. Its `buildExtensions` are computed once at builder construction time by scanning `lib/` and calling `GeneratorOrchestrator.computeOutputPaths` for every `.graphql`/`.gql` file — this lets `build_runner` know the full output set cheaply, without running actual code generation, before any `build()` call happens.

## `ParsedGraphQLDocument` (parser)

A thin wrapper (`lib/src/parser/graphql_parser.dart`) around `package:gql`'s AST parser that buckets a parsed document's definitions into `operations`, `fragments`, `objectTypes`, `enumTypes`, `inputTypes`, `unionTypes`, `scalarTypes`. Used for both the schema file and every operations file — a schema file is just a `ParsedGraphQLDocument` whose `objectTypes`/`enumTypes`/`inputTypes` happen to be populated instead of `operations`.

## `SchemaGenerator` (schema-wide artifacts)

Static, stateless generation of:

- **Enums** (`generateEnums`) — one `@JsonEnum()` Dart enum per schema enum, `@JsonValue` mapping the wire `SCREAMING_CASE` to a camelCase Dart identifier.
- **Inputs** (`generateInputs`) — one `@freezed` class per input type, with `@JsonKey(includeIfNull: false)` on optional fields (see below).
- **Object types** (`generateObjectTypes`) — one `@freezed` `{Type}Model` class per non-root object type. Not used for operation response parsing (see [Generated Output](generated-output.md#what-modelsmodelsdart-is-for)); exists for schema-driven operations and hand-written code.
- **Type resolution** (`parseFieldType`/`formatNamedType`/`unwrapTypeName`) — the shared logic that maps a GraphQL `TypeNode` to a Dart type string plus nullability, consulting the `enumNames`/`inputNames`/`scalarNames` sets so a bare type name like `Role` resolves to the actual `Role` enum rather than falling through to the `{Name}Model` default.

`includeIfNull: false` is applied **per-field** (as `@JsonKey(includeIfNull: false)` on each optional field), not as a class-level `@JsonSerializable(includeIfNull: false)` annotation — stacking that class-level annotation on these freezed 4.x classes broke `fromJson` generation for any class that also has a `required` field. Only applied to Vars and Input classes (things sent to the server); response Model classes keep `includeIfNull: true` so `toJson()` round-trips (relevant for `optimisticResponse`) preserve explicit nulls. This matters because some GraphQL servers treat an explicit `field: null` differently from an omitted field (see the `SchemaUtilityGenerator`/`_generateFreezedClassWithTypes` call sites for exactly where each is applied).

## `SchemaUtilityGenerator` (schema-driven operations)

Generates, for every field on `Query`/`Mutation`, a `{Field}Vars`/`{Field}Req` pair plus `future`/`stream`/`refetch` extension methods on `GraphQLClient` — independent of whether any `.graphql` operation file selects that field. See [Generated Output](generated-output.md#schema-driven-operations).

## `GeneratorOrchestrator` (per-file, per-operation generation)

The largest and most important file (`lib/src/generator/orchestrator/generator_orchestrator.dart`). Its entry point `generateForGraphQLFile` handles both schema files (delegates to `SchemaGenerator`) and operation files (the per-operation logic below), returning a `GeneratedBundle` — a `Map<String, String>` of relative output path → formatted Dart source.

### Response model resolution — the core design decision

`_resolveSelectionModel` is the function that decides what Dart class represents a given selection set. The rule (detailed with examples in [Generated Output](generated-output.md#response-models-are-generated-per-operation)):

1. If the selection is a sole fragment spread (`{ ...X }`), delegate to `_getOrGenerateFragmentModel`, which caches by fragment name (`fragmentModelCache`) so the same fragment always produces the same `{Fragment}Fragment` class no matter how many operations or how many places within one operation spread it.
2. Otherwise, generate a class named by the selection's **path from the operation root** (`baseName` is threaded down and extended with each child field's pascalCase name), scoped to `sharedClassNames` which is a **fresh set per operation** — so classes never collide across operations, and nothing is shared across operations except via fragments.
3. `_collectEffectiveFields` flattens `FragmentSpreadNode`/`InlineFragmentNode` selections into a single field-by-name map before generating fields, so a directly-selected field always overrides one contributed by a spread at the same level, and no field from a spread is ever silently dropped.
4. Each field's Dart nullability/type always comes from the **schema** (`SchemaGenerator.parseFieldType`/`unwrapTypeName`), regardless of which fields are or aren't selected — trimming the selection never changes what "required" means for the fields that remain.

There is deliberately **no** "does this selection satisfy every required field of the schema type" check anymore (an earlier design tried to reuse the schema-wide `{Type}Model` when a selection happened to satisfy it, and generate a scoped fallback otherwise — this produced inconsistent output where cosmetically identical queries generated different response shapes depending on incidental field coverage, and broke when a query legitimately omitted a required field, since `fromJson` on the shared model would then get called for the parts that fit). Always generating a scoped class removes that inconsistency entirely.

### Fragment document text

A request's wire document must be self-contained: if an operation spreads `...UserFields`, the server needs `fragment UserFields on User { ... }` in the request text too. `_collectUsedFragmentNames` transitively walks the selection set (including fragments spread by other fragments) and the orchestrator appends each used fragment's printed AST to the operation's printed AST before writing the `Req` class's `document` getter.

## Caching (`GeneratorCache`)

Two-tier (in-memory `Map`, then on-disk JSON under `.dart_tool/mk_graphql_cache/`) cache keyed by SHA-256 of `{cache format version}::{input path}::{input content}::{schema content}::{shared_dir}::{package name}`. Bump `GeneratorCache.version` whenever a change to the orchestrator/schema generator would produce different output for the *same* inputs — otherwise stale disk-cached bundles from a previous generator version would be served unchanged. `useCache: false` (or the [`cache: false`](configuration.md#cache) `build.yaml` option) bypasses both tiers.

## Testing

`packages/mk_graphql_generator/test/generator_test.dart` is the primary spec for this behavior — in particular the `Shared vs Partial Models Tests` group directly documents, via assertions, the model-sharing rules above (operation-scoped naming, fragment reuse, flattening a mixed spread-plus-extra-fields selection). When changing `_resolveSelectionModel` or the fragment-handling functions, extend that group rather than writing a new one.
