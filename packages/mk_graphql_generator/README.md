# mk_graphql_generator

[![pub package](https://img.shields.io/pub/v/mk_graphql_generator.svg)](https://pub.dev/packages/mk_graphql_generator)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An ultra-fast, intelligent `build_runner` code generator for [`mk_graphql`](https://pub.dev/packages/mk_graphql). Generates immutable Freezed models, typed operation requests, and convenient `GraphQLClient` extension methods directly from `.graphql` and `.gql` files.

📖 **[Full documentation](../../docs/README.md)** — getting started, `build.yaml` configuration, generated file layout, and model-sharing rules.

---

## ✨ Features

- ⚡ **Lightning-Fast Generation**: Two-tier caching (memory + disk) with microsecond output path computation so `build_runner` never hangs.
- ❄️ **Modern Freezed Models**: Generates `@freezed` models and `@JsonSerializable` classes for all operations, inputs, and schema models.
- 🎯 **Direct GraphQLClient Extensions**: Generates typed methods on `GraphQLClient` (e.g. `client.getUser(...)`, `client.getUserStream(...)`, and `client.refetchGetUser(...)`).
- 🧩 **Shared vs. Partial Models**: Schema models (`{Type}Model`) are strictly non-nullable; queries selecting partial fields generate operation-scoped `{Type}PartialModel` classes.
- 🔤 **Dart Reserved Keyword Mapping**: Automatically renames reserved keywords (e.g. `default`, `class`, `is`, `native`, `switch`) to `g{Keyword}` with exact wire `@JsonKey(name: raw)`.
- 🎛️ **Conditional Directives**: Supports `@include` and `@skip` by generating conditional fields as nullable in response models.
- 🛑 **Dio CancelToken Support**: Generated requests and client extensions natively accept `CancelToken? cancelToken`.
- 📁 **GraphQL Multipart Uploads**: Built-in mapping of `Upload` scalar to `MultipartFile`.
- ⚙️ **Custom Scalars & Path Config**: Simple `build.yaml` mapping for custom types and output directories.
- 🔍 **Schema Introspection CLI**: Built-in CLI command to introspect any GraphQL endpoint via HTTP and emit clean standard GraphQL SDL (`.graphql` or `.gql`).

---

## 🔍 Schema Introspection CLI

Generate your `schema.graphql` directly from a live GraphQL API with a single command:

```bash
# Automatically detects schema_path from build.yaml:
dart run mk_graphql_generator:introspect --url https://graphql.anilist.co

# Or specify custom options:
dart run mk_graphql_generator:introspect \
  --url https://graphql.anilist.co \
  --header "Referer: https://anilist.co/graphiql"
```

### CLI Options:
| Flag | Description | Default |
|---|---|---|
| `-u, --url` | Target GraphQL HTTP endpoint (**required**) | — |
| `-o, --output` | Destination path for SDL output | Automatically resolved from `build.yaml` (`schema_path`) |
| `-c, --build-yaml` | Path to `build.yaml` configuration file | `build.yaml` |
| `-H, --header` | Custom HTTP headers (`"Name: Value"`), can be repeated | — |
| `-h, --help` | Show usage help | — |

The CLI executes a standard full GraphQL introspection query, parses the schema types, inputs, enums, unions, interfaces, and directives, and outputs clean, valid GraphQL SDL. If `--output` is omitted, it automatically reads your `build.yaml` to detect your configured `schema_path`.


---

## 📦 Installation

Add `mk_graphql` to your `dependencies`, and `mk_graphql_generator` along with code-generation tools to your `dev_dependencies`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  mk_graphql: ^1.2.2
  freezed_annotation: ^3.1.0
  json_annotation: ^4.12.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  mk_graphql_generator: ^1.2.2
  build_runner: ^2.16.0
  freezed: ^4.0.1
  json_serializable: ^6.14.1
```

---

## 🚀 Step-by-Step Integration

### 1. Place Your Schema

Place your GraphQL schema file under `lib/` (e.g. `lib/graphql/schema.graphql`):

```graphql
# lib/graphql/schema.graphql
type Query {
  user(id: ID!): User
  countries(filter: CountryFilterInput): [Country!]!
}

type Mutation {
  updateUser(id: ID!, name: String!): User!
}

type User {
  id: ID!
  name: String!
  email: String!
  avatar: String
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

---

### 2. Write Operation Files

Write your queries, mutations, or subscriptions in `.graphql` or `.gql` files anywhere under `lib/`:

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

```graphql
# lib/features/user/get_user.graphql
query GetUser($id: ID!) {
  user(id: $id) {
    id
    name
  }
}
```

---

### 3. Configure `build.yaml` (Optional)

Create a `build.yaml` file in your project root to customize options:

```yaml
targets:
  $default:
    builders:
      mk_graphql_generator:mk_graphql_builder:
        options:
          # Path to schema (defaults to auto-detecting schema.graphql under lib/)
          schema_path: lib/graphql/schema.graphql
          
          # Directory for shared models, inputs, and enums (default: lib/shared/generated)
          shared_dir: lib/shared/generated
          
          # Enable disk + memory generation caching (default: true)
          cache: true
          
          # Map custom scalars to Dart types
          scalars:
            DateTime: DateTime
            UUID: String
            Upload: MultipartFile
```

---

### 4. Run Code Generation

Execute `build_runner`:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Or watch for continuous compilation while you code:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

---

### 5. Use the Generated Code

The generator creates:
1. Typed variables (`GetCountriesVars`)
2. Typed response models (`GetCountriesModel`)
3. Request classes (`GetCountriesReq`)
4. Direct `GraphQLClient` extension methods (`client.getCountries(...)`, `client.getCountriesStream(...)`, `client.refetchGetCountries(...)`)

#### Example: Calling Operations

```dart
import 'package:mk_graphql/mk_graphql.dart';
import 'package:my_app/features/countries/generated/get_countries.gql.dart';

final client = GraphQLClient(url: 'https://api.example.com/graphql');

// Option A: Direct client extension method
final data = await client.getCountries(
  filter: const CountryFilterInput(
    code: StringQueryOperatorInput(eq: 'NP'),
  ),
);

// Option B: Typed request object
final req = GetCountriesReq(
  variables: const GetCountriesVars(
    filter: CountryFilterInput(
      code: StringQueryOperatorInput(eq: 'NP'),
    ),
  ),
);

final data2 = await client.future(req);
```

---

## 🧩 Advanced Codegen Features

### Partial Models (`{Type}PartialModel`)
When a query selects only a partial subset of fields from a schema type, `mk_graphql_generator` generates an operation-scoped partial model named `{Type}PartialModel` (e.g. `CountryPartialModel`). If the query requests all required fields, it uses the shared schema model `{Type}Model`.

### Reserved Keywords (`g{Keyword}`)
GraphQL fields or arguments that match Dart reserved keywords (such as `default`, `class`, `is`, `native`, `switch`) are safely transformed to `g{Keyword}` in Dart with `@JsonKey(name: 'raw_name')`, avoiding syntax conflicts:
```dart
@JsonKey(name: 'default') final bool? gDefault;
```

### Conditional Directives (`@include` / `@skip`)
Fields marked with `@include(if: $flag)` or `@skip(if: $flag)` are generated as nullable (`FieldType?`) in response models even if non-null in the GraphQL schema, preventing runtime deserialization crashes when the server omits them.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
