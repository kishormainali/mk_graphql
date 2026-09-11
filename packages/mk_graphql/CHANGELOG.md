## 1.0.1

- **Pagination**: added `GraphQLPaginator` with `offset`/`page`/`cursor` factories, a reactive `PaginationState` (`items`, `isLoading`, `isLoadingMore`, `hasMore`, `error`), and `GraphQLClient`/`GraphQLRequest` extension methods (`paginate`, `paginateOffset`, `paginatePage`, `paginateCursor`) for building infinite lists without hand-rolled pagination state.
- Added an optional `requestId` override on `GraphQLRequest`, enabling cross-instance optimistic-response coalescing (used internally by `CompositeGraphQLRequest`).
- Repository moved into the unified `mk_graphql` monorepo alongside `mk_graphql_generator`; no API changes from the move itself.

## 1.0.0

- Initial release of `mk_graphql`.
- **Composable Link Architecture**:
  - `AuthLink` with automatic 401 interception, thread-safe asynchronous token refresh queuing, and token revocation hooks.
  - `DioLink` powered by Dio with full cancellation support (`CancelToken`), automatic GraphQL Multipart Request spec uploads (`Upload` scalar / `MultipartFile`), and HTTP interceptors.
  - `SseLink` for Server-Sent Events (SSE) subscriptions with dynamic token header injection and 401 retry support.
  - `WebSocketLink` for GraphQL over WebSockets (`graphql-ws` and legacy protocol).
  - `HttpLink` for lightweight HTTP operations.
  - `BatchLink` for batching multiple GraphQL requests into a single HTTP payload.
  - `TypenameLink` for automatic `__typename` injection into AST selection sets.
  - `LoggerLink` for structured console logging with customizable options.
- **Client & Caching**:
  - `GraphQLClient` supporting both Future (`future()`) and Stream (`stream()`) operations.
  - Pluggable cache interface with built-in normalized `InMemoryCache`.
  - Configurable fetch policies (`cacheFirst`, `cacheOnly`, `networkOnly`, `cacheAndNetwork`, `noCache`).
  - Optimistic response support.
- Fully typed responses and exceptions (`GraphQLResponse`, `GraphQLException`, `UnAuthorizedException`, `RequestCancelledException`).
