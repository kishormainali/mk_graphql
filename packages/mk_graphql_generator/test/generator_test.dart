import 'package:test/test.dart';
import 'package:mk_graphql_generator/src/cache/generator_cache.dart';
import 'package:mk_graphql_generator/src/generator/orchestrator/generator_orchestrator.dart';

void main() {
  group('GeneratorOrchestrator Tests with Structured Folders & Extensions', () {
    test(
        'generates enums/, inputs/, models/, and operation directories for schema.graphql',
        () {
      const graphqlContent = '''
        enum UserRole {
          ADMIN
          USER
        }

        input UserFilterInput {
          search: String
          role: UserRole
        }

        type UserResponse {
          id: String!
          name: String!
        }

        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
            name
            email
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: graphqlContent,
        inputPath: 'schema.graphql',
      );

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

      // Verify Operation Vars, Model, & Request
      final varContent = bundle.files['generated/get_user/get_user_var.dart']!;
      expect(varContent, contains('@freezed'));
      expect(varContent, contains(r'GetUserVars with _$GetUserVars'));
      expect(varContent, contains('required String id'));

      final reqContent = bundle.files['generated/get_user/get_user_req.dart']!;
      expect(reqContent, contains('@freezed'));
      expect(
          reqContent,
          contains(
              'class GetUserReq extends GraphQLRequest<GetUserModel, GetUserVars>'));
      expect(reqContent, contains(r'with _$GetUserReq'));
      expect(reqContent, contains('CancelToken? cancelToken'));

      // Verify Root Barrel File & GraphQLClient Extension
      final barrelContent = bundle.files['generated/schema.gql.dart']!;
      expect(barrelContent, contains("export 'enums/enums.dart';"));
      expect(barrelContent, contains("export 'inputs/inputs.dart';"));
      expect(barrelContent, contains("export 'models/models.dart';"));
      expect(barrelContent, contains("export 'get_user/get_user.dart';"));
      expect(barrelContent,
          contains('extension SchemaGraphQLClientExtension on GraphQLClient'));
      expect(barrelContent, contains('Future<GetUserModel> getUser('));
      expect(barrelContent, contains('Stream<GetUserModel> getUserStream('));
    });

    test(
        'non-schema .graphql file in nested directory references shared schema code via relative imports',
        () {
      const schemaContent = '''
        type User {
          id: ID!
          name: String!
        }

        type Query {
          user(id: ID!): User
        }
      ''';

      const opContent = '''
        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
            name
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: opContent,
        inputPath: 'lib/features/auth/queries.graphql',
        schemaPath: 'lib/graphql/schema.graphql',
        schemaContent: schemaContent,
      );

      // Non-schema file should NOT generate enums/, inputs/, models/
      expect(bundle.files.keys, isNot(contains('generated/enums/enums.dart')));
      expect(
          bundle.files.keys, isNot(contains('generated/inputs/inputs.dart')));
      expect(
          bundle.files.keys, isNot(contains('generated/models/models.dart')));

      // Non-schema file MUST generate operation files
      expect(
          bundle.files.keys, contains('generated/get_user/get_user_var.dart'));
      expect(bundle.files.keys,
          contains('generated/get_user/get_user_model.dart'));
      expect(
          bundle.files.keys, contains('generated/get_user/get_user_req.dart'));
      expect(bundle.files.keys, contains('generated/queries.gql.dart'));

      // `user`'s selection gets its own operation-scoped class rather than
      // reusing the shared UserModel — the op model file needs no import of
      // the shared models barrel at all.
      final modelContent =
          bundle.files['generated/get_user/get_user_model.dart']!;
      expect(modelContent, contains('class GetUserUserModel'));
      expect(
          modelContent,
          isNot(contains(
              "import '../../../../graphql/generated/models/models.dart';")));

      // `id`/`name` are plain scalars, so the vars file needs no shared import.
      final varContent = bundle.files['generated/get_user/get_user_var.dart']!;
      expect(
          varContent,
          isNot(contains(
              "import '../../../../graphql/generated/models/models.dart';")));
    });

    test(
        'enum values are generated as camelCase Dart identifiers with @JsonValue preserving the wire name',
        () {
      const graphqlContent = '''
        enum UserRole {
          ADMIN_USER
          STANDARD_USER
        }

        type Query {
          role: UserRole
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: graphqlContent,
        inputPath: 'schema.graphql',
      );

      final enumContent = bundle.files['generated/enums/user_role_enum.dart']!;
      expect(enumContent, contains('@JsonValue("ADMIN_USER")'));
      expect(enumContent, contains('adminUser,'));
      expect(enumContent, contains('@JsonValue("STANDARD_USER")'));
      expect(enumContent, contains('standardUser,'));
      expect(enumContent, isNot(contains('ADMIN_USER,')));
      expect(enumContent, isNot(contains('STANDARD_USER,')));
    });

    test('.gql schema file produces the same structured output as .graphql',
        () {
      const graphqlContent = '''
        type UserResponse {
          id: String!
          name: String!
        }

        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: graphqlContent,
        inputPath: 'schema.gql',
      );

      expect(bundle.files.keys,
          contains('generated/models/user_response_model.dart'));
      expect(bundle.files.keys, contains('generated/models/models.dart'));
      expect(bundle.files.keys, contains('generated/schema.gql.dart'));
    });

    test('feature .gql file (not just .graphql) generates operation output',
        () {
      const opContent = '''
        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: opContent,
        inputPath: 'lib/features/auth/queries.gql',
        schemaPath: 'lib/graphql/schema.graphql',
      );

      expect(
          bundle.files.keys, contains('generated/get_user/get_user_req.dart'));
      expect(bundle.files.keys, contains('generated/queries.gql.dart'));
    });

    test(
        'feature file field types are resolved from the schema AST (enums resolved for real, never guessed)',
        () {
      const schemaContent = '''
        enum UserRole {
          ADMIN
          MEMBER
        }

        type User {
          id: ID!
          name: String!
          role: UserRole!
        }

        type Query {
          user(id: ID!): User
        }
      ''';

      const opContent = '''
        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
            name
            role
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: opContent,
        inputPath: 'lib/features/auth/queries.graphql',
        schemaPath: 'lib/graphql/schema.graphql',
        schemaContent: schemaContent,
      );

      // The root `user` field always gets its own operation-scoped class,
      // never the shared UserModel.
      final opModelContent =
          bundle.files['generated/get_user/get_user_model.dart']!;
      expect(opModelContent, contains('class GetUserUserModel'));
      expect(opModelContent, contains('GetUserUserModel? user'));
      // `role` should resolve to the real shared UserRole enum, not String.
      expect(opModelContent, contains('required UserRole role'));
      expect(opModelContent, isNot(contains('required String role')));

      final reqContent = bundle.files['generated/get_user/get_user_req.dart']!;
      expect(reqContent, contains('GetUserModel parseData'));
    });

    test(
        'generated model/input files only import enums/inputs/models barrels they actually reference',
        () {
      const graphqlContent = '''
        enum UserRole {
          ADMIN
          MEMBER
        }

        input AddressInput {
          street: String
        }

        type Address {
          street: String
        }

        type PlainThing {
          id: ID!
          label: String!
        }

        type UserResponse {
          id: String!
          role: UserRole!
          address: Address
        }

        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: graphqlContent,
        inputPath: 'schema.graphql',
      );

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

    test(
        'operation request files never import the shared enums/inputs/models barrels directly',
        () {
      const schemaContent = '''
        enum UserRole {
          ADMIN
          MEMBER
        }

        type User {
          id: ID!
          role: UserRole!
        }

        type Query {
          user(id: ID!): User
        }
      ''';

      const opContent = '''
        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
            role
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: opContent,
        inputPath: 'lib/features/auth/queries.graphql',
        schemaPath: 'lib/graphql/schema.graphql',
        schemaContent: schemaContent,
      );

      final reqContent = bundle.files['generated/get_user/get_user_req.dart']!;
      expect(reqContent, isNot(contains('enums.dart')));
      expect(reqContent, isNot(contains('inputs.dart')));
      expect(reqContent, isNot(contains('models.dart')));
      expect(
          reqContent, contains("import 'package:mk_graphql/mk_graphql.dart';"));
    });

    test(
        'emits package: imports instead of relative imports when packageName is provided',
        () {
      const schemaContent = '''
        enum UserRole {
          ADMIN
          MEMBER
        }

        type User {
          id: ID!
          role: UserRole!
        }

        type Query {
          user(id: ID!): User
        }
      ''';

      const opContent = '''
        query GetUser(\$id: ID!) {
          user(id: \$id) {
            id
            role
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: opContent,
        inputPath: 'lib/features/auth/queries.graphql',
        schemaPath: 'lib/graphql/schema.graphql',
        schemaContent: schemaContent,
        packageName: 'my_app',
      );

      // `user` gets its own operation-scoped class referencing the shared
      // UserRole enum, so the op model needs a package: import pointing at
      // the schema's generated enums barrel (never the models barrel).
      final modelContent =
          bundle.files['generated/get_user/get_user_model.dart']!;
      expect(modelContent, contains('class GetUserUserModel'));
      expect(
          modelContent,
          contains(
              "import 'package:my_app/graphql/generated/enums/enums.dart';"));
      expect(modelContent, isNot(contains('models/models.dart')));
      expect(modelContent, isNot(contains('../../')));

      // Same-directory files (req -> var/model) also use package: imports.
      final reqContent = bundle.files['generated/get_user/get_user_req.dart']!;
      expect(
          reqContent,
          contains(
              "import 'package:my_app/features/auth/generated/get_user/get_user_var.dart';"));
      expect(
          reqContent,
          contains(
              "import 'package:my_app/features/auth/generated/get_user/get_user_model.dart';"));

      // The root barrel's op-folder import and shared barrel exports also
      // use package: imports.
      final barrelContent = bundle.files['generated/queries.gql.dart']!;
      expect(
          barrelContent,
          contains(
              "import 'package:my_app/features/auth/generated/get_user/get_user.dart';"));
      expect(barrelContent, isNot(contains('../')));
    });

    test(
        'schema-level model/input files use package: imports for shared barrels when packageName is provided',
        () {
      const graphqlContent = '''
        enum UserRole {
          ADMIN
          MEMBER
        }

        type UserResponse {
          id: String!
          role: UserRole!
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: graphqlContent,
        inputPath: 'lib/graphql/schema.graphql',
        packageName: 'my_app',
      );

      final userModel =
          bundle.files['generated/models/user_response_model.dart']!;
      expect(
          userModel,
          contains(
              "import 'package:my_app/graphql/generated/enums/enums.dart';"));
      expect(userModel, isNot(contains("import '../")));
    });

    test('supports Upload scalar in operations and maps to MultipartFile', () {
      const schemaContent = '''
        scalar Upload

        type FilePayload {
          id: ID!
        }

        type Mutation {
          singleUpload(file: Upload!): FilePayload
        }
      ''';

      const opContent = '''
        mutation SingleUpload(\$file: Upload!) {
          singleUpload(file: \$file) {
            id
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: opContent,
        inputPath: 'lib/features/upload/upload.graphql',
        schemaPath: 'lib/graphql/schema.graphql',
        schemaContent: schemaContent,
      );

      final varContent =
          bundle.files['generated/single_upload/single_upload_var.dart']!;
      expect(varContent, contains('required MultipartFile file'));
    });

    test('generates CancelToken? in client extensions and schema utilities',
        () {
      const schemaContent = '''
        type User {
          id: ID!
          name: String!
        }

        type Query {
          currentUser: User
        }

        query GetMe {
          currentUser {
            id
            name
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schemaContent,
        inputPath: 'schema.graphql',
      );

      final rootBarrel = bundle.files['generated/schema.gql.dart']!;
      expect(rootBarrel, contains('CancelToken? cancelToken'));

      final reqFile = bundle.files['generated/get_me/get_me_req.dart']!;
      expect(reqFile, contains('CancelToken? cancelToken'));
    });

    test('respects custom schemaPath and sharedDir options', () {
      const schemaContent = '''
        enum Status {
          ACTIVE
          INACTIVE
        }

        type User {
          id: ID!
          status: Status!
        }

        type Query {
          user(id: ID!): User
        }
      ''';

      final schemaBundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schemaContent,
        inputPath: 'lib/api/custom_schema.graphql',
        schemaPath: 'lib/api/custom_schema.graphql',
        sharedDir: 'lib/shared/generated',
      );

      // Verify files are written to custom shared dir relative to input
      // inputPath: lib/api/custom_schema.graphql -> inputDir: lib/api
      // sharedDir: lib/shared/generated -> relative: ../shared/generated
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

      // Now verify a feature operation file imports from custom sharedDir
      const featureOp = '''
        query GetUserStatus(\$id: ID!) {
          user(id: \$id) {
            status
          }
        }
      ''';

      final featureBundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: featureOp,
        inputPath: 'lib/features/profile/status.graphql',
        schemaPath: 'lib/api/custom_schema.graphql',
        sharedDir: 'lib/shared/generated',
        schemaContent: schemaContent,
      );

      final varFile = featureBundle
          .files['generated/get_user_status/get_user_status_var.dart']!;
      expect(varFile, contains('@freezed'));

      final reqFile = featureBundle
          .files['generated/get_user_status/get_user_status_req.dart']!;
      expect(reqFile, contains('CancelToken? cancelToken'));

      final barrelFile = featureBundle.files['generated/status.gql.dart']!;
      // Should import and export from the shared directory!
      expect(barrelFile, contains('../../shared/generated/models/models.dart'));
      expect(barrelFile, contains('../../shared/generated/enums/enums.dart'));
    });

    test(
        'only generates for .graphql or .gql files and ignores other file extensions',
        () {
      const content = 'type User { id: ID! }';

      final dartBundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'lib/models/user.dart',
      );
      expect(dartBundle.files, isEmpty);

      final jsonBundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'lib/schema.json',
      );
      expect(jsonBundle.files, isEmpty);

      final txtBundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'readme.txt',
      );
      expect(txtBundle.files, isEmpty);
    });
  });

  group('Cached Generation Tests', () {
    setUp(() {
      GeneratorCache.clear();
    });

    tearDown(() {
      GeneratorCache.clear();
    });

    test(
        'caches generated bundle and reuses on subsequent calls with identical inputs',
        () {
      const content = '''
        type User {
          id: ID!
          name: String!
        }
        query GetUser {
          user { id }
        }
      ''';

      final bundle1 = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'lib/get_user.graphql',
      );

      final bundle2 = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'lib/get_user.graphql',
      );

      // Verify second call is returned from cache (identical instance or identical files)
      expect(identical(bundle1, bundle2), isTrue);
      expect(bundle2.files.keys, equals(bundle1.files.keys));
    });

    test('re-generates when input content or schema content changes', () {
      const content1 = '''
        type User { id: ID! }
      ''';
      const content2 = '''
        type User { id: ID! name: String! }
      ''';

      final bundle1 = GeneratorOrchestrator.generateForGraphQLFile(
        content: content1,
        inputPath: 'schema.graphql',
      );

      final bundle2 = GeneratorOrchestrator.generateForGraphQLFile(
        content: content2,
        inputPath: 'schema.graphql',
      );

      expect(identical(bundle1, bundle2), isFalse);
      expect(bundle1.files['generated/models/user_model.dart'],
          isNot(contains('name')));
      expect(
          bundle2.files['generated/models/user_model.dart'], contains('name'));
    });

    test('useCache: false bypasses cache', () {
      const content = '''
        type User { id: ID! }
      ''';

      final bundle1 = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'schema.graphql',
        useCache: false,
      );

      final bundle2 = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'schema.graphql',
        useCache: false,
      );

      expect(identical(bundle1, bundle2), isFalse);
    });

    test('disk cache restores bundle even after in-memory cache is cleared',
        () {
      const content = '''
        type User { id: ID! }
      ''';

      final key = GeneratorCache.computeKey(
        inputPath: 'schema.graphql',
        content: content,
      );

      final bundle1 = GeneratorOrchestrator.generateForGraphQLFile(
        content: content,
        inputPath: 'schema.graphql',
      );

      // Manually wipe memory cache only
      GeneratorCache.clearMemory();
      final cachedDisk = GeneratorCache.get(key);
      expect(cachedDisk, isNotNull);
      expect(cachedDisk!.files.keys, equals(bundle1.files.keys));
    });

    test('in-memory cache does not block generation when query fields change',
        () {
      const schema = '''
        type User {
          id: ID!
          name: String!
          email: String!
        }
        type Query {
          user: User
        }
      ''';

      const queryWithIdOnly = '''
        query GetUser {
          user {
            id
          }
        }
      ''';

      const queryWithIdNameEmail = '''
        query GetUser {
          user {
            id
            name
            email
          }
        }
      ''';

      // 1. Initial generation with id only
      final bundle1 = GeneratorOrchestrator.generateForGraphQLFile(
        content: queryWithIdOnly,
        inputPath: 'lib/features/user/get_user.graphql',
        schemaPath: 'lib/schema.graphql',
        schemaContent: schema,
      );

      final req1 = bundle1.files['generated/get_user/get_user_req.dart']!;
      expect(req1, contains('id'));
      expect(req1, isNot(contains('email')));

      // 2. Query fields change - in-memory cache MUST NOT block generation
      final bundle2 = GeneratorOrchestrator.generateForGraphQLFile(
        content: queryWithIdNameEmail,
        inputPath: 'lib/features/user/get_user.graphql',
        schemaPath: 'lib/schema.graphql',
        schemaContent: schema,
      );

      // Verify new bundle was produced and is not the old cached bundle
      expect(identical(bundle1, bundle2), isFalse);

      final req2 = bundle2.files['generated/get_user/get_user_req.dart']!;
      expect(req2, contains('id'));
      expect(req2, contains('name'));
      expect(req2, contains('email'));

      // 3. Second call with the modified query uses the updated in-memory cache
      final bundle2Cached = GeneratorOrchestrator.generateForGraphQLFile(
        content: queryWithIdNameEmail,
        inputPath: 'lib/features/user/get_user.graphql',
        schemaPath: 'lib/schema.graphql',
        schemaContent: schema,
      );
      expect(identical(bundle2, bundle2Cached), isTrue);

      // 4. Switching back to the original query resolves to original cached bundle without collision
      final bundle1Cached = GeneratorOrchestrator.generateForGraphQLFile(
        content: queryWithIdOnly,
        inputPath: 'lib/features/user/get_user.graphql',
        schemaPath: 'lib/schema.graphql',
        schemaContent: schema,
      );
      expect(identical(bundle1, bundle1Cached), isTrue);
      final req1Cached =
          bundle1Cached.files['generated/get_user/get_user_req.dart']!;
      expect(req1Cached, isNot(contains('email')));
    });

    test(
        'in-memory cache updates generated inline selection models when sub-fields change',
        () {
      const queryV1 = '''
        query Search {
          search {
            title
          }
        }
      ''';

      const queryV2 = '''
        query Search {
          search {
            title
            snippet
            url
          }
        }
      ''';

      final bundleV1 = GeneratorOrchestrator.generateForGraphQLFile(
        content: queryV1,
        inputPath: 'lib/features/search/search.graphql',
      );

      final modelV1 = bundleV1.files['generated/search/search_model.dart']!;
      expect(modelV1, contains('title'));
      expect(modelV1, isNot(contains('snippet')));
      expect(modelV1, isNot(contains('url')));

      // Modify fields in query
      final bundleV2 = GeneratorOrchestrator.generateForGraphQLFile(
        content: queryV2,
        inputPath: 'lib/features/search/search.graphql',
      );

      expect(identical(bundleV1, bundleV2), isFalse);

      final modelV2 = bundleV2.files['generated/search/search_model.dart']!;
      expect(modelV2, contains('title'));
      expect(modelV2, contains('snippet'));
      expect(modelV2, contains('url'));
    });
  });

  group('computeOutputPaths Tests', () {
    test(
        'computes fast expected output paths for schema file without full code generation',
        () {
      const schemaContent = '''
        enum Status { ACTIVE, INACTIVE }
        input CreateUserInput { name: String! }
        type User { id: ID! }
      ''';

      final paths = GeneratorOrchestrator.computeOutputPaths(
        content: schemaContent,
        inputPath: 'lib/schema.graphql',
        schemaPath: 'lib/schema.graphql',
      );

      expect(paths, contains('generated/enums/status_enum.dart'));
      expect(paths, contains('generated/enums/enums.dart'));
      expect(paths, contains('generated/inputs/create_user_input.dart'));
      expect(paths, contains('generated/inputs/inputs.dart'));
      expect(paths, contains('generated/models/user_model.dart'));
      expect(paths, contains('generated/models/models.dart'));
      expect(paths, contains('generated/schema.gql.dart'));
    });

    test('computes fast expected output paths for operation file', () {
      const opContent = '''
        query GetUser {
          user { id }
        }
        mutation UpdateUser {
          updateUser { id }
        }
      ''';

      final paths = GeneratorOrchestrator.computeOutputPaths(
        content: opContent,
        inputPath: 'lib/features/user/user_operations.graphql',
        schemaPath: 'lib/schema.graphql',
      );

      expect(paths, contains('generated/get_user/get_user_var.dart'));
      expect(paths, contains('generated/get_user/get_user_model.dart'));
      expect(paths, contains('generated/get_user/get_user_req.dart'));
      expect(paths, contains('generated/get_user/get_user.dart'));
      expect(paths, contains('generated/update_user/update_user_var.dart'));
      expect(paths, contains('generated/update_user/update_user_model.dart'));
      expect(paths, contains('generated/update_user/update_user_req.dart'));
      expect(paths, contains('generated/update_user/update_user.dart'));
      expect(paths, contains('generated/user_operations.gql.dart'));
    });

    test('returns empty set for non-graphql files', () {
      const content = 'type User { id: ID! }';

      final paths = GeneratorOrchestrator.computeOutputPaths(
        content: content,
        inputPath: 'lib/user.dart',
      );

      expect(paths, isEmpty);
    });
  });

  group('Shared vs Partial Models Tests', () {
    const schemaContent = '''
      type Country {
        code: ID!
        name: String!
        native: String!
        phone: String
        emoji: String!
      }

      type Query {
        countries: [Country!]!
        country(code: ID!): Country
      }
    ''';

    test('generates shared models with strict non-nullable fields', () {
      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: schemaContent,
        inputPath: 'lib/graphql/schema.graphql',
      );

      final countryModel = bundle.files['generated/models/country_model.dart']!;
      expect(countryModel, contains('required String code'));
      expect(countryModel, contains('required String name'));
      expect(countryModel, contains('required String native'));
      expect(countryModel, contains('String? phone'));
      expect(countryModel, contains('required String emoji'));
    });

    test(
        'generates an operation-scoped model when query selects partial required fields',
        () {
      const partialOp = '''
        query GetCountriesBasic {
          countries {
            code
            name
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: partialOp,
        inputPath: 'lib/graphql/operations.graphql',
        schemaContent: schemaContent,
        schemaPath: 'lib/graphql/schema.graphql',
      );

      final opModel = bundle.files[
          'generated/get_countries_basic/get_countries_basic_model.dart']!;
      // Should generate its own path-named class, not reuse/derive from
      // the shared CountryModel.
      expect(opModel, contains('class GetCountriesBasicCountriesModel'));
      expect(opModel, isNot(contains('CountryModel')));
      expect(opModel, isNot(contains('CountryPartialModel')));
      // Selected fields that are non-null in schema should remain non-null
      expect(opModel, contains('required String code'));
      expect(opModel, contains('required String name'));
      // Should NOT contain unselected fields
      expect(opModel, isNot(contains('emoji')));
      expect(opModel, isNot(contains('native')));

      // Verify copyWithRequest in req file
      final opReq = bundle
          .files['generated/get_countries_basic/get_countries_basic_req.dart']!;
      expect(opReq, contains('copyWithRequest'));

      // Verify refetch method in root operations extension
      final opExt = bundle.files['generated/operations.gql.dart']!;
      expect(opExt, contains('refetchGetCountriesBasic'));
    });

    test(
        'still generates its own operation-scoped model when query selects every required field',
        () {
      const fullOp = '''
        query GetCountriesFull {
          countries {
            code
            name
            native
            emoji
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: fullOp,
        inputPath: 'lib/graphql/operations.graphql',
        schemaContent: schemaContent,
        schemaPath: 'lib/graphql/schema.graphql',
      );

      final opModel = bundle
          .files['generated/get_countries_full/get_countries_full_model.dart']!;
      // Even though every required Country field is selected, the response
      // model is still scoped to this operation — never the shared
      // CountryModel, so a later query with different fields can't corrupt
      // this one.
      expect(opModel, contains('class GetCountriesFullCountriesModel'));
      expect(opModel, isNot(contains('CountryModel')));
      expect(opModel, isNot(contains('CountryPartialModel')));
    });

    test(
        'a fragment spread as the whole selection reuses one shared class across operations',
        () {
      const opsWithFragment = '''
        fragment CountryFields on Country {
          code
          name
        }

        query GetCountriesA {
          countries {
            ...CountryFields
          }
        }

        query GetCountriesB {
          countries {
            ...CountryFields
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: opsWithFragment,
        inputPath: 'lib/graphql/operations.graphql',
        schemaContent: schemaContent,
        schemaPath: 'lib/graphql/schema.graphql',
      );

      expect(bundle.files.keys, contains('generated/fragments/fragments.dart'));
      final fragmentsFile = bundle.files['generated/fragments/fragments.dart']!;
      expect(fragmentsFile, contains('class CountryFieldsFragment'));
      expect(fragmentsFile, contains('required String code'));
      expect(fragmentsFile, contains('required String name'));

      // Neither operation should generate its own inline class for
      // `countries` — both reuse CountryFieldsFragment.
      final modelA =
          bundle.files['generated/get_countries_a/get_countries_a_model.dart']!;
      final modelB =
          bundle.files['generated/get_countries_b/get_countries_b_model.dart']!;
      expect(modelA, contains('List<CountryFieldsFragment> countries'));
      expect(modelB, contains('List<CountryFieldsFragment> countries'));
      expect(modelA, isNot(contains('class GetCountriesACountriesModel')));
      expect(modelB, isNot(contains('class GetCountriesBCountriesModel')));

      // Both op model files import the shared fragments barrel.
      expect(modelA, contains("import '../fragments/fragments.dart';"));
      expect(modelB, contains("import '../fragments/fragments.dart';"));
    });

    test(
        'a fragment spread mixed with extra fields still flattens all fields (no silent drop)',
        () {
      const mixedOp = '''
        fragment CountryBase on Country {
          code
          name
        }

        query GetCountryDetails {
          country(code: "us") {
            ...CountryBase
            emoji
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: mixedOp,
        inputPath: 'lib/graphql/operations.graphql',
        schemaContent: schemaContent,
        schemaPath: 'lib/graphql/schema.graphql',
      );

      final opModel = bundle.files[
          'generated/get_country_details/get_country_details_model.dart']!;
      // Mixed selections flatten the fragment's fields into the
      // operation-scoped class rather than reusing the shared fragment
      // class outright.
      expect(opModel, contains('class GetCountryDetailsCountryModel'));
      expect(opModel, contains('required String code'));
      expect(opModel, contains('required String name'));
      expect(opModel, contains('required String emoji'));
    });
  });
}
