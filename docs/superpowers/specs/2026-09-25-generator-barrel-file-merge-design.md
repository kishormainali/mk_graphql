# Generator: Merge Schema-Level Barrel Files — Design

Status: approved by user 2026-09-25. Ready for implementation planning.

## Goal

Fix a real bug reported against `mk_graphql_generator`: growing a GraphQL schema
(adding an `enum`/`input`/`type`) while `dart run build_runner watch` is already
running can leave `generated/models/models.dart` and `generated/inputs/inputs.dart`
missing export entries for types that genuinely exist on disk, breaking
`json_serializable`'s type resolution for anything importing those barrels.

The fix makes the *set* of files `mk_graphql_generator` declares as outputs for the
schema file stop depending on how many types the schema defines, by merging the
current one-file-per-type layout into three fixed, always-in-the-same-place files.

## Root cause (for context — already diagnosed and reproduced, not re-litigated here)

`MkGraphQLBuilder`'s `buildExtensions` (`packages/mk_graphql_generator/lib/builder.dart`)
is computed once, synchronously, when the builder is constructed — a hard requirement
of `package:build`'s `Builder` contract ("An instance of a builder must always return
the same configuration... for the lifetime of this Builder"). It's built by scanning
`schema.graphql`'s *current* content via `GeneratorOrchestrator.computeOutputPaths`,
which predicts one output file per enum/input/object type the schema defines *at that
moment*.

`dart run build_runner watch` constructs the builder once and keeps it alive for the
whole session. If the schema gains a new type while `watch` is running, the next
`build()` call tries to write that new type's file — an output `buildExtensions` never
declared — which `package:build` rejects with `InvalidOutputException`, aborting the
rest of that `build()` call. Because `SchemaGenerator.generateObjectTypes` (and
`generateInputs`) always write their barrel file (`models/models.dart`,
`inputs/inputs.dart`) *last*, after every per-type file, the abort happens *before* the
barrel is rewritten — leaving it on disk holding its old, now-incomplete export list.
Confirmed via a throwaway reproduction: a schema gaining one object type produces a
real `bundle.files` entry for that type's model file that is absent from the
declared-at-`watch`-start output set, and the barrel is later in write order than that
undeclared file.

This has been present, unchanged, since the `builder.dart`/`computeOutputPaths`
mechanism shipped in `1.1.0` — it is not something introduced by any `1.2.1-dev.*`
prerelease.

## Non-goals

- **Not a complete fix for every staleness case.** A schema's *first-ever* enum, input,
  or object type appearing while `watch` is already running still needs a restart —
  that one category file's existence (not just its size) is still content-dependent.
  This spec removes the dominant, realistic trigger (adding a type to an already-populated
  category), not the rarer 0→1 transition. This is documented, not silently assumed away.
- **Not changing anything about operation-level (`.graphql` query/mutation file) output.**
  Those already use a fixed, predictable file set per operation
  (`{op}_var.dart`/`{op}_model.dart`/`{op}_req.dart`/`{op}.dart`) unrelated to schema
  type count — no bug there, no changes here.
- **Not a `buildExtensions`/`builder.dart` redesign.** The builder's snapshot-once
  mechanism is an unavoidable constraint of `package:build`'s `Builder` API, not
  something to work around structurally beyond what this spec does.
- **Not restructuring `generateEnums`/`generateInputs`/`generateObjectTypes`'s
  public signatures** beyond what merging requires — callers in
  `generator_orchestrator.dart` keep calling them the same way.

## Design

### 1. Merge per-type files into three fixed category files

`SchemaGenerator.generateEnums`, `.generateInputs`, and `.generateObjectTypes`
(`packages/mk_graphql_generator/lib/src/generator/schema/schema_generator.dart`)
currently loop over their type list, writing one file per type into `result`, then
append one barrel file of `export '...';` lines. They change to loop over the type
list writing every type's generated class **into one shared `StringBuffer`**, then
write that single buffer as the category's only output:

