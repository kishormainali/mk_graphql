# Generator Barrel File Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `mk_graphql_generator` producing incomplete `models.dart`/`inputs.dart` barrels when a GraphQL schema grows while `dart run build_runner watch` is already running, by merging the current one-file-per-type schema output into three fixed files whose existence no longer depends on the schema's type count.

**Architecture:** `SchemaGenerator.generateEnums`/`generateInputs`/`generateObjectTypes` (`packages/mk_graphql_generator/lib/src/generator/schema/schema_generator.dart`) stop writing one file per GraphQL type; each writes every type in its category into one shared buffer and returns a single file (`enums/enums.dart`, `inputs/inputs.dart`, `models/models.dart`). `GeneratorOrchestrator.computeOutputPaths` (`packages/mk_graphql_generator/lib/src/generator/orchestrator/generator_orchestrator.dart`) — which predicts a schema file's outputs once, before any type-by-type generation runs, so `build_runner`'s `Builder.buildExtensions` can declare them up front — mirrors the same three fixed paths. Nothing else changes: every consumer of these files already imports the barrel filename, never a per-type file.

**Tech Stack:** Dart, `package:build`/`build_runner` (target, not a dependency of this package), `package:test`, `freezed_annotation`/`json_serializable` (consumed by generated output), `package:recase` (`.pascalCase`/`.snakeCase`).

**Spec:** `docs/superpowers/specs/2026-09-25-generator-barrel-file-merge-design.md`

## Global Constraints

