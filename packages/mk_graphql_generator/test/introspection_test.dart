import 'dart:io';

import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:mk_graphql_generator/src/introspection/build_yaml_helper.dart';
import 'package:mk_graphql_generator/src/introspection/introspection_to_sdl.dart';
import 'package:test/test.dart';

void main() {
  group('introspectionToSdl Tests', () {
    test('converts basic schema with Query, User, and Enum to valid SDL', () {
      final introspectionJson = {
        'data': {
          '__schema': {
            'queryType': {'name': 'Query'},
            'mutationType': null,
            'subscriptionType': null,
            'types': [
              {
                'kind': 'OBJECT',
                'name': 'Query',
                'description': 'Root query type',
                'fields': [
                  {
                    'name': 'user',
                    'description': 'Fetch a user',
                    'args': [
                      {
                        'name': 'id',
                        'description': 'User ID',
                        'type': {
                          'kind': 'NON_NULL',
                          'ofType': {'kind': 'SCALAR', 'name': 'ID'}
                        },
                        'defaultValue': null,
                      },
                      {
                        'name': 'limit',
                        'description': 'Page limit',
                        'type': {'kind': 'SCALAR', 'name': 'Int'},
                        'defaultValue': '20',
                      }
                    ],
                    'type': {'kind': 'OBJECT', 'name': 'User'},
                    'isDeprecated': false,
                  }
                ],
              },
              {
                'kind': 'OBJECT',
                'name': 'User',
                'fields': [
                  {
                    'name': 'id',
                    'type': {
                      'kind': 'NON_NULL',
                      'ofType': {'kind': 'SCALAR', 'name': 'ID'}
                    },
                    'isDeprecated': false,
                  },
                  {
                    'name': 'name',
                    'type': {
                      'kind': 'NON_NULL',
                      'ofType': {'kind': 'SCALAR', 'name': 'String'}
                    },
                    'isDeprecated': false,
                  },
                  {
                    'name': 'role',
                    'type': {'kind': 'ENUM', 'name': 'Role'},
                    'isDeprecated': false,
                  },
                  {
                    'name': 'oldField',
                    'type': {'kind': 'SCALAR', 'name': 'String'},
                    'isDeprecated': true,
                    'deprecationReason': 'Use name instead',
                  }
                ],
              },
              {
                'kind': 'ENUM',
                'name': 'Role',
                'enumValues': [
                  {'name': 'ADMIN', 'isDeprecated': false},
                  {
                    'name': 'USER',
                    'isDeprecated': true,
                    'deprecationReason': 'Legacy role'
                  }
                ],
              },
              {
                'kind': 'INPUT_OBJECT',
                'name': 'UserFilterInput',
                'inputFields': [
                  {
                    'name': 'search',
                    'type': {'kind': 'SCALAR', 'name': 'String'},
                    'defaultValue': '"guest"',
                  }
                ],
              },
              {
                'kind': 'SCALAR',
                'name': 'DateTime',
                'description': 'ISO date time',
              }
            ],
            'directives': []
          }
        }
      };

      final sdl = introspectionToSdl(introspectionJson);
      expect(sdl, isNotEmpty);

      // Verify the generated SDL can be parsed back into a DocumentNode by gql
      final doc = parseString(sdl);
      expect(doc.definitions, isNotEmpty);

      // Verify definitions
      final typeNames = doc.definitions
          .whereType<TypeDefinitionNode>()
          .map((d) => d.name.value)
          .toSet();

      expect(
          typeNames,
          containsAll(
              ['Query', 'User', 'Role', 'UserFilterInput', 'DateTime']));

      // Verify deprecated directive was emitted
      expect(sdl, contains('@deprecated(reason: "Use name instead")'));
      expect(sdl, contains('@deprecated(reason: "Legacy role")'));
      expect(sdl, contains('scalar DateTime'));
      expect(sdl, contains('enum Role'));
      expect(sdl, contains('input UserFilterInput'));
    });

    test(
        'ignores internal __ introspection types and standard built-in scalars',
        () {
      final introspectionJson = {
        '__schema': {
          'queryType': {'name': 'Query'},
          'types': [
            {'kind': 'SCALAR', 'name': 'String'},
            {'kind': 'SCALAR', 'name': 'Int'},
            {'kind': 'OBJECT', 'name': '__Schema'},
            {'kind': 'OBJECT', 'name': '__Type'},
            {
              'kind': 'OBJECT',
              'name': 'Query',
              'fields': [
                {
                  'name': 'ping',
                  'type': {'kind': 'SCALAR', 'name': 'String'}
                }
              ]
            }
          ]
        }
      };

      final sdl = introspectionToSdl(introspectionJson);
      expect(sdl, isNot(contains('__Schema')));
      expect(sdl, isNot(contains('__Type')));
      expect(sdl, isNot(contains('scalar String')));
      expect(sdl, contains('type Query'));
    });
  });

  group('build_yaml_helper Tests', () {
    test('extracts schema_path from targets with mk_graphql builder', () {
      const yaml = '''
targets:
  \$default:
    builders:
      mk_graphql_builder:
        options:
          schema_path: lib/graphql/schema.graphql
''';
      expect(
          parseSchemaPathFromYaml(yaml), equals('lib/graphql/schema.graphql'));
    });

    test('extracts schemaPath (camelCase) from targets', () {
      const yaml = '''
targets:
  \$default:
    builders:
      mk_graphql_generator:
        options:
          schemaPath: custom/path/schema.gql
''';
      expect(parseSchemaPathFromYaml(yaml), equals('custom/path/schema.gql'));
    });

    test('extracts schema_path from global_options if targets is absent', () {
      const yaml = '''
global_options:
  mk_graphql_builder:
    options:
      schema_path: assets/schema.graphql
''';
      expect(parseSchemaPathFromYaml(yaml), equals('assets/schema.graphql'));
    });

    test('prioritizes mk_graphql builder over generic builder', () {
      const yaml = '''
targets:
  \$default:
    builders:
      other_builder:
        options:
          schema_path: other/schema.graphql
      mk_graphql_builder:
        options:
          schema_path: correct/schema.graphql
''';
      expect(parseSchemaPathFromYaml(yaml), equals('correct/schema.graphql'));
    });

    test('returns null when schema_path is missing or empty', () {
      const yaml = '''
targets:
  \$default:
    builders:
      mk_graphql_builder:
        options:
          output_dir: lib/generated
''';
      expect(parseSchemaPathFromYaml(yaml), isNull);
      expect(parseSchemaPathFromYaml('invalid: [yaml: :'), isNull);
    });

    test(
        'findSchemaPathFromBuildYaml reads from actual file or returns null if not found',
        () {
      expect(
          findSchemaPathFromBuildYaml(buildYamlPath: 'non_existent_file.yaml'),
          isNull);

      final tempDir = Directory.systemTemp.createTempSync('build_yaml_test_');
      final tempFile = File('${tempDir.path}/build.yaml');
      tempFile.writeAsStringSync('''
targets:
  \$default:
    builders:
      mk_graphql_builder:
        options:
          schema_path: lib/my_schema.graphql
''');

      try {
        final result =
            findSchemaPathFromBuildYaml(buildYamlPath: tempFile.path);
        expect(result, equals('lib/my_schema.graphql'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
