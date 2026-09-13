## 1.2.0

- **Breaking**: `OnRefreshCallback` (used by `onTokenRefresh` on `GraphQLClient`, `AuthLink`, and `SseLink`) now receives a plain `GraphQLClient` (no auth link attached) instead of a raw `DioLink`, so refresh logic can use the typed client API (`refreshClient.future(...)`, `.stream(...)`) instead of hand-rolling a raw HTTP request.

## 1.1.0

- **Dynamic Pagination Variables**: Added `applyVariables()` and `updateVariables()` to `GraphQLPaginator` to dynamically update active variables (e.g. search queries, genre/status filters, sorting) on page 1 without recreating the paginator or wiping other active filter criteria.
- **Refetch & Pagination Reset Lifecycle**: `refetch()` resets `_baseRequest = initialRequest`, restoring page 1 and clearing active filters/search to defaults, while `loadNext()` persists and accumulates items across pages.
- **Fine-Grained Page Tracking**: Added optional `getPage` and `hasNextPage` callbacks to `GraphQLPaginator.page(...)` to allow authoritative backend pagination metadata (such as `PageInfo.hasNextPage`) to govern whether subsequent pages exist.
- **`ErrorPolicy` Support**: Added `ErrorPolicy.none`, `ErrorPolicy.ignore`, and `ErrorPolicy.all` across requests, client executions, copy constructors, and client defaults.
- **Performance & Cache Optimization**: Added deterministic canonical JSON variable cache key sorting and Document AST caching.
- **Documentation**: Updated comprehensive guides for client requests, caching, links, and Flutter BLoC `emit.forEach` pagination patterns.

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