- Every function signature in `schema_generator.dart` and `computeOutputPaths` keeps its exact current parameter list — callers in `generator_orchestrator.dart` are unchanged.
- `generateEnums`/`generateInputs`/`generateObjectTypes` keep returning `{}` (writing nothing) when their input list is empty — this preserves the documented, accepted 0→1 limitation (a category's *first* type still needs a `watch` restart) rather than silently pretending it's gone.
- No change to operation-level (`.graphql` query/mutation file) output — only the three schema-level category functions and their matching prediction in `computeOutputPaths`.
- `dart format` and `dart analyze` must be clean, and `dart test` must pass with zero failures, before any commit in this plan.
- Before running `dart test` in any task below, run `rm -rf .dart_tool/mk_graphql_cache` first — `GeneratorCache`'s on-disk cache does not key on this package's own source changes, only on `GeneratorCache.version` + input content, so a stale entry from a previous run in this same checkout can make a genuinely-fixed test look like it's still failing (and vice versa).

## Review Focus

- **The primary bug case is pinned by a real test, not just claimed fixed.** A schema gaining an object type while an already-populated `models` category exists must produce zero outputs outside what `computeOutputPaths` predicted before the change. (Task 1)
- **An input type referencing another input type.** No existing test exercises this; the merge changes it from "import the inputs barrel" to "no import at all, it's the same file now" — a plausible place for a leftover unused-import or a missed removal to surface. (Task 3)
- **The documented 0→1 residual limitation is still honestly true.** A category's first-ever type appearing after the "already declared" snapshot must still be missing from that snapshot — this test protects against someone mistaking a future tweak for closing this gap without updating the docs/CHANGELOG that say it's still open. (Task 1)
- **Import-flag accumulation across multiple types in one merged file is order-independent.** A 3-model schema where only the last-processed model references an enum must still produce a `models.dart` that imports `enums.dart` — proving the flag is unioned across every type, not just read off whichever type happened to be generated last. (Task 3)
- **A self-referencing model type** (e.g. `type User { friend: User }`) compiles correctly with no self-import — the old code had an explicit `baseType != className` guard for exactly this case; the merge removes the import path entirely rather than keeping that guard as now-dead code, and a self-referencing type is common enough (tree/graph shapes) to be worth pinning directly. (Task 3)

---

### Task 1: Add the regression test proving the original bug, against today's (buggy) code

**Files:**
- Modify: `packages/mk_graphql_generator/test/generator_test.dart` (add to the `group('computeOutputPaths Tests', ...)` block, which currently spans lines 892–954)

**Interfaces:**
- Consumes: `GeneratorOrchestrator.computeOutputPaths({required String content, required String inputPath, String? schemaPath, String? sharedDir}) -> List<String>` and `GeneratorOrchestrator.generateForGraphQLFile({required String content, required String inputPath, ...}) -> GeneratedBundle` (both already exist, both unchanged by this task — `GeneratedBundle` exposes `.files` as `Map<String, String>`).
- Produces: nothing new for later tasks to consume — this is a pinning test.

- [ ] **Step 1: Write the two new tests**

Open `packages/mk_graphql_generator/test/generator_test.dart`. Find the `group('computeOutputPaths Tests', ...)` block (starts around line 892) and its closing `});` (around line 954, right before `group('Shared vs Partial Models Tests', ...)`). Insert the following two `test(...)` blocks immediately before that group's closing `});`, i.e. after the existing `test('returns empty set for non-graphql files', ...)`:

```dart
    test(
        'growing an already-populated category during a live watch session '
        'never produces an output outside what was declared when the '
        'builder started — this is the actual bug this generator once had: '
        'a schema gaining a type while `build_runner watch` kept running '
        'used to write an undeclared per-type file, which build_runner '
        'rejects, aborting that build before models.dart/inputs.dart got '
        'rewritten and leaving them on disk with a stale export list', () {
      const schemaV1 = '''
        type Post {
          id: ID!
          title: String!
        }
      ''';
      // What MkGraphQLBuilder's factory computes once, at watch-session
      // start, from the schema's content at that moment — this is what
      // build_runner's Builder.buildExtensions declares as the schema
      // file's allowed outputs for the rest of that watch session.
      final declaredAtWatchStart = GeneratorOrchestrator.computeOutputPaths(
        content: schemaV1,
        inputPath: 'lib/schema.graphql',
        schemaPath: 'lib/schema.graphql',
      ).toSet();

      // The developer edits schema.graphql while watch is still running —
      // adding a second object type to the already-populated `models`
      // category — and saves.
      const schemaV2 = '''
        type Post {
          id: ID!
          title: String!
        }

        type Author {
          id: ID!
          name: String!
        }
      ''';
      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schemaV2,
        inputPath: 'lib/schema.graphql',
        schemaPath: 'lib/schema.graphql',
      );

      // Every real output must already have been declared at watch start —
      // nothing new for build_runner to reject.
      expect(declaredAtWatchStart.containsAll(bundle.files.keys), isTrue,
          reason: 'undeclared outputs: '
              '${bundle.files.keys.toSet().difference(declaredAtWatchStart)}');

      // And the merged barrel genuinely contains both types — the bug's
      // actual symptom was a barrel missing the new type's export.
      expect(bundle.files['generated/models/models.dart'],
          contains('class PostModel'));
      expect(bundle.files['generated/models/models.dart'],
          contains('class AuthorModel'));
    });

    test(
        'a category\'s first-ever type appearing during a live watch '
        'session is a known, accepted limitation this fix does not close — '
        'unlike growing an already-populated category, this still needs a '
        'watch restart, and this test exists so that remains true and '
        'documented rather than silently assumed', () {
      const schemaV1 = '''
        type Post {
          id: ID!
          title: String!
        }
      ''';
      final declaredAtWatchStart = GeneratorOrchestrator.computeOutputPaths(
        content: schemaV1,
        inputPath: 'lib/schema.graphql',
        schemaPath: 'lib/schema.graphql',
      ).toSet();

      // The schema's first-ever enum appears — a brand new category, not
      // an addition to one that already existed at watch start.
      const schemaV2 = '''
        type Post {
          id: ID!
          title: String!
        }

        enum Status {
          DRAFT
          PUBLISHED
        }
      ''';
      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schemaV2,
        inputPath: 'lib/schema.graphql',
        schemaPath: 'lib/schema.graphql',
      );

      expect(declaredAtWatchStart.containsAll(bundle.files.keys), isFalse,
          reason:
              'this is the documented 0→1 limitation — enums/enums.dart '
              'appearing for the first time is expected to be undeclared '
              'here; if this assertion starts failing, the limitation has '
              'actually been closed and docs/CHANGELOG need updating, not '
              'this test');
      expect(bundle.files.keys, contains('generated/enums/enums.dart'));
    });
```

- [ ] **Step 2: Run both new tests to verify they fail/pass as expected against today's code**

```bash
cd packages/mk_graphql_generator
rm -rf .dart_tool/mk_graphql_cache
dart test test/generator_test.dart -n "growing an already-populated category" -n "a category's first-ever type"
```

Expected: the first test (**growing an already-populated category**) **fails** — `declaredAtWatchStart.containsAll(bundle.files.keys)` is `false` because `generated/models/author_model.dart` is in `bundle.files.keys` but not in `declaredAtWatchStart`. Read the failure's `reason:` output and confirm it names exactly `generated/models/author_model.dart` — that confirms it's failing for the bug, not a typo.

The second test (**a category's first-ever type**) **passes already** — it's pinning a limitation that already exists in today's code (nothing to fix here), not proving a new bug. This is expected and correct; it stays green through the rest of this plan as a guard against accidentally over-fixing.

- [ ] **Step 3: Commit**

```bash
git add packages/mk_graphql_generator/test/generator_test.dart
git commit -m "test(generator): pin the buildExtensions-staleness bug and its documented 0->1 limitation"
```

---

### Task 2: Update every other existing test to the post-merge expected output shape

**Files:**
- Modify: `packages/mk_graphql_generator/test/generator_test.dart`

**Interfaces:**
- Consumes: same two functions as Task 1.
- Produces: nothing new — this task only edits existing assertions.

- [ ] **Step 1: Edit 1 — the primary "generates enums/, inputs/, models/, and operation directories" test (lines 41–77)**

Replace:

```dart
      // Verify files map contains expected structured paths
      expect(
          bundle.files.keys, contains('generated/enums/user_role_enum.dart'));
      expect(bundle.files.keys, contains('generated/enums/enums.dart'));
      expect(bundle.files.keys,
          contains('generated/inputs/user_filter_input.dart'));
      expect(bundle.files.keys, contains('generated/inputs/inputs.dart'));
      expect(bundle.files.keys,
          contains('generated/models/user_response_model.dart'));
      expect(bundle.files.keys, contains('generated/models/models.dart'));
      expect(
          bundle.files.keys, contains('generated/get_user/get_user_var.dart'));
      expect(bundle.files.keys,
          contains('generated/get_user/get_user_model.dart'));
      expect(
          bundle.files.keys, contains('generated/get_user/get_user_req.dart'));
      expect(bundle.files.keys, contains('generated/get_user/get_user.dart'));
      expect(bundle.files.keys, contains('generated/schema.gql.dart'));

      // Verify Enum File
      final enumContent = bundle.files['generated/enums/user_role_enum.dart']!;
      expect(enumContent, contains('@JsonEnum()'));
      expect(enumContent, contains('enum UserRole'));

      // Verify Input File
      final inputContent =
          bundle.files['generated/inputs/user_filter_input.dart']!;
      expect(inputContent, contains('@freezed'));
      expect(inputContent, contains(r'UserFilterInput with _$UserFilterInput'));

      // Verify Model File
      final modelContent =
          bundle.files['generated/models/user_response_model.dart']!;
      expect(modelContent, contains('@freezed'));
      expect(modelContent,
          contains(r'UserResponseModel with _$UserResponseModel'));
      expect(modelContent, contains('required String id'));
```

with:

```dart
      // Verify files map contains expected structured paths — one merged
      // barrel per category (not one file per type) is the point of this
      // generator: see
      // docs/superpowers/specs/2026-09-25-generator-barrel-file-merge-design.md.
      expect(bundle.files.keys, contains('generated/enums/enums.dart'));
      expect(bundle.files.keys, contains('generated/inputs/inputs.dart'));
      expect(bundle.files.keys, contains('generated/models/models.dart'));
      expect(
          bundle.files.keys, contains('generated/get_user/get_user_var.dart'));
      expect(bundle.files.keys,
          contains('generated/get_user/get_user_model.dart'));
      expect(
          bundle.files.keys, contains('generated/get_user/get_user_req.dart'));
      expect(bundle.files.keys, contains('generated/get_user/get_user.dart'));
      expect(bundle.files.keys, contains('generated/schema.gql.dart'));

      // Verify Enum File
      final enumContent = bundle.files['generated/enums/enums.dart']!;
      expect(enumContent, contains('@JsonEnum()'));
      expect(enumContent, contains('enum UserRole'));

      // Verify Input File
      final inputContent = bundle.files['generated/inputs/inputs.dart']!;
      expect(inputContent, contains('@freezed'));
      expect(inputContent, contains(r'UserFilterInput with _$UserFilterInput'));

      // Verify Model File
      final modelContent = bundle.files['generated/models/models.dart']!;
      expect(modelContent, contains('@freezed'));
      expect(modelContent,
          contains(r'UserResponseModel with _$UserResponseModel'));
      expect(modelContent, contains('required String id'));
```

(The rest of this test, from `// Verify Operation Vars, Model, & Request` through the end, is unchanged — operation files and the root `schema.gql.dart`'s `export 'enums/enums.dart';`/`export 'inputs/inputs.dart';`/`export 'models/models.dart';` lines already referenced the barrel names, not per-type files.)

- [ ] **Step 2: Edit 2 — "enum values are generated as camelCase Dart identifiers" test**

Replace:
```dart
      final enumContent = bundle.files['generated/enums/user_role_enum.dart']!;
```
with:
```dart
      final enumContent = bundle.files['generated/enums/enums.dart']!;
```

- [ ] **Step 3: Edit 3 — ".gql schema file produces the same structured output as .graphql" test**

Replace:
```dart
      expect(bundle.files.keys,
          contains('generated/models/user_response_model.dart'));
      expect(bundle.files.keys, contains('generated/models/models.dart'));
      expect(bundle.files.keys, contains('generated/schema.gql.dart'));
```
with:
```dart
      expect(bundle.files.keys, contains('generated/models/models.dart'));
      expect(bundle.files.keys, contains('generated/schema.gql.dart'));
```

- [ ] **Step 4: Edit 4 — "generated model/input files only import enums/inputs/models barrels they actually reference" test**

Replace:
```dart
      // A model whose fields are all plain scalars needs none of the
      // shared barrels.
      final plainModel =
          bundle.files['generated/models/plain_thing_model.dart']!;
      expect(plainModel, isNot(contains("enums.dart")));
      expect(plainModel, isNot(contains("inputs.dart")));
      expect(plainModel, isNot(contains("import 'models.dart';")));

      // A model referencing an enum and another model type needs exactly
      // those two barrels, not inputs.
      final userModel =
          bundle.files['generated/models/user_response_model.dart']!;
      expect(userModel, contains("import '../enums/enums.dart';"));
      expect(userModel, contains("import 'models.dart';"));
      expect(userModel, isNot(contains("inputs.dart")));
    });
```
with:
```dart
      // Every model now lives in one merged models.dart, so "does this
      // reference an enum/input/model" is a property of the FILE as a
      // whole (does ANY model in it reference something outside its own
      // category), not of each individual class.
      final modelsFile = bundle.files['generated/models/models.dart']!;
      // UserResponse references the UserRole enum, so the file needs the
      // enums barrel...
      expect(modelsFile, contains("import '../enums/enums.dart';"));
      // ...but nothing here references an input type.
      expect(modelsFile, isNot(contains("inputs.dart")));
      // UserResponse's other reference (Address) is now just another class
      // in this SAME file — no self-import of models.dart is ever needed.
      expect(modelsFile, isNot(contains("import 'models.dart';")));
      expect(modelsFile, contains('class PlainThingModel'));
      expect(modelsFile, contains('class AddressModel'));
      expect(modelsFile, contains('class UserResponseModel'));
    });
```

- [ ] **Step 5: Edit 5 — "schema-level model/input files use package: imports for shared barrels when packageName is provided" test**

Replace:
```dart
      final userModel =
          bundle.files['generated/models/user_response_model.dart']!;
      expect(
          userModel,
          contains(
              "import 'package:my_app/graphql/generated/enums/enums.dart';"));
      expect(userModel, isNot(contains("import '../")));
    });
```
with:
```dart
      final modelsFile = bundle.files['generated/models/models.dart']!;
      expect(
          modelsFile,
          contains(
              "import 'package:my_app/graphql/generated/enums/enums.dart';"));
      expect(modelsFile, isNot(contains("import '../")));
    });
```

- [ ] **Step 6: Edit 6 — "respects custom schemaPath and sharedDir options" test**

Replace:
```dart
      expect(schemaBundle.files.keys,
          contains('../shared/generated/enums/status_enum.dart'));
      expect(schemaBundle.files.keys,
          contains('../shared/generated/enums/enums.dart'));
      expect(schemaBundle.files.keys,
          contains('../shared/generated/models/user_model.dart'));
      expect(schemaBundle.files.keys,
          contains('../shared/generated/models/models.dart'));
      expect(schemaBundle.files.keys,
          contains('../shared/generated/custom_schema.gql.dart'));
```
with:
```dart
      expect(schemaBundle.files.keys,
          contains('../shared/generated/enums/enums.dart'));
      expect(schemaBundle.files.keys,
          contains('../shared/generated/models/models.dart'));
      expect(schemaBundle.files.keys,
          contains('../shared/generated/custom_schema.gql.dart'));
```

(This test's later assertions on `barrelFile` — the two lines checking `'../../shared/generated/models/models.dart'` and `'../../shared/generated/enums/enums.dart'` inside `generated/status.gql.dart` — are unchanged; they already referenced barrel names.)

- [ ] **Step 7: Edit 7 — "re-generates when input content or schema content changes" test**

Replace:
```dart
      expect(bundle1.files['generated/models/user_model.dart'],
          isNot(contains('required String name')));
      expect(bundle2.files['generated/models/user_model.dart'],
          contains('required String name'));
```
with:
```dart
      expect(bundle1.files['generated/models/models.dart'],
          isNot(contains('required String name')));
      expect(bundle2.files['generated/models/models.dart'],
          contains('required String name'));
```

- [ ] **Step 8: Edit 8 — "computes fast expected output paths for schema file without full code generation" test**

Replace:
```dart
      expect(paths, contains('generated/enums/status_enum.dart'));
      expect(paths, contains('generated/enums/enums.dart'));
      expect(paths, contains('generated/inputs/create_user_input.dart'));
      expect(paths, contains('generated/inputs/inputs.dart'));
      expect(paths, contains('generated/models/user_model.dart'));
      expect(paths, contains('generated/models/models.dart'));
      expect(paths, contains('generated/schema.gql.dart'));
```
with:
```dart
      expect(paths, contains('generated/enums/enums.dart'));
      expect(paths, contains('generated/inputs/inputs.dart'));
      expect(paths, contains('generated/models/models.dart'));
      expect(paths, contains('generated/schema.gql.dart'));
      // No per-type paths (generated/enums/status_enum.dart, etc.) — the
      // schema file's declared output set stops growing with its type
      // count, which is the actual fix. See the "computeOutputPaths Tests"
      // group's other two tests for the end-to-end proof.
      expect(paths, hasLength(4));
```

- [ ] **Step 9: Edit 9 — "generates shared models with strict non-nullable fields" test**

Replace:
```dart
      final countryModel = bundle.files['generated/models/country_model.dart']!;
```
with:
```dart
      final countryModel = bundle.files['generated/models/models.dart']!;
```

- [ ] **Step 10: Edit 10 — "generates an operation-scoped model when query selects partial required fields" test**

Replace:
```dart
      expect(bundle.files.containsKey('generated/models/country_model.dart'),
          isFalse);
```
with:
```dart
      expect(bundle.files.containsKey('generated/models/models.dart'),
          isFalse);
```

- [ ] **Step 11: Edit 11 — "Dart reserved keywords map to g{Keyword} with @JsonKey(name: raw)" test**

Replace:
```dart
      final itemModel = bundle.files['generated/models/item_model.dart']!;
```
with:
```dart
      final itemModel = bundle.files['generated/models/models.dart']!;
```

Replace:
```dart
      final filterInput = bundle.files['generated/inputs/filter_input.dart']!;
```
with:
```dart
      final filterInput = bundle.files['generated/inputs/inputs.dart']!;
```

Replace:
```dart
      final statusEnum = bundle.files['generated/enums/status_enum.dart']!;
```
with:
```dart
      final statusEnum = bundle.files['generated/enums/enums.dart']!;
```

(Every `expect(...)` in this test that reads `itemModel`/`filterInput`/`statusEnum` afterward is unchanged — the content it checks for is still present, just inside a bigger merged file now.)

- [ ] **Step 12: Edit 12 — "a field named after a Dart core type (int/double/bool/num) maps to g{Name}" test**

Replace:
```dart
      final readingModel = bundle.files['generated/models/reading_model.dart']!;
```
with:
```dart
      final readingModel = bundle.files['generated/models/models.dart']!;
```

- [ ] **Step 13: Run the full suite and confirm the failures are exactly the ones this task's edits describe (schema_generator.dart/generator_orchestrator.dart haven't changed yet)**

```bash
rm -rf .dart_tool/mk_graphql_cache
dart test
```

Expected: most of the tests this task touched still **fail** (the code hasn't changed yet — only the assertions have). Confirm each failure is a `Null check operator used on a null value` (from a `bundle.files['...']!` key that no longer exists yet) or a content mismatch, not a compile error. Task 1's two new tests should show the same results as at the end of Task 1 (one red, one green). Do **not** proceed to Task 3 until every failure here is one this task's own edits explain — an unexplained failure means a missed edit above.

- [ ] **Step 14: Commit**

```bash
git add packages/mk_graphql_generator/test/generator_test.dart
git commit -m "test(generator): update assertions for the merged schema-level barrel files"
```

---

### Task 3: Merge `generateEnums`/`generateInputs`/`generateObjectTypes` into one file per category

**Files:**
- Modify: `packages/mk_graphql_generator/lib/src/generator/schema/schema_generator.dart:43-267` (the three `generate*` functions)
- Test: `packages/mk_graphql_generator/test/generator_test.dart` (adds the 5 Review Focus regression tests from this task's Step 1)

**Interfaces:**
- Consumes: `resolveGeneratedImport({required String? packageName, required String generatedDir, required String targetSubDir, required String targetFile, required String fromSubDir}) -> String`, `_generateFreezedClass({required String className, required Map<String, FieldTypeInfo> fields, required StringBuffer buffer, bool isInput = false})`, `parseFieldType(...)`, `_unwrapDartType(String) -> String`, `_toDartEnumValue(String) -> String`, `formatDefaultValue(...)` — all already exist in this file, unchanged.
- Produces: `generateEnums(List<EnumTypeDefinitionNode> enums) -> Map<String, String>` returning at most `{'enums/enums.dart': ...}` (or `{}`); `generateInputs(...) -> Map<String, String>` returning at most `{'inputs/inputs.dart': ...}`; `generateObjectTypes(...) -> Map<String, String>` returning at most `{'models/models.dart': ...}`. Same signatures as before — `generator_orchestrator.dart`'s call sites (Task 4 reads them, doesn't change them) need no edits.

- [ ] **Step 1: Add the 4 new regression tests this task's changes need (Review Focus items not already covered)**

In `packages/mk_graphql_generator/test/generator_test.dart`, add these 4 tests inside `group('GraphQL Conventions & Optimizations Tests', ...)` (the group containing `conventionSchema` — add them right after the `'Dart reserved keywords map to g{Keyword} with @JsonKey(name: raw)'` test, which Task 2's Step 11 already updated):

```dart
    test(
        'an input type referencing another input type needs no import — '
        'both live in the same merged inputs.dart', () {
      const schema = '''
        input AddressInput {
          street: String!
        }

        input CreateUserInput {
          name: String!
          address: AddressInput
        }

        type Query {
          placeholder: String
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schema,
        inputPath: 'lib/graphql/schema.graphql',
      );

      final inputsFile = bundle.files['generated/inputs/inputs.dart']!;
      // Class names are the GraphQL input type name as-is (pascalCase, no
      // suffix appended) — unlike models, which get "Model" appended.
      expect(inputsFile, contains('class AddressInput'));
      expect(inputsFile, contains('class CreateUserInput'));
      expect(inputsFile, isNot(contains("import 'inputs.dart';")));
    });

    test(
        'a models.dart import flag is unioned across every model in the '
        'file, not just the last one generated — only the third of three '
        'models here references an enum, and the file must still import '
        'enums.dart', () {
      const schema = '''
        enum Status {
          ACTIVE
          INACTIVE
        }

        type Alpha {
          id: ID!
        }

        type Beta {
          id: ID!
        }

        type Gamma {
          id: ID!
          status: Status!
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schema,
        inputPath: 'lib/graphql/schema.graphql',
      );

      final modelsFile = bundle.files['generated/models/models.dart']!;
      expect(modelsFile, contains("import '../enums/enums.dart';"));
      expect(modelsFile, contains('class AlphaModel'));
      expect(modelsFile, contains('class BetaModel'));
      expect(modelsFile, contains('class GammaModel'));
    });

    test(
        'a self-referencing model type compiles with no self-import — the '
        'field and its declaring class are in the same merged models.dart',
        () {
      const schema = '''
        type User {
          id: ID!
          name: String!
          friend: User
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schema,
        inputPath: 'lib/graphql/schema.graphql',
      );

      final modelsFile = bundle.files['generated/models/models.dart']!;
      expect(modelsFile, contains('class UserModel'));
      expect(modelsFile, contains('UserModel? friend'));
      expect(modelsFile, isNot(contains("import 'models.dart';")));
    });

    test('an enum-only schema (no inputs, no non-root object types) merges '
        'correctly and produces no inputs.dart or models.dart at all', () {
      const schema = '''
        enum Status {
          ACTIVE
          INACTIVE
        }

        type Query {
          status: Status
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schema,
        inputPath: 'lib/graphql/schema.graphql',
      );

      expect(bundle.files.keys, contains('generated/enums/enums.dart'));
      expect(bundle.files.keys, isNot(contains('generated/inputs/inputs.dart')));
      expect(bundle.files.keys, isNot(contains('generated/models/models.dart')));
    });
```

- [ ] **Step 2: Run the whole suite to confirm the new tests from Step 1 fail for the right reason (schema_generator.dart hasn't changed yet)**

```bash
cd packages/mk_graphql_generator
rm -rf .dart_tool/mk_graphql_cache
dart test test/generator_test.dart -n "input type referencing another input type" -n "unioned across every model" -n "self-referencing model type" -n "enum-only schema"
```

Expected: 3 of the 4 **fail**: "input type referencing another input type", "unioned across every model", and "self-referencing model type" each read `bundle.files['generated/inputs/inputs.dart']!`/`bundle.files['generated/models/models.dart']!` — those keys already exist today too (today's code still writes them as a barrel of `export 'address_input.dart'; export 'create_user_input.dart';`-style lines, alongside the separate per-type files), so the `!` doesn't throw. The failure instead comes from the very next line: each test's `contains('class ...')`/`contains("import '../enums/enums.dart';")` assertion fails, because today's barrel content is only comment headers and `export` statements — no class bodies, no import lines. The 4th test, "enum-only schema", **already passes** — `generateEnums` already writes a single `enums/enums.dart` key today (just with export-statement content instead of the enum body, which this particular test doesn't inspect), and `generateInputs`/`generateObjectTypes` already return nothing for an empty type list — so this test isn't pinning anything Task 3 changes; it's cheap regression coverage for the single-populated-category case, kept passing before and after.

- [ ] **Step 3: Replace `generateEnums`**

In `packages/mk_graphql_generator/lib/src/generator/schema/schema_generator.dart`, replace the entire function (lines 43–81):

```dart
  static Map<String, String> generateEnums(List<EnumTypeDefinitionNode> enums) {
    final result = <String, String>{};
    final enumExports = <String>[];

    for (final enumDef in enums) {
      final name = enumDef.name.value.pascalCase;
      final fileName = '${enumDef.name.value.snakeCase}_enum.dart';
      final buffer = StringBuffer();

      buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      buffer.writeln('// ignore_for_file: type=lint');
      buffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
      buffer.writeln();
      buffer.writeln(codegen.emitSpec(codegen.jsonEnum(
        name: name,
        values: {
          // e.g. ADMIN_USER (wire) -> adminUser (Dart)
          for (final val in enumDef.values)
            val.name.value: _toDartEnumValue(val.name.value),
        },
      )));

      result['enums/$fileName'] = buffer.toString();
      enumExports.add("export '$fileName';");
    }

    if (enumExports.isNotEmpty) {
      final barrelBuffer = StringBuffer();
      barrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      barrelBuffer.writeln('// ignore_for_file: type=lint');
      for (final exp in enumExports) {
        barrelBuffer.writeln(exp);
      }
      result['enums/enums.dart'] = barrelBuffer.toString();
    }

    return result;
  }
```

with:

```dart
  /// Every schema enum, declared inline in one `enums/enums.dart` — not one
  /// file per enum plus a barrel of exports. This keeps the schema file's
  /// declared build_runner outputs fixed regardless of how many enums the
  /// schema defines; see
  /// docs/superpowers/specs/2026-09-25-generator-barrel-file-merge-design.md.
  /// Enums need no `part` directive — `@JsonEnum()`/`@JsonValue(...)` are
  /// consumed at runtime by json_annotation and by *other* classes'
  /// generated `.g.dart`, never by a companion file of their own.
  static Map<String, String> generateEnums(List<EnumTypeDefinitionNode> enums) {
    if (enums.isEmpty) return const {};

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: type=lint');
    buffer.writeln(
        "import 'package:freezed_annotation/freezed_annotation.dart';");
    buffer.writeln();

    for (final enumDef in enums) {
      final name = enumDef.name.value.pascalCase;
      buffer.writeln(codegen.emitSpec(codegen.jsonEnum(
        name: name,
        values: {
          // e.g. ADMIN_USER (wire) -> adminUser (Dart)
          for (final val in enumDef.values)
            val.name.value: _toDartEnumValue(val.name.value),
        },
      )));
    }

    return {'enums/enums.dart': buffer.toString()};
  }
```

- [ ] **Step 4: Replace `generateInputs`**

Replace the entire function (lines 83–168):

```dart
  static Map<String, String> generateInputs(
    List<InputObjectTypeDefinitionNode> inputs,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    final result = <String, String>{};
    final inputExports = <String>[];

    for (final inputDef in inputs) {
      final name = inputDef.name.value.pascalCase;
      final fileName = '${inputDef.name.value.snakeCase}.dart';
      final buffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      var needsEnumImport = false;
      var needsInputImport = false;
      for (final field in inputDef.fields) {
        final rawFieldName = field.name.value;
        final typeInfo = parseFieldType(field.type,
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
            customScalars: customScalars);
        final defaultValueStr =
            formatDefaultValue(field.defaultValue, dartType: typeInfo.dartType);
        fields[rawFieldName] = FieldTypeInfo(
          dartType: typeInfo.dartType,
          isRequired: defaultValueStr == null && typeInfo.isRequired,
          defaultValue: defaultValueStr,
        );
        final baseType = _unwrapDartType(typeInfo.dartType);
        if (enumNames.contains(baseType)) needsEnumImport = true;
        if (inputNames.contains(baseType) && baseType != name)
          needsInputImport = true;
      }

      buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      buffer.writeln('// ignore_for_file: type=lint');
      buffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
      if (needsInputImport) {
        buffer.writeln("import '${resolveGeneratedImport(
          packageName: packageName,
          generatedDir: generatedDir,
          targetSubDir: 'inputs',
          targetFile: 'inputs.dart',
          fromSubDir: 'inputs',
        )}';");
      }
      if (needsEnumImport) {
        buffer.writeln("import '${resolveGeneratedImport(
          packageName: packageName,
          generatedDir: generatedDir,
          targetSubDir: 'enums',
          targetFile: 'enums.dart',
          fromSubDir: 'inputs',
        )}';");
      }
      buffer.writeln();
      buffer.writeln("part '${inputDef.name.value.snakeCase}.freezed.dart';");
      buffer.writeln("part '${inputDef.name.value.snakeCase}.g.dart';");
      buffer.writeln();

      _generateFreezedClass(
          className: name, fields: fields, buffer: buffer, isInput: true);

      result['inputs/$fileName'] = buffer.toString();
      inputExports.add("export '$fileName';");
    }

    if (inputExports.isNotEmpty) {
      final barrelBuffer = StringBuffer();
      barrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      barrelBuffer.writeln('// ignore_for_file: type=lint');
      for (final exp in inputExports) {
        barrelBuffer.writeln(exp);
      }
      result['inputs/inputs.dart'] = barrelBuffer.toString();
    }

    return result;
  }
```

with:

```dart
  /// Every schema input type, declared inline in one `inputs/inputs.dart`
  /// with a single shared `part 'inputs.freezed.dart'; part 'inputs.g.dart';`
  /// pair — not one file per input plus a barrel of exports. Same rationale
  /// as [generateEnums]. An input referencing another input type needs no
  /// import at all now — both live in this same file — unlike an input
  /// referencing an enum, which is still a genuine cross-file (cross-
  /// category) reference to `enums/enums.dart`.
  static Map<String, String> generateInputs(
    List<InputObjectTypeDefinitionNode> inputs,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    if (inputs.isEmpty) return const {};

    var needsEnumImport = false;
    final classBuffers = <StringBuffer>[];

    for (final inputDef in inputs) {
      final name = inputDef.name.value.pascalCase;
      final classBuffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      for (final field in inputDef.fields) {
        final rawFieldName = field.name.value;
        final typeInfo = parseFieldType(field.type,
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
            customScalars: customScalars);
        final defaultValueStr =
            formatDefaultValue(field.defaultValue, dartType: typeInfo.dartType);
        fields[rawFieldName] = FieldTypeInfo(
          dartType: typeInfo.dartType,
          isRequired: defaultValueStr == null && typeInfo.isRequired,
          defaultValue: defaultValueStr,
        );
        final baseType = _unwrapDartType(typeInfo.dartType);
        if (enumNames.contains(baseType)) needsEnumImport = true;
      }

      _generateFreezedClass(
          className: name, fields: fields, buffer: classBuffer, isInput: true);
      classBuffers.add(classBuffer);
    }

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: type=lint');
    buffer.writeln(
        "import 'package:freezed_annotation/freezed_annotation.dart';");
    if (needsEnumImport) {
      buffer.writeln("import '${resolveGeneratedImport(
        packageName: packageName,
        generatedDir: generatedDir,
        targetSubDir: 'enums',
        targetFile: 'enums.dart',
        fromSubDir: 'inputs',
      )}';");
    }
    buffer.writeln();
    buffer.writeln("part 'inputs.freezed.dart';");
    buffer.writeln("part 'inputs.g.dart';");
    buffer.writeln();
    for (final classBuffer in classBuffers) {
      buffer.write(classBuffer);
    }

    return {'inputs/inputs.dart': buffer.toString()};
  }
```

- [ ] **Step 5: Replace `generateObjectTypes`**

Replace the entire function (lines 170–267):

```dart
  static Map<String, String> generateObjectTypes(
    List<ObjectTypeDefinitionNode> objects,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    final result = <String, String>{};
    final modelExports = <String>[];

    for (final obj in objects) {
      if (obj.name.value == 'Query' ||
          obj.name.value == 'Mutation' ||
          obj.name.value == 'Subscription') {
        continue;
      }

      final rawName = obj.name.value;
      final className = '${rawName.pascalCase}Model';
      final fileName = '${rawName.snakeCase}_model.dart';
      final buffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      var needsEnumImport = false;
      var needsInputImport = false;
      var needsModelImport = false;
      for (final field in obj.fields) {
        final rawFieldName = field.name.value;
        final typeInfo = parseFieldType(field.type,
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
            customScalars: customScalars);
        fields[rawFieldName] = typeInfo;
        final baseType = _unwrapDartType(typeInfo.dartType);
        if (enumNames.contains(baseType)) needsEnumImport = true;
        if (inputNames.contains(baseType)) needsInputImport = true;
        if (baseType.endsWith('Model') && baseType != className)
          needsModelImport = true;
      }

      buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      buffer.writeln('// ignore_for_file: type=lint');
      buffer.writeln(
          "import 'package:freezed_annotation/freezed_annotation.dart';");
      if (needsModelImport) {
        buffer.writeln("import '${resolveGeneratedImport(
          packageName: packageName,
          generatedDir: generatedDir,
          targetSubDir: 'models',
          targetFile: 'models.dart',
          fromSubDir: 'models',
        )}';");
      }
      if (needsEnumImport) {
        buffer.writeln("import '${resolveGeneratedImport(
          packageName: packageName,
          generatedDir: generatedDir,
          targetSubDir: 'enums',
          targetFile: 'enums.dart',
          fromSubDir: 'models',
        )}';");
      }
      if (needsInputImport) {
        buffer.writeln("import '${resolveGeneratedImport(
          packageName: packageName,
          generatedDir: generatedDir,
          targetSubDir: 'inputs',
          targetFile: 'inputs.dart',
          fromSubDir: 'models',
        )}';");
      }
      buffer.writeln();
      buffer.writeln("part '${rawName.snakeCase}_model.freezed.dart';");
      buffer.writeln("part '${rawName.snakeCase}_model.g.dart';");
      buffer.writeln();

      _generateFreezedClass(
          className: className, fields: fields, buffer: buffer);

      result['models/$fileName'] = buffer.toString();
      modelExports.add("export '$fileName';");
    }

    if (modelExports.isNotEmpty) {
      final barrelBuffer = StringBuffer();
      barrelBuffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
      barrelBuffer.writeln('// ignore_for_file: type=lint');
      for (final exp in modelExports) {
        barrelBuffer.writeln(exp);
      }
      result['models/models.dart'] = barrelBuffer.toString();
    }

    return result;
  }
```

with:

```dart
  /// Every non-root (`Query`/`Mutation`/`Subscription` excluded) schema
  /// object type, declared inline in one `models/models.dart` with a single
  /// shared `part 'models.freezed.dart'; part 'models.g.dart';` pair — not
  /// one file per type plus a barrel of exports. Same rationale as
  /// [generateEnums]. A model referencing another model type — including
  /// itself, e.g. `type User { friend: User }` — needs no import at all
  /// now: every model lives in this same file, so the old
  /// `baseType != className` self-reference guard (and the whole
  /// models.dart-importing-itself case it guarded against) no longer
  /// applies to anything and is removed rather than kept as dead code.
  static Map<String, String> generateObjectTypes(
    List<ObjectTypeDefinitionNode> objects,
    Set<String> enumNames,
    Set<String> inputNames, {
    Set<String> scalarNames = const {},
    Map<String, String> customScalars = const {},
    String? packageName,
    String generatedDir = '',
  }) {
    final filtered = objects
        .where((o) =>
            o.name.value != 'Query' &&
            o.name.value != 'Mutation' &&
            o.name.value != 'Subscription')
        .toList();
    if (filtered.isEmpty) return const {};

    var needsEnumImport = false;
    var needsInputImport = false;
    final classBuffers = <StringBuffer>[];

    for (final obj in filtered) {
      final rawName = obj.name.value;
      final className = '${rawName.pascalCase}Model';
      final classBuffer = StringBuffer();

      final fields = <String, FieldTypeInfo>{};
      for (final field in obj.fields) {
        final rawFieldName = field.name.value;
        final typeInfo = parseFieldType(field.type,
            enumNames: enumNames,
            inputNames: inputNames,
            scalarNames: scalarNames,
            customScalars: customScalars);
        fields[rawFieldName] = typeInfo;
        final baseType = _unwrapDartType(typeInfo.dartType);
        if (enumNames.contains(baseType)) needsEnumImport = true;
        if (inputNames.contains(baseType)) needsInputImport = true;
      }

      _generateFreezedClass(
          className: className, fields: fields, buffer: classBuffer);
      classBuffers.add(classBuffer);
    }

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: type=lint');
    buffer.writeln(
        "import 'package:freezed_annotation/freezed_annotation.dart';");
    if (needsEnumImport) {
      buffer.writeln("import '${resolveGeneratedImport(
        packageName: packageName,
        generatedDir: generatedDir,
        targetSubDir: 'enums',
        targetFile: 'enums.dart',
        fromSubDir: 'models',
      )}';");
    }
    if (needsInputImport) {
      buffer.writeln("import '${resolveGeneratedImport(
        packageName: packageName,
        generatedDir: generatedDir,
        targetSubDir: 'inputs',
        targetFile: 'inputs.dart',
        fromSubDir: 'models',
      )}';");
    }
    buffer.writeln();
    buffer.writeln("part 'models.freezed.dart';");
    buffer.writeln("part 'models.g.dart';");
    buffer.writeln();
    for (final classBuffer in classBuffers) {
      buffer.write(classBuffer);
    }

    return {'models/models.dart': buffer.toString()};
  }
```

- [ ] **Step 6: Format, analyze, and run the full suite**

```bash
dart format lib test
dart analyze
rm -rf .dart_tool/mk_graphql_cache
dart test
```

Expected: `dart analyze` reports no issues. `dart test` — every test Task 1–3 touched should now **pass**, *except* the `computeOutputPaths Tests` group's `'computes fast expected output paths for schema file without full code generation'` test (Task 2 Step 8) and Task 1's primary regression test's `computeOutputPaths`-derived half — `computeOutputPaths` itself hasn't been updated yet (Task 4), so it's still predicting per-type paths that no longer exist, which will show as `paths` not matching the new expectations. This is expected; do not attempt to fix it here.

- [ ] **Step 7: Commit**

```bash
git add packages/mk_graphql_generator/lib/src/generator/schema/schema_generator.dart packages/mk_graphql_generator/test/generator_test.dart
git commit -m "feat(generator): merge per-type enum/input/model files into one file per category"
```

---

### Task 4: Update `computeOutputPaths` to predict the same merged files

**Files:**
- Modify: `packages/mk_graphql_generator/lib/src/generator/orchestrator/generator_orchestrator.dart:799-826`

**Interfaces:**
- Consumes: `ParsedGraphQLDocument.parse(content)` (already used, unchanged) exposing `.enumTypes`, `.inputTypes`, `.objectTypes` (unchanged).
- Produces: `computeOutputPaths({required String content, required String inputPath, String? schemaPath, String? sharedDir}) -> List<String>` — same signature; for a schema file now returns at most 4 entries (`enums/enums.dart`, `inputs/inputs.dart`, `models/models.dart`, `{fileName}.gql.dart`, each `sharedPrefix`-qualified, each only when its category is non-empty) instead of one entry per type plus those 4.

- [ ] **Step 1: Replace the schema-file branch**

In `packages/mk_graphql_generator/lib/src/generator/orchestrator/generator_orchestrator.dart`, inside `computeOutputPaths`, replace:

```dart
    if (isSchemaFile) {
      if (parsed.enumTypes.isNotEmpty) {
        for (final e in parsed.enumTypes) {
          outputs
              .add('${sharedPrefix}enums/${e.name.value.snakeCase}_enum.dart');
        }
        outputs.add('${sharedPrefix}enums/enums.dart');
      }
      if (parsed.inputTypes.isNotEmpty) {
        for (final i in parsed.inputTypes) {
          outputs.add('${sharedPrefix}inputs/${i.name.value.snakeCase}.dart');
        }
        outputs.add('${sharedPrefix}inputs/inputs.dart');
      }
      final objectTypes = parsed.objectTypes
          .where((o) =>
              o.name.value != 'Query' &&
              o.name.value != 'Mutation' &&
              o.name.value != 'Subscription')
          .toList();
      if (objectTypes.isNotEmpty) {
        for (final o in objectTypes) {
          outputs.add(
              '${sharedPrefix}models/${o.name.value.snakeCase}_model.dart');
        }
        outputs.add('${sharedPrefix}models/models.dart');
      }
      outputs.add('${sharedPrefix}$fileName.gql.dart');
    } else {
```

with:

```dart
    if (isSchemaFile) {
      // One fixed path per category — never one per type — so this
      // schema file's declared build_runner outputs stop depending on how
      // many enums/inputs/objects it defines. See generateEnums/
      // generateInputs/generateObjectTypes in schema_generator.dart, which
      // this must keep matching exactly.
      if (parsed.enumTypes.isNotEmpty) {
        outputs.add('${sharedPrefix}enums/enums.dart');
      }
      if (parsed.inputTypes.isNotEmpty) {
        outputs.add('${sharedPrefix}inputs/inputs.dart');
      }
      final objectTypes = parsed.objectTypes.where((o) =>
          o.name.value != 'Query' &&
          o.name.value != 'Mutation' &&
          o.name.value != 'Subscription');
      if (objectTypes.isNotEmpty) {
        outputs.add('${sharedPrefix}models/models.dart');
      }
      outputs.add('${sharedPrefix}$fileName.gql.dart');
    } else {
```

- [ ] **Step 2: Format, analyze, and run the full suite**

```bash
cd packages/mk_graphql_generator
dart format lib test
dart analyze
rm -rf .dart_tool/mk_graphql_cache
dart test
```

Expected: `dart analyze` reports no issues. `dart test` — **every** test now passes, including Task 1's primary regression test (`declaredAtWatchStart.containsAll(bundle.files.keys)` is now `true`) and Task 2 Step 8's `hasLength(4)` assertion. If anything is still red, stop and re-read this task's diff against the failure before touching anything else.

- [ ] **Step 3: Commit**

```bash
git add packages/mk_graphql_generator/lib/src/generator/orchestrator/generator_orchestrator.dart
git commit -m "fix(generator): computeOutputPaths predicts the merged schema-level barrels"
```

---

### Task 5: Bump `GeneratorCache.version`

**Files:**
- Modify: `packages/mk_graphql_generator/lib/src/cache/generator_cache.dart:10`

**Interfaces:**
- Consumes: nothing new.
- Produces: `GeneratorCache.version` (a `static const String`, read by `computeKey(...)` to build the on-disk/in-memory cache fingerprint — unchanged usage elsewhere).

- [ ] **Step 1: Bump the version**

Replace:
```dart
  static const String version = 'v15';
```
with:
```dart
  static const String version = 'v16';
```

- [ ] **Step 2: Run the full suite**

```bash
cd packages/mk_graphql_generator
rm -rf .dart_tool/mk_graphql_cache
dart test
```

Expected: all tests still pass (nothing asserts the literal version string).

- [ ] **Step 3: Commit**

```bash
git add packages/mk_graphql_generator/lib/src/cache/generator_cache.dart
git commit -m "chore(generator): bump GeneratorCache to v16 for the barrel-file merge"
```

---

### Task 6: Update docs and add the CHANGELOG entry

**Files:**
- Modify: `docs/mk_graphql_generator/generated-output.md`
- Modify: `packages/mk_graphql_generator/CHANGELOG.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update the file-layout tree and its surrounding text in `docs/mk_graphql_generator/generated-output.md`**

Replace the fenced code block and the paragraph immediately after it (currently):

```
```
lib/graphql/
├── schema.graphql
├── operations.graphql
└── generated/
    ├── enums/
    │   ├── {enum}_enum.dart        # one per schema enum
    │   └── enums.dart              # barrel
    ├── inputs/
    │   ├── {input}.dart            # one per schema input type
    │   └── inputs.dart             # barrel
    ├── models/
    │   ├── {type}_model.dart       # one per schema object type (Query/Mutation/Subscription excluded)
    │   └── models.dart             # barrel
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

Every `.graphql`/`.gql` operations file gets its own `generated/{fileName}.gql.dart` barrel and `generated/{operationName}/` folders; the schema file gets the schema-wide `enums/`, `inputs/`, `models/`, and `fragments/` output (location controlled by [`shared_dir`](configuration.md#shared_dir)).
```

with:

```
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

Every `.graphql`/`.gql` operations file gets its own `generated/{fileName}.gql.dart` barrel and `generated/{operationName}/` folders; the schema file gets the schema-wide `enums/enums.dart`, `inputs/inputs.dart`, `models/models.dart`, and `fragments/fragments.dart` output (location controlled by [`shared_dir`](configuration.md#shared_dir)). Each of `enums.dart`/`inputs.dart`/`models.dart` holds every type in its category, not one file per type — this keeps the generator's declared build outputs for the schema file fixed regardless of how many types the schema defines, which matters for `dart run build_runner watch`: growing an already-populated category (adding a type to a schema that already has other enums/inputs/objects) no longer requires restarting `watch`. A category's *first* type appearing while `watch` is already running still does.
```

- [ ] **Step 2: Clarify the "What `models/models.dart` is for" section**

Replace:
```
The schema-wide `{Type}Model` classes are still generated (one per non-root object type in the schema) because [schema-driven operations](#schema-driven-operations) and any code you write by hand need a way to reference "the full shape of a `User`". They are simply never used to deserialize a hand-written operation's trimmed response.
```
with:
```
The schema-wide `{Type}Model` classes are still generated — one per non-root object type in the schema, all declared together in `models/models.dart` — because [schema-driven operations](#schema-driven-operations) and any code you write by hand need a way to reference "the full shape of a `User`". They are simply never used to deserialize a hand-written operation's trimmed response.
```

- [ ] **Step 3: Add the CHANGELOG entry**

In `packages/mk_graphql_generator/CHANGELOG.md`, add a new `## Unreleased` section at the very top (above the current `## 1.2.1-dev.2` heading):

```markdown
## Unreleased

- **Fix**: growing a schema (adding an `enum`/`input`/`type`) while `dart run build_runner watch` is already running could leave `generated/models/models.dart` and `generated/inputs/inputs.dart` missing export entries for types that genuinely exist on disk, breaking `json_serializable`'s type resolution for anything importing those barrels. Root cause: `buildExtensions` (which files build_runner will let the builder write) is computed once when the builder starts, by predicting one output file per schema type; a schema growing mid-`watch` produces a new per-type file build_runner never declared, aborting that build before the barrel got rewritten.
- **Breaking**: fixed by merging the schema-level per-type files into three fixed files — `enums/{type}_enum.dart` → `enums/enums.dart`, `inputs/{type}.dart` → `inputs/inputs.dart`, `models/{type}_model.dart` → `models/models.dart` — so the schema file's declared output set no longer depends on how many types it defines. Regenerate (`dart run build_runner build --delete-conflicting-outputs`) to pick this up; the generator's on-disk cache is automatically invalidated (`GeneratorCache` bumped to v16). Any app importing one of the old per-type file paths directly (rather than the barrel, which is what the README/docs have always shown) needs to switch to importing the barrel instead — e.g. `import 'generated/models/user_model.dart'` becomes `import 'generated/models/models.dart'`.
- **Known limitation, unchanged by this fix**: a schema's *first-ever* enum, input, or object type appearing while `watch` is already running still requires a restart — that category's file existence (not just its size) is still content-dependent. Adding a type to a category the schema already has does not.

```

- [ ] **Step 4: Commit**

```bash
git add docs/mk_graphql_generator/generated-output.md packages/mk_graphql_generator/CHANGELOG.md
git commit -m "docs(generator): document the merged barrel file layout"
```

---

## After this plan

This plan intentionally stops short of bumping `pubspec.yaml`'s version or retitling the CHANGELOG's `## Unreleased` heading — every prior release in this project (`dev.2`, `dev.4`, `dev.5`) was cut as an explicit, separate step the user asked for after reviewing the finished fix, not bundled into the implementation. Once this plan's tasks are reviewed and merged, the next step (only on request) is the same two-commit pattern used for those: bump `packages/mk_graphql_generator/pubspec.yaml`'s `version` to `1.2.1-dev.3`, retitle the CHANGELOG's `## Unreleased` to `## 1.2.1-dev.3`, run `dart pub publish --dry-run`, commit as `chore(release): prepare 1.2.1-dev.3 for mk_graphql_generator`, then tag `mk_graphql_generator-v1.2.1-dev.3`.
