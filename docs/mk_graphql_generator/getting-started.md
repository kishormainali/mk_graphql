# mk_graphql_generator — Getting Started

`mk_graphql_generator` is a `build_runner` builder that turns a GraphQL schema and your `.graphql`/`.gql` operation files into typed Dart: `@freezed` variables, response models, `GraphQLRequest` subclasses, and `GraphQLClient` extension methods, all consumable by [`mk_graphql`](../mk_graphql/getting-started.md).

---

## Step 1: Install Dependencies

Add runtime dependencies and builder dev dependencies to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  mk_graphql: ^1.0.1
  freezed_annotation: ^3.1.0
  json_annotation: ^4.12.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  mk_graphql_generator: ^1.0.1
  build_runner: ^2.16.0
  freezed: ^4.0.1
  json_serializable: ^6.14.1
```

Run:
```bash
flutter pub get
```

---

## Step 2: Add a Schema File

Place your GraphQL schema anywhere under `lib/` named `schema.graphql` (or point `schema_path` in `build.yaml` to a custom location — see [Configuration](configuration.md)):

```graphql
# lib/graphql/schema.graphql
type Query {
  user(id: ID!): User
  countries(filter: CountryFilterInput): [Country!]!
}

type User {
  id: ID!
  name: String!
  email: String!
  avatarUrl: String
}

input CountryFilterInput {
  code: StringQueryOperatorInput
}

input StringQueryOperatorInput {
  eq: String
}

type Country {
  code: ID!
  name: String!
  capital: String
  emoji: String!
}
```

The schema file is the single source of truth for object types, enums, inputs, and custom scalars — the generator reads it to enforce non-nullability and resolve accurate types.

---

## Step 3: Write Operations

Create any other `.graphql` or `.gql` file under `lib/` with your operations:

```graphql
# lib/features/user/get_user.graphql
query GetUser($id: ID!) {
  user(id: $id) {
    id
    name
  }
}
```

```graphql
# lib/features/countries/get_countries.graphql
query GetCountries($filter: CountryFilterInput) {
  countries(filter: $filter) {
    code
    name
    capital
    emoji
  }
}
```

---

## Step 4: Run the Generator

Execute `build_runner`:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Or watch for changes during development:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

### Generated File Structure

Generated files are placed neatly alongside your schema and operations (see [Generated Output](generated-output.md)):

```
lib/graphql/
├── schema.graphql
└── generated/
    ├── enums/                # Generated enum types with @JsonValue
    ├── inputs/               # Generated input models with @freezed
    ├── models/               # Shared {Type}Model classes from the schema
    ├── schema.gql.dart       # Barrel file + schema-driven client extensions
lib/features/
├── user/
│   ├── get_user.graphql
│   └── generated/
│       ├── get_user/
│       │   ├── get_user_var.dart
│       │   ├── get_user_model.dart
│       │   ├── get_user_req.dart
│       │   └── get_user.dart
│       └── get_user.gql.dart
```

---

## Step 5: Use the Generated Code

You have two equivalent ways to call an operation:

```dart
import 'package:mk_graphql/mk_graphql.dart';
import 'package:my_app/features/user/generated/get_user.gql.dart';

final client = GraphQLClient(url: 'https://api.example.com/graphql');

// A. Using generated GraphQLClientExtension method (less boilerplate):
final user = await client.getUser(id: '123');

// B. Using generated request class directly:
final req = GetUserReq(variables: const GetUserVars(id: '123'));
final user2 = await client.future(req);
```

Every operation also gets streaming and refetching extension methods:
- `client.getUser(...)`
- `client.getUserStream(...)`
- `client.refetchGetUser(...)`

---

## Key Generator Features

### Partial Models (`{Type}PartialModel`)
When a query selects only a partial subset of fields, the generator produces an operation-scoped partial model named `{Type}PartialModel` (e.g. `CountryPartialModel`). If the query requests all required fields, it reuses the shared schema model `{Type}Model`.

### Dart Reserved Keywords (`g{Keyword}`)
Any field or variable matching a Dart reserved keyword (`default`, `class`, `is`, `native`, `switch`, etc.) is automatically safely prefixed with `g`:
```dart
@JsonKey(name: 'default') final bool? gDefault;
```

### Conditional Directives (`@include` & `@skip`)
Fields using `@include` or `@skip` are generated as nullable in response models, preventing deserialization errors when fields are conditionally skipped by the server.

### Variable Defaults (`@Default(...)`)
Operation variable definitions with defaults (e.g. `$limit: Int = 20`) automatically emit `@Default(20)` on Freezed `Vars` classes and default parameter values on client extension methods.

---

## Next

- [Configuration](configuration.md) — `build.yaml` options: custom schema path, shared output directory, custom scalars, caching.
- [Generated Output & Model Sharing](generated-output.md) — the full file layout and model-sharing rules.
- [Architecture](architecture.md) — for contributors working on the generator itself.
