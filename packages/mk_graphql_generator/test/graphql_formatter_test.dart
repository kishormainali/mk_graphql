import 'package:gql/language.dart';
import 'package:mk_graphql_generator/src/formatter/graphql_formatter.dart';
import 'package:test/test.dart';

void main() {
  group('GraphQLFormatter Tests', () {
    test('formats object types with simple and complex argument fields', () {
      const source = '''
type Query {
  page(page: Int, perPage: Int): Page
  media(
    id: Int
    search: String
    type: MediaType
    sort: [MediaSort]
    genre: String
  ): [Media]
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('  page(page: Int, perPage: Int): Page'));
      expect(formatted, contains('  media('));
      expect(formatted, contains('    id: Int'));
      expect(formatted, contains('    search: String'));
      expect(formatted, contains('  ): [Media]'));

      // Round-trip parse
      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats field and argument descriptions properly', () {
      const source = '''
type Query {
  "Fetches single user"
  user(
    "The unique identifier"
    id: ID!
    "Include inactive users"
    includeInactive: Boolean = false
  ): User
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('  "Fetches single user"'));
      expect(formatted, contains('  user('));
      expect(formatted, contains('    "The unique identifier"'));
      expect(formatted, contains('    id: ID!'));
      expect(formatted, contains('    "Include inactive users"'));
      expect(formatted, contains('    includeInactive: Boolean = false'));
      expect(formatted, contains('  ): User'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats multiline block string descriptions', () {
      const source = '''
"""
This is a multiline
description for the type.
"""
type Media {
  id: Int!
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('"""'));
      expect(formatted, contains('This is a multiline'));
      expect(formatted, contains('description for the type.'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats enums with descriptions and deprecations', () {
      const source = '''
enum MediaStatus {
  "Has completed airing"
  FINISHED

  "Currently releasing"
  RELEASING

  "Deprecated status"
  CANCELLED @deprecated(reason: "Use NOT_YET_RELEASED instead")
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('enum MediaStatus {'));
      expect(formatted, contains('  "Has completed airing"'));
      expect(formatted, contains('  FINISHED'));
      expect(formatted, contains('  CANCELLED @deprecated(reason: "Use NOT_YET_RELEASED instead")'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats input objects with default values', () {
      const source = '''
input FilterInput {
  "Search query"
  search: String = "default"
  limit: Int = 10
  tags: [String] = ["action", "comedy"]
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('input FilterInput {'));
      expect(formatted, contains('  "Search query"'));
      expect(formatted, contains('  search: String = "default"'));
      expect(formatted, contains('  limit: Int = 10'));
      expect(formatted, contains('  tags: [String] = ["action", "comedy"]'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats interfaces and union types', () {
      const source = '''
interface Node {
  id: ID!
}

type User implements Node {
  id: ID!
  name: String!
}

union SearchResult = User | Page
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('interface Node {'));
      expect(formatted, contains('type User implements Node {'));
      expect(formatted, contains('union SearchResult = User | Page'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(3));
    });

    test('formats schema definition with custom roots', () {
      const source = '''
schema {
  query: RootQuery
  mutation: RootMutation
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('schema {'));
      expect(formatted, contains('  query: RootQuery'));
      expect(formatted, contains('  mutation: RootMutation'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats directive definitions', () {
      const source = '''
directive @cacheControl(
  maxAge: Int
  scope: String
) on FIELD_DEFINITION | OBJECT
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('directive @cacheControl('));
      expect(formatted, contains('on FIELD_DEFINITION | OBJECT'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats operations with variables and selection sets', () {
      const source = '''
query GetAnime(\$id: Int, \$type: MediaType) {
  Media(id: \$id, type: \$type) {
    id
    title {
      romaji
      english
    }
  }
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('query GetAnime(\$id: Int, \$type: MediaType) {'));
      expect(formatted, contains('  Media(id: \$id, type: \$type) {'));
      expect(formatted, contains('    id'));
      expect(formatted, contains('    title {'));
      expect(formatted, contains('      romaji'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });

    test('formats fragments', () {
      const source = '''
fragment MediaFields on Media {
  id
  title {
    romaji
  }
}
''';
      final formatted = formatGraphQLString(source);
      expect(formatted, contains('fragment MediaFields on Media {'));
      expect(formatted, contains('  id'));
      expect(formatted, contains('  title {'));
      expect(formatted, contains('    romaji'));

      final doc = parseString(formatted);
      expect(doc.definitions, hasLength(1));
    });
  });
}
