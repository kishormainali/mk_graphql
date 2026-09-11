# mk_graphql_generator — Getting Started

`mk_graphql_generator` is a `build_runner` builder that turns a GraphQL schema and your `.graphql`/`.gql` operation files into typed Dart: `@freezed` variables, response models, `GraphQLRequest` subclasses, and `GraphQLClient` extension methods, all consumable by [`mk_graphql`](../mk_graphql/getting-started.md).

## Install

```yaml
dependencies:
  mk_graphql: ^1.0.0
  freezed_annotation: ^3.1.0
  json_annotation: ^4.12.0

dev_dependencies:
  mk_graphql_generator: ^1.0.0
  build_runner: ^2.16.0
  freezed: ^4.0.1
  json_serializable: ^6.14.1
```

## 1. Add a schema file

Anywhere under `lib/`, name a file `schema.graphql` (or point `schema_path` at a different location — see [Configuration](configuration.md)):

```graphql
# lib/graphql/schema.graphql
type Query {
  user(id: ID!): User
}

type User {
  id: ID!
  name: String!
  email: String!
  avatarUrl: String
}
```

The schema file is the source of truth for object types, enums, inputs, and scalars — the generator reads it to know which fields are required, and to resolve field types by name instead of guessing.

## 2. Write operations

Any other `.graphql`/`.gql` file under `lib/` is treated as an operations file:

```graphql
# lib/graphql/operations.graphql
query GetUser($id: ID!) {
  user(id: $id) {
    id
    name
  }
}

mutation UpdateUserName($id: ID!, $name: String!) {
  updateUser(id: $id, name: $name) {
    id
    name
  }
}
```

## 3. Run the generator

```bash
dart run build_runner build --delete-conflicting-outputs
```

or, while iterating:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

This produces, next to `schema.graphql` (see [Generated Output](generated-output.md) for the full layout):

```
lib/graphql/
├── schema.graphql
├── operations.graphql
└── generated/
    ├── enums/
    ├── inputs/
    ├── models/               # shared {Type}Model classes from the schema
    ├── schema.gql.dart       # enum/input/model barrel + schema-driven client extension
    └── get_user/
        ├── get_user_var.dart
        ├── get_user_model.dart
        ├── get_user_req.dart
        └── get_user.dart
    └── operations.gql.dart   # barrel + GraphQLClientExtension for this file's operations
```

## 4. Use the generated code

Two equivalent ways to call an operation:

```dart
import 'package:mk_graphql/mk_graphql.dart';
import 'package:my_app/graphql/generated/operations.gql.dart';

final client = GraphQLClient(url: 'https://api.example.com/graphql');

// A. Using the generated request class directly.
final user = await client.future(
  GetUserReq(variables: const GetUserVars(id: '123')),
);

// B. Using the generated GraphQLClientExtension method (same request, less boilerplate).
final user2 = await client.getUser(id: '123');
```

Both `future`/`stream`/`refetch` variants exist for extension methods too: `client.getUser(...)`, `client.getUserStream(...)`, `client.refetchGetUser(...)`.

Schema fields (i.e. every field on `Query`/`Mutation`, whether or not you wrote a matching `.graphql` operation for it) also get their own generated `{Field}Req`/`{Field}Vars` and client extension methods in `schema.gql.dart` — see [Generated Output](generated-output.md#schema-driven-operations).

## Next

- [Configuration](configuration.md) — `build.yaml` options: custom schema path, shared output directory, disabling the cache.
- [Generated Output & Model Sharing](generated-output.md) — the full file layout, and exactly when a response type is shared vs. generated per-operation.
- [Architecture](architecture.md) — for contributors working on the generator itself.
