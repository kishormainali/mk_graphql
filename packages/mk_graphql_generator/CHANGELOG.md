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
