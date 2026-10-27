## Unreleased

- **Feature**: subscriptions are generated. Schema `Subscription` fields and `.graphql` `subscription` operations get `Req`/`Vars`/model classes and a single `Stream<Model> name(...)` client method (no `Future`/`refetch`). Previously schema subscriptions were skipped and `.graphql` subscriptions resolved their fields against `Query`.

## 1.2.2

- **New**: every generated enum now has `static Name? fromString(String? value)`, converting a wire value (e.g. `'ADMIN_USER'`) to its constant (`UserRole.adminUser`). Returns `null` for `null` or an unrecognized value, so it's safe on server enums that gain new values. Each enum also gets `String get value` returning the wire value, so `Enum.fromString(e.value) == e`. Schema enum values named `value` or `fromString` are escaped to `gValue`/`gFromString` (like Dart keywords) so they can't clash with these members.

## 1.2.1

- **Fix**: the reserved-word list used by `safeIdentifier` to escape field names to `g{Name}` is now a curated set of Dart's actual reserved words, built-in identifiers, and `dart:core` type names, replacing the previous list derived from `package:_fe_analyzer_shared`'s full `Keyword` table. `inout`, `native`, `of`, `out`, `patch`, and `source` are context-only pseudo-keywords that are valid Dart identifiers outside their specific syntactic positions (FFI `native` functions, variance annotations, augmentation libraries) — fields named after them are no longer escaped. `bigInt`, `list`, `map`, `never`, `object`, `record`, `runes`, `string`, and `symbol` (additional `dart:core` type names, alongside the already-covered `int`/`double`/`bool`/`num`) are now escaped for the same reason those four already were: a field named after a type shadows that type for the rest of the enclosing class.

## 1.2.1-dev.4

