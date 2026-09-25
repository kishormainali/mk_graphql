## Unreleased

- **Fix**: growing a schema (adding an `enum`/`input`/`type`) while `dart run build_runner watch` is already running could leave `generated/models/models.dart` and `generated/inputs/inputs.dart` missing export entries for types that genuinely exist on disk, breaking `json_serializable`'s type resolution for anything importing those barrels. Root cause: `buildExtensions` (which files build_runner will let the builder write) is computed once when the builder starts, by predicting one output file per schema type; a schema growing mid-`watch` produces a new per-type file build_runner never declared, aborting that build before the barrel got rewritten.
- **Breaking**: fixed by merging the schema-level per-type files into three fixed files — `enums/{type}_enum.dart` → `enums/enums.dart`, `inputs/{type}.dart` → `inputs/inputs.dart`, `models/{type}_model.dart` → `models/models.dart` — so the schema file's declared output set no longer depends on how many types it defines. Regenerate (`dart run build_runner build --delete-conflicting-outputs`) to pick this up; the generator's on-disk cache is automatically invalidated (`GeneratorCache` bumped to v16). Any app importing one of the old per-type file paths directly (rather than the barrel, which is what the README/docs have always shown) needs to switch to importing the barrel instead — e.g. `import 'generated/models/user_model.dart'` becomes `import 'generated/models/models.dart'`.
- **Known limitation, unchanged by this fix**: a schema's *first-ever* enum, input, or object type appearing while `watch` is already running still requires a restart — that category's file existence (not just its size) is still content-dependent. Adding a type to a category the schema already has does not.

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
