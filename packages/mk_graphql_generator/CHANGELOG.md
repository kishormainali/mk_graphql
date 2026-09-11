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