- **Breaking**: `GeneratorOrchestrator.generateForGraphQLFile` is now `async`, returning `Future<GeneratedBundle>` instead of `GeneratedBundle`. This is needed to parallelize the `DartFormatter` pass across isolates (see the perf entry below). `MkGraphQLBuilder.build()` (the actual `build_runner` entry point) already awaits it, so nothing changes for consumers using the builder via `build.yaml`/`build_runner` — this only affects code calling `GeneratorOrchestrator.generateForGraphQLFile` directly (uncommon outside this package's own tests). `computeOutputPaths` is unaffected and stays synchronous.
- **Perf**: `DartFormatter.format` — which re-parses and pretty-prints every generated file — was found to dominate generation time (profiling a medium schema: ~78% of total generation time was formatting, and just the two root barrel files, which bundle every schema utility and every operation's client extension method into one file each, accounted for ~66% of that). Formatting now runs across a small pool of isolates (each `format()` call is independent, pure, and CPU-bound), bin-packed by content length so the largest files each land on their own worker instead of being split evenly by file count. Measured ~40% faster formatting, ~18% faster full cold-build cycle on a representative schema. See `benchmark/generator_benchmark.dart` (`dart run benchmark/generator_benchmark.dart`) for the numbers on your own machine.
- **Perf**: `MkGraphQLBuilder`'s factory (which must scan every `.graphql`/`.gql` file up front to declare `buildExtensions`, a `build_runner` requirement) now caches the parse it does for that scan and reuses it in `build()` instead of parsing the same file's content again — halves parse work on a fresh `build_runner build`, where every file is a cache miss. The factory also now does a single recursive `lib/` scan instead of two (schema auto-detection reuses the same file list `.graphql`/`.gql` discovery already collected, instead of a separate directory walk). New `computeOutputPaths`/`generateForGraphQLFile` parameter `preParsed` powers this — pass an already-parsed `ParsedGraphQLDocument` to skip the internal parse.
- **Perf**: `GeneratorCache`'s in-memory map is now LRU-capped (`maxMemoryEntries`, default 500) instead of growing forever across a long `build_runner watch` session; its on-disk cache is pruned by mtime past `maxDiskEntries` (default 2000, checked every 200 writes) instead of growing forever across the project's lifetime; and cache writes no longer pass `flush: true`, so a build's disk I/O no longer serializes unnecessarily.
- **Perf**: `buildSelectionSetNode`'s result is now memoized per return-type name across one schema-utilities generation pass — a schema where several Query/Mutation fields return the same object type (a common CRUD pattern) no longer re-walks that type's entire selection subtree once per field. `_referencesAny` (decides which shared barrel imports a generated file needs) now compiles one alternation regex per call instead of one regex per candidate name, turning an O(names) compile+scan into O(1) per generated file.
- **Fix**: every previously-silent `catch (_) {}` (a malformed schema file, an unreadable `build.yaml`, a broken query file) now logs a warning with the actual error instead of failing invisibly and producing incomplete or stale generated output with no diagnostic.
- **Internal**: `generator_orchestrator.dart`'s single ~716-line `generateForGraphQLFile` method is split into 6 named, independently-documented stages (`_resolveGenerationContext`, `_generateSchemaSharedFiles`, `_generateSchemaUtilitiesCode`, `_generateOperations`, `_generateRootBarrel`, `_formatGeneratedFiles`) — verified behavior-identical against the full existing test suite, which asserts exact generated output. The duplicated future/stream/refetch client-method-triple emission (previously built independently in both the orchestrator and the schema-utility generator) is now one shared `codegen.emitOperationMethodTriple`.

## 1.2.1-dev.3

- **Fix**: growing a schema (adding an `enum`/`input`/`type`) while `dart run build_runner watch` is already running could leave `generated/models/models.dart` and `generated/inputs/inputs.dart` missing export entries for types that genuinely exist on disk, breaking `json_serializable`'s type resolution for anything importing those barrels. Root cause: `buildExtensions` (which files build_runner will let the builder write) is computed once when the builder starts, by predicting one output file per schema type; a schema growing mid-`watch` produces a new per-type file build_runner never declared, aborting that build before the barrel got rewritten.
- **Breaking**: fixed by merging the schema-level per-type files into three fixed files — `enums/{type}_enum.dart` → `enums/enums.dart`, `inputs/{type}.dart` → `inputs/inputs.dart`, `models/{type}_model.dart` → `models/models.dart` — so the schema file's declared output set no longer depends on how many types it defines. Regenerate (`dart run build_runner build --delete-conflicting-outputs`) to pick this up; the generator's on-disk cache is automatically invalidated (`GeneratorCache` bumped to v16). Any app importing one of the old per-type file paths directly (rather than the barrel, which is what the README/docs have always shown) needs to switch to importing the barrel instead — e.g. `import 'generated/models/user_model.dart'` becomes `import 'generated/models/models.dart'`.
- **Known limitation, unchanged by this fix**: a schema's *first-ever* enum, input, or object type appearing while `watch` is already running still requires a restart — that category's file existence (not just its size) is still content-dependent. Adding a type to a category the schema already has does not. The symptom is `build_runner` reporting `UnexpectedOutputException` naming `enums.dart`/`inputs.dart`/`models.dart`, and — since that failed build step also discards the *other* outputs it would have written (`models.dart`, its `.freezed.dart`/`.g.dart`, `schema.gql.dart`, etc.) as collateral — the app won't compile until `watch` is restarted; restarting `watch` fully resolves it. Operation (`.graphql` query/mutation) files have an analogous, separate limitation: adding a new operation to an existing file, or creating a brand-new `.graphql` file, while `watch` is running also isn't picked up without a restart.

## 1.2.1-dev.2

- **Fix**: a GraphQL field named after a Dart core type (`int`, `double`, `bool`, or `num`) — e.g. `double: Float!` — now maps to `g{Name}` (`gDouble`, `@JsonKey(name: 'double')`) the same way a real reserved keyword already did. Previously it generated e.g. `final double double;`, which fails to compile: declaring a field named `double` shadows the *type* `double` for the rest of the enclosing class, so any other field actually typed `double` in that same class stops resolving too.
- **Fix**: the reserved-keyword list is now generated from `package:_fe_analyzer_shared`'s own `Keyword` table (every reserved word, built-in identifier, and pseudo keyword Dart's scanner recognizes), so fields named `base`, `sealed`, `when`, `augment`, `inout`, `out`, `patch`, or `source` are now also escaped — previously only a partial hand-maintained list was covered.
- Regenerate (`dart run build_runner build --delete-conflicting-outputs`) to pick this up — the generator's on-disk cache (`.dart_tool/mk_graphql_cache`) is automatically invalidated (`GeneratorCache` bumped to v15).

## 1.2.1-dev.1

- **New**: every generated response Model class (operation-level wrappers, schema-level shared models, and nested selection-scoped models — anything with `includeIfNull: true`) now declares an optional `@JsonKey(name: '__typename', includeIfNull: false) String? typename` field. Previously `__typename` (injected into every selection set by `TypenameLink`) was silently dropped by `fromJson` and could never be reproduced by `toJson()`, which meant it never reached `GraphQLClient.cache` (populated from the *parsed* model, not the raw response) — permanently breaking `invalidateQueries(types: ...)`/`Cache.matchingQueryKeys(types: ...)` for every generated model (`operationNames:`-based invalidation was unaffected, since it matches on the request, not the response). Regenerate (`dart run build_runner build --delete-conflicting-outputs`) to pick this up — the generator's on-disk cache (`.dart_tool/mk_graphql_cache`) is automatically invalidated. Vars/Input classes (`includeIfNull: false`) never get this field, since they're sent to the server, not received from it.

## 1.2.1-dev.0

- **Internal**: Freezed data classes, request classes, schema enums, and `GraphQLClient` extension methods (`future`/`stream`/`refetch`) are now emitted structurally via `code_builder` instead of hand-written `StringBuffer` writes, and the five near-duplicate implementations of these shapes (previously spread across `generator_orchestrator.dart` and `schema_utility_generator.dart`) are consolidated into a single shared `dart_codegen.dart` module. No generated-code behavior changes; output is functionally identical, verified byte-for-byte except for field/method ordering inside a handful of `*Req` classes (fields now grouped before methods, matching `code_builder`'s `Class` structure — cosmetic only, resolved by the existing `DartFormatter` pass either way).
- **Removed**: Deleted `CombinerGenerator` (`combiner_generator.dart`) — dead code with no call sites anywhere in the package.

## 1.2.0

- **Pre-parsed request documents**: Generated `*Req` classes now override `GraphQLRequest.documentNode` with a `static final DocumentNode` parsed once per class (via `GraphQLClient.getParsedDocument`), so `GraphQLClient` no longer needs to parse or cache-lookup the query string on every request of that type. Requires `mk_graphql` >= 1.2.0.

## 1.1.1

- **Automatic Selection Sets for Schema Client Extensions**: Automatically generates selection sets for operations and typed `GraphQLClient` extension methods returning composite types (objects, interfaces, unions) such as `register(input: RegisterInput!): RegisterResponse!`, resolving `GRAPHQL_VALIDATION_FAILED` errors where subfields were missing.
- **Cycle Detection & Depth Limiting**: Automatically breaks recursive or self-referential schema cycles (e.g. `User -> User`) and caps expansion depth safely.
- **Required Argument Filtering**: Skips subfields that define required (non-null without default) arguments during automatic selection set generation, ensuring generated queries remain valid.
- **Feature Operation Selection Set Synthesis**: Synthesizes missing selection sets for object fields in hand-written `.graphql` operations.
- **Interface Type AST Parsing**: Added collection of `interfaceTypes` in `ParsedGraphQLDocument` and support for interface field selections.
- **Enum Return Type Parsing**: Added direct enum decoding in schema-driven client operations.

## 1.1.0

- **Schema Introspection CLI (`dart run mk_graphql_generator:introspect`)**: Built-in CLI command to introspect remote GraphQL endpoints via HTTP into clean, standard GraphQL SDL (`.graphql` or `.gql`).
- **Automatic `build.yaml` Path Resolution**: When `--output` / `-o` is omitted, the introspection CLI automatically detects and uses the configured `schema_path` from `build.yaml`.
- **AST-Based GraphQL Formatter (`GraphQLFormatter`)**: Added `formatGraphQL` and `formatGraphQLString` adhering strictly to GraphQL specifications and Prettier formatting rules (indented multiline arguments, clean descriptions, enums, interfaces, unions, directives, and operations).
- **`ErrorPolicy` Code Generation**: Request classes, copy constructors, and typed client extensions now include `ErrorPolicy? errorPolicy`.
- **Dart Reserved Keyword Mapping**: Automatically sanitizes field names colliding with Dart reserved keywords to `g{Keyword}` with `@JsonKey(name: raw)`.
- **Directives & Default Values**: Handles `@include` and `@skip` directives in response models, making fields nullable, and emits `@Default(...)` in variables for arguments with default values.

## 1.0.1


- **Breaking (generated output): response models are now always generated per-operation**, scoped to exactly the fields a query/mutation selected, instead of ever reusing a shared schema-wide `{Type}Model` for responses. Two operations selecting different fields of the same GraphQL type now reliably get correctly-shaped, independently-named classes (e.g. `GetUserModel`/`GetUserProfileModel`) rather than risking one operation's selection silently missing a field the shared model required.
- **Fragments are now the sanctioned way to share a response model** across operations: a selection that is nothing but a named fragment spread (`{ ...UserFields }`) reuses one generated `{Fragment}Fragment` class everywhere it's spread; mixing a spread with extra fields flattens everything into that operation's own scoped model instead of silently dropping fields.
- Fixed: generated `Vars` and input-object `toJson()` now omit unset optional fields instead of sending them as explicit `"field": null`. Some GraphQL servers treat an explicit null differently from an omitted argument (e.g. a `filter: null` that resolves to zero results where an omitted `filter` returns everything) — this could previously break pagination/filtering silently.
- Removed the unused legacy `OperationGenerator` class — it was never wired into the builder; `GeneratorOrchestrator` has been the actual code path since 1.0.0.
- Repository moved into the unified `mk_graphql` monorepo alongside `mk_graphql`; `build.yaml` configuration is unchanged.

## 1.0.0

- Initial release of `mk_graphql_generator`.
- **High-Performance Code Generation**:
  - Automatically generates immutable Freezed data models, variables, requests, and barrel files from `.graphql` and `.gql` SDL documents.
  - Generates type-safe client extension methods on `GraphQLClient` (`client.myQuery(...)` and `client.myQueryStream(...)`).
  - Strict typing for `CancelToken? cancelToken` across all generated requests and client extension methods.
  - Seamless handling of GraphQL `Upload` scalar mapped directly to `MultipartFile`.
- **Builder Options & Customization**:
  - `schema_path`: Explicit configuration of schema SDL path.
  - `shared_dir`: Configurable output destination for shared enums, inputs, models, and schema barrel files.
  - `cache`: Optional toggle for generation caching.
- **Ultra-Fast Two-Tier Generation Caching**:
  - Deterministic SHA-256 fingerprinting avoiding redundant code generation and Dart formatting.
  - Memory LRU map + persistent disk cache in `.dart_tool/mk_graphql_cache/`.
  - Microsecond-level `computeOutputPaths()` during builder initialization eliminating startup latency.