- `generateEnums` → `enums/enums.dart` only (one file, all `@JsonEnum()` declarations
  inline; enums need no `part` directive today and none is added — `@JsonValue`
  annotations are consumed by *other* classes' generated `.g.dart`, not their own).
- `generateInputs` → `inputs/inputs.dart` only (one file, all Freezed input classes
  inline, with one shared `part 'inputs.freezed.dart'; part 'inputs.g.dart';` pair).
- `generateObjectTypes` → `models/models.dart` only (same pattern, one shared
  `part 'models.freezed.dart'; part 'models.g.dart';` pair).

Each function still returns `{}` (writing nothing) when its input list is empty —
matching today's behavior for a schema with zero enums/inputs/objects, and preserving
the non-goal above.

`_generateFreezedClass` (private helper both `generateInputs` and `generateObjectTypes`
already call per type into a passed-in `buffer`) needs no change — it already writes
into whatever buffer it's given, so calling it once per type into one shared buffer
(instead of a fresh buffer per type) is the entire mechanical change.

### 2. Cross-references need no change

`needsEnumImport`/`needsInputImport`/`needsModelImport` in both functions already
compute "does this type reference something outside its own category" and, when true,
import the **barrel** filename via `resolveGeneratedImport(..., targetFile: 'inputs.dart', ...)`
(or `enums.dart`/`models.dart`) — never a per-type file. Callers of `inputs.dart`/
`models.dart`/`enums.dart` (operation-level generated files, the schema client
extension) already import the barrel too. None of that changes.

One simplification falls out naturally: `generateObjectTypes`'s existing
`if (baseType.endsWith('Model') && baseType != className) needsModelImport = true;`
(a model referencing another model needs to import `models.dart`, unless it's
referencing itself) generalizes to "never true" once every model lives in the same
file — a model referencing another model is now an intra-file reference needing no
import at all. The condition is deleted rather than kept as always-false dead code.

### 3. `computeOutputPaths` mirrors the same three fixed names

`GeneratorOrchestrator.computeOutputPaths`
(`packages/mk_graphql_generator/lib/src/generator/orchestrator/generator_orchestrator.dart`)
currently predicts one output path per enum/input/object type plus the barrel. It
changes to predict only the barrel path per non-empty category — the same
non-empty-list guard as today, just without the per-type loop:

```dart
if (parsed.enumTypes.isNotEmpty) {
  outputs.add('${sharedPrefix}enums/enums.dart');
}
if (parsed.inputTypes.isNotEmpty) {
  outputs.add('${sharedPrefix}inputs/inputs.dart');
}
if (objectTypes.isNotEmpty) {  // Query/Mutation/Subscription-filtered, as today
  outputs.add('${sharedPrefix}models/models.dart');
}
```

This is what makes the fix real: the declared output set for the schema file is now
exactly `{enums/enums.dart, inputs/inputs.dart, models/models.dart, {name}.gql.dart}`
(each conditional only on its category being non-empty *at all* — never on *how many*
types it has), so it cannot go stale as a schema grows once each category exists.

### 4. Error handling

No new error paths. The three `generate*` functions already return `{}` for an empty
input list — unchanged. `computeOutputPaths` already guards each category on
`isNotEmpty` — unchanged shape, just one output per category instead of many.

### 5. Testing

- **Update existing assertions** in `packages/mk_graphql_generator/test/generator_test.dart`
  that check a specific per-type file path (e.g.
  `bundle.files['generated/models/user_response_model.dart']`,
  `bundle.files['generated/inputs/filter_input.dart']`,
  `bundle.files['generated/enums/user_role_enum.dart']`) to instead check for the
  class's declaration *inside* the merged `models.dart`/`inputs.dart`/`enums.dart`
  content. Also update assertions on `bundle.files.keys` that currently expect
  per-type paths to be present (e.g. `contains('generated/models/item_model.dart')`)
  or absent (`isNot(contains('generated/enums/enums.dart'))` for non-schema files —
  unaffected, still correct) to match the new fixed set.
- **New regression test** reproducing the original bug end-to-end, replacing the
  throwaway repro used during diagnosis: compute `buildExtensions`-equivalent output
  paths for a schema (`computeOutputPaths`), then generate a bundle for the *same*
  schema with one additional type added to an *already-populated* category (e.g. a
  second `Author` type added to a schema that already has `Post`), and assert every
  path in the new bundle is contained in the paths computed from the original schema.
  This is the test that would have failed before this fix and passes after.
- **New unit test** confirming the 0→1 non-goal is still accurate and documented in
  behavior (a schema with zero inputs produces no `inputs/inputs.dart` key at all —
  already implicitly covered by existing tests checking `isNot(contains('inputs.dart'))`
  for input-less schemas, but worth a direct assertion here for clarity).
- Full `dart test` + `dart analyze` pass for `mk_graphql_generator`, same as every
  change in this package.
- `GeneratorCache.version` bump (same pattern as the `v14`→`v15` bump for the
  keyword-escaping fix): this changes generated output shape for every schema with
  more than one type in a category, so stale on-disk cache entries must be invalidated.

## Breaking change

Generated output shape changes: `generated/models/{type}_model.dart`,
`generated/inputs/{type}.dart`, and `generated/enums/{type}_enum.dart` (the per-type
files) no longer exist after regeneration — their content moves into
`generated/models/models.dart`, `generated/inputs/inputs.dart`, and
`generated/enums/enums.dart` respectively. Any app importing one of those per-type
paths directly (rather than the barrel, which is what the README/docs have always
shown) will break and needs to switch to importing the barrel. This is called out
explicitly in the CHANGELOG as **Breaking**, with the before/after import example.

## Release

This ships as `mk_graphql_generator` `1.2.1-dev.3` (following the existing
`GeneratorCache` version-bump pattern from `dev.2`), with a CHANGELOG entry stating
the breaking change and the residual 0→1 limitation, and a note that regenerating
(`dart run build_runner build --delete-conflicting-outputs`) picks it up.
