# Generated Output & Model Sharing

## File layout

For a schema at `lib/graphql/schema.graphql` and operations in `lib/graphql/operations.graphql`:

```
lib/graphql/
├── schema.graphql
├── operations.graphql
└── generated/
    ├── enums/
    │   └── enums.dart              # every schema enum, in one file
    ├── inputs/
    │   └── inputs.dart             # every schema input type, in one file
    ├── models/
    │   └── models.dart             # every schema object type (Query/Mutation/Subscription excluded), in one file
    ├── fragments/
    │   └── fragments.dart          # one class per named GraphQL fragment actually spread, if any
    ├── schema.gql.dart             # schema barrel: exports enums/inputs/models + SchemaGraphQLClientExtension
    ├── get_user/
    │   ├── get_user_var.dart       # GetUserVars
    │   ├── get_user_model.dart     # GetUserModel + any nested selection classes it needed
    │   ├── get_user_req.dart       # GetUserReq
    │   └── get_user.dart           # barrel exporting the three above
    ├── update_user_name/
    │   └── ...                     # same shape, one folder per operation
    └── operations.gql.dart         # barrel: exports every operation folder + OperationsGraphQLClientExtension
```

Every `.graphql`/`.gql` operations file gets its own `generated/{fileName}.gql.dart` barrel and `generated/{operationName}/` folders; the schema file gets the schema-wide `enums/enums.dart`, `inputs/inputs.dart`, `models/models.dart`, and `fragments/fragments.dart` output (location controlled by [`shared_dir`](configuration.md#shared_dir)). Each of `enums.dart`/`inputs.dart`/`models.dart` holds every type in its category, not one file per type — this keeps the generator's declared build outputs for the schema file fixed regardless of how many types the schema defines, which matters for `dart run build_runner watch`: growing an already-populated category (adding a type to a schema that already has other enums/inputs/objects) no longer requires restarting `watch`. A category's *first* type appearing while `watch` is already running still does. The same caveat applies to operation (`.graphql` query/mutation) files: adding a new operation to an existing file, or creating a brand-new `.graphql` file, while `watch` is running also isn't picked up without a restart.

## Subscriptions

A `subscription` operation (from a `.graphql` file, or a field of the schema's `Subscription` type) generates the same `Req`/`Vars`/model classes as a query, but its client extension has a single `Stream<Model> name({...})` method — no `Future` form, no `refetch`. Pass `wsUrl`/`sseUrl` to `GraphQLClient` to use it; see [authentication](../mk_graphql/authentication.md#subscriptions).

## Schema-driven operations

Beyond whatever you write in `.graphql` operation files, **every field on `Query` and `Mutation` in the schema** gets a generated `{Field}Req`/`{Field}Vars` pair and three `GraphQLClient` extension methods (`client.{field}(...)`, `client.{field}Stream(...)`, `client.refetch{Field}(...)`) in `schema.gql.dart`, using the field's full return type (`{ReturnType}Model` from `models/`) with no field-level trimming. This is a convenience for ad-hoc calls; anything you actually hand-write a `.graphql` operation for gets the trimmed, operation-scoped model described below instead.

## Response models are generated per operation

This is the important part to understand before you go looking for a `UserModel` class: **response models are never the shared, schema-wide `{Type}Model`.** Two operations that select different fields of the same GraphQL type inevitably have different requiredness/shape needs — one might select every required field, another might deliberately omit one — and a single shared class can't safely represent both (`fromJson` would either wrongly require a field one query never asked for, or wrongly allow null on a field the schema declares non-null for the other). So the generator always builds a class scoped to exactly the fields a given selection set asked for.

### Naming

A response class is named by its **path from the operation root**, not by the underlying GraphQL type. For:

```graphql
query GetCountryDetails($code: ID!) {
  country(code: $code) {
    code
    name
    continent {
      code
      name
    }
  }
}
```

the generator produces:

- `GetCountryDetailsModel` — the operation root (always generated, one per operation).
- `GetCountryDetailsCountryModel` — for the `country` selection.
- `GetCountryDetailsCountryContinentModel` — for the nested `continent` selection.

This guarantees no naming collision between operations, even when two operations select the exact same fields of the exact same type — each gets its own class. (The tradeoff: two operations with identical selections generate duplicate, but harmless, classes rather than one shared one — see [Fragments](#fragments-are-the-sanctioned-sharing-mechanism) for how to opt into sharing deliberately.)

### Requiredness comes from the schema, always

Even though the model is trimmed to selected fields, each field's `required` vs nullable annotation in the generated Dart class still reflects the **schema's** nullability for that field — not whether every sibling required field happens to be selected. Selecting `id name` from a `User` where `email` is non-null in the schema but not selected simply omits `email` from the generated class entirely; it does not make the generated class more permissive than the schema, nor does it require a field you didn't ask for.

### Fragments are the sanctioned sharing mechanism

If you deliberately want two operations to share one response class, spread a **named fragment**:

```graphql
fragment UserFields on User {
  id
  name
}

query GetUser($id: ID!) {
  user(id: $id) { ...UserFields }
}

query GetViewer {
  viewer { ...UserFields }
}
```

Both operations get a `user`/`viewer` field typed as the single shared `UserFieldsFragment` class (in `generated/fragments/fragments.dart`), generated once regardless of how many operations spread it. This only applies when the fragment spread is the *entire* selection set (`{ ...UserFields }`); mixing a spread with extra fields (`{ ...UserFields email }`) flattens everything (the fragment's fields plus the extra ones, with a directly-selected field winning over one contributed by the spread) into that operation's own scoped class instead of the fragment's — mixing selections should never silently lose or hide fields.

Fragment spreads are resolved transitively (a fragment spreading another fragment), and the wire document for a request automatically includes the text of every fragment it (transitively) spreads, so the server always receives valid, self-contained document text.

### What `models/models.dart` is for

The schema-wide `{Type}Model` classes are still generated — one per non-root object type in the schema, all declared together in `models/models.dart` — because [schema-driven operations](#schema-driven-operations) and any code you write by hand need a way to reference "the full shape of a `User`". They are simply never used to deserialize a hand-written operation's trimmed response.

## Enums

Every schema enum becomes a `@JsonEnum()` Dart enum in `enums/enums.dart`. Constants are camelCase Dart identifiers with `@JsonValue` preserving the wire name, and each enum gets two helpers for converting to and from the wire value:

```dart
@JsonEnum()
enum UserRole {
  @JsonValue("ADMIN_USER")
  adminUser,
  @JsonValue("STANDARD_USER")
  standardUser;

  String get value => switch (this) {
    UserRole.adminUser => 'ADMIN_USER',
    UserRole.standardUser => 'STANDARD_USER',
  };

  static UserRole? fromString(String? value) => switch (value) {
    'ADMIN_USER' => UserRole.adminUser,
    'STANDARD_USER' => UserRole.standardUser,
    _ => null,
  };
}
```

- `role.value` is the wire string (`'ADMIN_USER'`); `toString()`/`name` are Dart's defaults (`UserRole.adminUser`/`adminUser`).
- `UserRole.fromString(...)` matches the **wire** value and returns `null` for `null` or an unknown value (e.g. a value the server added after you generated), so `fromString(role.value) == role`.
- A schema value that would clash with these members (`value`, `fromString`) is escaped with a `g` prefix — `gValue`, `gFromString` — like Dart keywords.
