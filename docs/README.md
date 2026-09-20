# mk_graphql Documentation

This repository is a monorepo with two published packages:

| Package | What it is | Docs |
|---|---|---|
| [`mk_graphql`](../packages/mk_graphql) | The runtime GraphQL client: link pipeline, normalized cache, fetch policies, pagination, error mapping. | [docs/mk_graphql](mk_graphql/getting-started.md) |
| [`mk_graphql_generator`](../packages/mk_graphql_generator) | The `build_runner` code generator that turns `.graphql`/`.gql` files into typed Freezed requests, variables, and response models for `mk_graphql`. | [docs/mk_graphql_generator](mk_graphql_generator/getting-started.md) |

## Where to start

- New to the project? Read [mk_graphql: Getting Started](mk_graphql/getting-started.md), then [mk_graphql_generator: Getting Started](mk_graphql_generator/getting-started.md) — the generator produces the code the client consumes.
- Already generating code and want to understand *why* a particular model shape was produced? See [Generated Output & Model Sharing](mk_graphql_generator/generated-output.md).
- Configuring `build.yaml`? See [Generator Configuration](mk_graphql_generator/configuration.md).
- Working on the generator itself? See [Generator Architecture](mk_graphql_generator/architecture.md).

## mk_graphql (client)

- [Getting Started](mk_graphql/getting-started.md) — step-by-step integration: installing, configuring `GraphQLClient`, executing operations, and handling validation errors.
- [Client, Requests & Responses](mk_graphql/client-and-requests.md) — `GraphQLClient` API, `FetchPolicy`, `ErrorPolicy`, `GraphQLRequest`, `GraphQLResponse`, and `ValidationException`.
- [Authentication & Token Storage](mk_graphql/authentication.md) — `TokenPair`, `TokenStorage.i`, silent token refresh, login/logout/revoke listeners, and how `GraphQLClient` manages the session.
- [Link Pipeline](mk_graphql/links.md) — how `AuthLink`, `TypenameLink`, `LoggerLink`, and transport links (`DioLink`, `HttpLink`, `SseLink`, `WebSocketLink`, `BatchLink`) compose.
- [Caching](mk_graphql/caching.md) — normalized in-memory cache, deterministic canonical key sorting, optimistic responses, `watchQuery`.
- [Pagination](mk_graphql/pagination.md) — automatic list and Relay connection merging with `client.fetchMore` / `req.fetchMore`, and reactive `GraphQLPaginator`.

## mk_graphql_generator (codegen)

- [Getting Started](mk_graphql_generator/getting-started.md) — schema + operation files, running `build_runner`, using generated code.
- [Configuration](mk_graphql_generator/configuration.md) — `build.yaml` options (`schema_path`, `shared_dir`, `cache`).
- [Generated Output & Model Sharing](mk_graphql_generator/generated-output.md) — file layout per operation, and the rules that decide when a response type reuses a shared schema model versus generating an operation-scoped one.
- [Architecture](mk_graphql_generator/architecture.md) — internal pipeline: parser → schema generator → orchestrator → cache, for contributors.
