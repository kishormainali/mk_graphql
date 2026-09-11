# Generator Configuration

Configure the builder via `build.yaml` at your project root:

```yaml
targets:
  $default:
    builders:
      mk_graphql_generator:
        options:
          schema_path: lib/api/schema.graphql
          shared_dir: lib/shared/generated
          cache: true
```

All options are optional.

## `schema_path`

Path (relative to the package root) to the GraphQL schema SDL file.

- **Default**: the generator scans `lib/` recursively for the first file literally named `schema.graphql` or `schema.gql`.
- Set this explicitly if your schema file doesn't live at the default location, or if you have multiple `.graphql` files and want to be unambiguous about which one is the schema.
- Accepts either key spelling: `schema_path` or `schemaPath`.

## `shared_dir`

Directory (relative to the project) where schema-wide artifacts are written: `enums/`, `inputs/`, `models/`, and the schema barrel file (`{schemaFileName}.gql.dart`, containing schema-driven `Req`/`Vars` classes and the `SchemaGraphQLClientExtension`).

- **Default**: a `generated/` folder next to the schema file (i.e. `dirname(schema_path)/generated`).
- Accepted key spellings: `shared_dir`, `sharedDir`, `shared_path`, `sharedPath`.
- Per-operation output (`{opDir}_var.dart`, `{opDir}_model.dart`, `{opDir}_req.dart`) always stays next to the `.graphql` file that defines the operation, under its own `generated/{operationName}/` folder — `shared_dir` only affects the schema-wide artifacts.

## `cache`

- **Default**: `true`.
- The generator keeps a two-tier (in-memory + on-disk) cache keyed by input content, schema content, `shared_dir`, and `packageName`, so `build_runner watch` avoids re-generating files whose relevant inputs haven't changed.
- Set to `false` to always regenerate from scratch — useful when debugging the generator itself, or if you suspect a stale cache (though correctness bugs here should be reported, not worked around).

See [Architecture](architecture.md#caching) for how the cache key is computed.
