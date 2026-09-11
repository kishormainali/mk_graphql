import 'dart:convert';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:http/http.dart' as http;

/// Terminating [Link] for executing HTTP POST GraphQL requests.
///
/// Supports standard JSON bodies and multipart file uploads
/// (GraphQL Multipart Request Spec).
class HttpLink extends Link {
  final Uri uri;
  final http.Client _client;
  final Map<String, String> defaultHeaders;

  HttpLink(
    String url, {
    http.Client? client,
    this.defaultHeaders = const {},
  })  : uri = Uri.parse(url),
        _client = client ?? http.Client();

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    try {
      final variablesMap = req.variables;

      // Check for file uploads (GraphQL Multipart Spec)
      final uploads = <String, http.MultipartFile>{};
      final cleanedVars = _extractMultipartFiles(variablesMap, '', uploads);

      final contextHeaders =
          req.context.entry<HttpLinkHeaders>()?.headers ?? const {};

      final headers = <String, String>{
        'Accept': 'application/json',
        ...defaultHeaders,
        ...contextHeaders,
      };

      http.Response httpResponse;

      if (uploads.isNotEmpty) {
        // Multipart request for file uploads
        final multipartReq = http.MultipartRequest('POST', uri);
        multipartReq.headers.addAll(headers);

        final operations = jsonEncode({
          'query': printNode(req.operation.document),
          'operationName': req.operation.operationName,
          'variables': cleanedVars,
        });

        multipartReq.fields['operations'] = operations;

        final map = <String, List<String>>{};
        int i = 0;
        uploads.forEach((path, file) {
          final key = i.toString();
          map[key] = [path];
          multipartReq.files.add(http.MultipartFile(
            key,
            file.finalize(),
            file.length,
            filename: file.filename,
            contentType: file.contentType,
          ));
          i++;
        });

        multipartReq.fields['map'] = jsonEncode(map);
        final streamedResponse = await _client.send(multipartReq);
        httpResponse = await http.Response.fromStream(streamedResponse);
      } else {
        headers['Content-Type'] = 'application/json';
        final body = jsonEncode({
          'query': printNode(req.operation.document),
          'operationName': req.operation.operationName,
          'variables': cleanedVars,
        });
        httpResponse = await _client.post(uri, headers: headers, body: body);
      }

      if (httpResponse.statusCode >= 400 && httpResponse.body.isEmpty) {
        throw ServerException(statusCode: httpResponse.statusCode);
      }

      final Map<String, dynamic> bodyJson =
          jsonDecode(httpResponse.body) as Map<String, dynamic>;

      yield Response(
        data: bodyJson['data'] as Map<String, dynamic>?,
        errors: (bodyJson['errors'] as List<dynamic>?)
            ?.map((e) => GraphQLError(
                  message: (e as Map<String, dynamic>)['message'] as String,
                ))
            .toList(),
        response: bodyJson,
      );
    } catch (e, stack) {
      if (e is LinkException) rethrow;
      throw ServerException(originalException: e, originalStackTrace: stack);
    }
  }

  dynamic _extractMultipartFiles(
    dynamic value,
    String path,
    Map<String, http.MultipartFile> uploads,
  ) {
    if (value is http.MultipartFile) {
      uploads['variables.$path'] = value;
      return null;
    } else if (value is Map) {
      final newMap = <String, dynamic>{};
      value.forEach((key, val) {
        final currentPath = path.isEmpty ? '$key' : '$path.$key';
        newMap[key as String] =
            _extractMultipartFiles(val, currentPath, uploads);
      });
      return newMap;
    } else if (value is List) {
      final newList = [];
      for (int i = 0; i < value.length; i++) {
        final currentPath = path.isEmpty ? '$i' : '$path.$i';
        newList.add(_extractMultipartFiles(value[i], currentPath, uploads));
      }
      return newList;
    }
    return value;
  }
}
