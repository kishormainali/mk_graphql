import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gql_exec/gql_exec.dart' as gql;
import 'package:gql_link/gql_link.dart';
import 'package:mk_graphql/mk_graphql.dart';

class _TestVars {
  final String email;
  const _TestVars(this.email);
  Map<String, dynamic> toJson() => {'email': email};
}

class _TestData {
  final String? id;
  const _TestData({this.id});
  factory _TestData.fromJson(Map<String, dynamic> json) =>
      _TestData(id: json['id'] as String?);
}

class _TestReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestReq(this.variables, {super.fetchPolicy});

  @override
  String get document =>
      'mutation CreateUser(\$email: String!) { createUser(email: \$email) { id } }';

  @override
  String get operationName => 'CreateUser';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) {
    return _TestReq(
      variables ?? this.variables,
      fetchPolicy: fetchPolicy ?? this.fetchPolicy,
    );
  }
}

class _MockErrorLink extends Link {
  final List<gql.GraphQLError> errors;
  const _MockErrorLink(this.errors);

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    yield gql.Response(errors: errors, response: const {});
  }
}

void main() {
  group('ValidationException tests', () {
    test('Apollo BAD_USER_INPUT with invalidArgs', () {
      final errors = [
        const GraphQLError(
          message: 'Invalid email address provided',
          extensions: {
            'code': 'BAD_USER_INPUT',
            'invalidArgs': ['email'],
          },
        ),
      ];

      final exception = GraphQLExceptionExtension.fromGraphQLErrors(errors);
      expect(exception, isA<ValidationException>());
      final valEx = exception as ValidationException;

      expect(valEx.hasError('email'), isTrue);
      expect(valEx.getFirstError('email'), 'Invalid email address provided');
      expect(valEx.fields, contains('email'));
      expect(valEx.allMessages, contains('Invalid email address provided'));
      expect(valEx.graphqlErrors, equals(errors));
    });

    test('Laravel Lighthouse validation category and map', () {
      final errors = [
        const GraphQLError(
          message: 'Validation failed for the given input.',
          extensions: {
            'category': 'validation',
            'validation': {
              'email': [
                'The email must be a valid email address.',
                'The email has already been taken.',
              ],
              'password': ['The password must be at least 8 characters.'],
            },
          },
        ),
      ];

      final exception = GraphQLExceptionExtension.fromGraphQLErrors(errors);
      expect(exception, isA<ValidationException>());
      final valEx = exception as ValidationException;

      expect(valEx.fields, containsAll(['email', 'password']));
      expect(valEx.getErrors('email').length, 2);
      expect(
        valEx.getFirstError('email'),
        'The email must be a valid email address.',
      );
      expect(
        valEx.getFirstError('password'),
        'The password must be at least 8 characters.',
      );
      expect(valEx.hasError('unknown'), isFalse);
      expect(valEx.getErrors('unknown'), isEmpty);
      expect(valEx.getFirstError('unknown'), isNull);
    });

    test('NestJS / class-validator validationErrors list', () {
      final errors = [
        const GraphQLError(
          message: 'Bad Request Exception',
          extensions: {
            'code': 'BAD_USER_INPUT',
            'validationErrors': [
              {
                'property': 'email',
                'constraints': {'isEmail': 'email must be an email'},
              },
              {
                'property': 'age',
                'constraints': {'min': 'age must not be less than 18'},
              },
            ],
          },
        ),
      ];

      final exception = GraphQLExceptionExtension.fromGraphQLErrors(errors);
      expect(exception, isA<ValidationException>());
      final valEx = exception as ValidationException;

      expect(valEx.fields, containsAll(['email', 'age']));
      expect(valEx.getFirstError('email'), 'email must be an email');
      expect(valEx.getFirstError('age'), 'age must not be less than 18');
    });

    test('GraphQL path-based validation errors with multiple errors', () {
      final errors = [
        const GraphQLError(
          message: 'Email is already taken',
          path: ['createUser', 'email'],
          extensions: {'code': 'GRAPHQL_VALIDATION_FAILED'},
        ),
        const GraphQLError(
          message: 'Password is too weak',
          path: ['createUser', 'password'],
          extensions: {'code': 'GRAPHQL_VALIDATION_FAILED'},
        ),
      ];

      final exception = GraphQLExceptionExtension.fromGraphQLErrors(errors);
      expect(exception, isA<ValidationException>());
      final valEx = exception as ValidationException;

      expect(valEx.hasError('email'), isTrue);
      expect(valEx.hasError('password'), isTrue);
      expect(valEx.getFirstError('email'), 'Email is already taken');
      expect(valEx.getFirstError('password'), 'Password is too weak');
      expect(valEx.allMessages.length, 2);
      expect(valEx.toString(), contains('ValidationException'));
      expect(valEx.toString(), contains('email: Email is already taken'));
    });

    test('ValidationException inherits from BadRequestException', () {
      final errors = [
        const GraphQLError(
          message: 'Validation failed',
          extensions: {'code': 'VALIDATION_FAILED'},
        ),
      ];

      final exception = GraphQLExceptionExtension.fromGraphQLErrors(errors);
      expect(exception, isA<BadRequestException>());
      expect(exception, isA<ValidationException>());
      expect(exception, isA<GraphQLException>());
    });

    test('GraphQLResponse validation helper getters', () {
      final responseWithErrors = GraphQLResponse<_TestData>(
        source: ResponseSource.network,
        errors: const [
          GraphQLError(
            message: 'Invalid input',
            extensions: {
              'code': 'BAD_USER_INPUT',
              'fieldErrors': {
                'username': ['Username is required'],
              },
            },
          ),
        ],
      );

      expect(responseWithErrors.hasErrors, isTrue);
      expect(responseWithErrors.hasValidationErrors, isTrue);
      expect(responseWithErrors.validationException, isNotNull);
      expect(
        responseWithErrors.validationErrors?['username']?.first,
        'Username is required',
      );

      const cleanResponse = GraphQLResponse<_TestData>(
        source: ResponseSource.network,
        data: _TestData(id: '123'),
      );
      expect(cleanResponse.hasErrors, isFalse);
      expect(cleanResponse.hasValidationErrors, isFalse);
      expect(cleanResponse.validationException, isNull);
      expect(cleanResponse.validationErrors, isNull);
    });

    test(
      'GraphQLClient.future throws ValidationException on validation failure',
      () async {
        final client = GraphQLClient.fromLink(
          const _MockErrorLink([
            gql.GraphQLError(
              message: 'Invalid email format',
              extensions: {'code': 'BAD_USER_INPUT', 'field': 'email'},
            ),
          ]),
        );

        expect(
          () => client.future(_TestReq(const _TestVars('invalid-email'))),
          throwsA(
            isA<ValidationException>()
                .having((e) => e.hasError('email'), 'hasError email', isTrue)
                .having(
                  (e) => e.getFirstError('email'),
                  'getFirstError email',
                  'Invalid email format',
                )
                .having(
                  (e) => e.graphqlErrors?.first.message,
                  'graphqlErrors',
                  'Invalid email format',
                ),
          ),
        );
      },
    );

    test('GraphQLClient.stream emits ValidationException on error', () async {
      final client = GraphQLClient.fromLink(
        const _MockErrorLink([
          gql.GraphQLError(
            message: 'Email must be unique',
            extensions: {
              'code': 'VALIDATION_FAILED',
              'validation': {
                'email': ['Email already taken'],
              },
            },
          ),
        ]),
      );

      expect(
        client.stream(_TestReq(const _TestVars('test@test.com'))),
        emitsError(
          isA<ValidationException>().having(
            (e) => e.getFirstError('email'),
            'email error',
            'Email already taken',
          ),
        ),
      );
    });
  });
}
