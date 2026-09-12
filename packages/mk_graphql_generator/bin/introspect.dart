import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:mk_graphql_generator/src/introspection/build_yaml_helper.dart';
import 'package:mk_graphql_generator/src/introspection/introspection_query.dart';
import 'package:mk_graphql_generator/src/introspection/introspection_to_sdl.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'url',
      abbr: 'u',
      help: 'The GraphQL endpoint URL to introspect (required).',
    )
    ..addOption(
      'output',
      abbr: 'o',
      help:
          'The output file path for the generated schema SDL (defaults to schema_path from build.yaml).',
    )
    ..addOption(
      'build-yaml',
      abbr: 'c',
      defaultsTo: 'build.yaml',
      help: 'Path to build.yaml configuration file.',
    )
    ..addMultiOption(
      'header',
      abbr: 'H',
      help:
          'Custom HTTP headers in "Key: Value" format (can be specified multiple times).',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show command usage instructions.',
    );

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error: ${e.toString()}\n');
    _printUsage(parser);
    exit(1);
  }

  if (results['help'] as bool || arguments.isEmpty) {
    _printUsage(parser);
    exit(0);
  }

  final urlString = results['url'] as String?;
  if (urlString == null || urlString.trim().isEmpty) {
    stderr.writeln('Error: Missing required option --url / -u.\n');
    _printUsage(parser);
    exit(1);
  }

  // Resolve output path:
  // 1. Explicit CLI argument --output / -o
  // 2. schema_path from build.yaml
  // 3. Fallback to existing schema file in lib/
  // 4. Default to 'lib/graphql/schema.graphql' or 'schema.graphql'
  String outputPath;
  if (results.wasParsed('output') &&
      (results['output'] as String).trim().isNotEmpty) {
    outputPath = (results['output'] as String).trim();
  } else {
    final buildYamlPath = results['build-yaml'] as String? ?? 'build.yaml';
    final fromBuildYaml =
        findSchemaPathFromBuildYaml(buildYamlPath: buildYamlPath);
    if (fromBuildYaml != null) {
      stdout.writeln('📋 Using schema path from $buildYamlPath: $fromBuildYaml');
      outputPath = fromBuildYaml;
    } else {
      final existing = _findExistingSchemaPath();
      if (existing != null) {
        stdout.writeln('📋 Using existing schema file: $existing');
        outputPath = existing;
      } else {
        outputPath = Directory('lib/graphql').existsSync()
            ? 'lib/graphql/schema.graphql'
            : 'schema.graphql';
      }
    }
  }

  final rawHeaders = results['header'] as List<String>;

  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  for (final raw in rawHeaders) {
    final colonIndex = raw.indexOf(':');
    if (colonIndex > 0) {
      final key = raw.substring(0, colonIndex).trim();
      final val = raw.substring(colonIndex + 1).trim();
      headers[key] = val;
    } else {
      stderr.writeln(
          'Warning: Ignoring header "$raw" (expected format "Key: Value")');
    }
  }

  stdout.writeln('🔍 Introspecting GraphQL schema from $urlString...');

  Uri uri;
  try {
    uri = Uri.parse(urlString);
  } catch (e) {
    stderr.writeln('Error: Invalid URL "$urlString": $e');
    exit(1);
  }

  final body = jsonEncode({
    'query': introspectionQuery,
    'operationName': 'IntrospectionQuery',
  });

  http.Response response;
  try {
    response = await http.post(uri, headers: headers, body: body);
  } catch (e) {
    stderr.writeln('❌ Failed to connect to $urlString: $e');
    exit(1);
  }

  if (response.statusCode != 200) {
    stderr.writeln(
        '❌ Introspection request failed with HTTP ${response.statusCode}:');
    stderr.writeln(response.body);
    exit(1);
  }

  Map<String, dynamic> responseJson;
  try {
    responseJson = jsonDecode(response.body) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('❌ Failed to parse response as JSON: $e');
    stderr.writeln('Response body: ${response.body}');
    exit(1);
  }

  if (responseJson.containsKey('errors') &&
      responseJson['errors'] != null &&
      (responseJson['errors'] as List).isNotEmpty) {
    stderr.writeln('❌ GraphQL errors encountered during introspection:');
    stderr.writeln(jsonEncode(responseJson['errors']));
    exit(1);
  }

  stdout.writeln('⚙️ Converting introspection schema to GraphQL SDL...');
  String sdl;
  try {
    sdl = introspectionToSdl(responseJson);
  } catch (e, st) {
    stderr.writeln('❌ Failed to convert introspection to SDL: $e\n$st');
    exit(1);
  }

  final outputFile = File(outputPath);
  try {
    outputFile.parent.createSync(recursive: true);
    outputFile.writeAsStringSync(sdl);
  } catch (e) {
    stderr.writeln('❌ Failed to write output file "$outputPath": $e');
    exit(1);
  }

  stdout.writeln(
      '✅ Successfully generated schema SDL (${sdl.length} bytes) at $outputPath');
}

String? _findExistingSchemaPath() {
  const candidates = [
    'lib/graphql/schema.graphql',
    'lib/graphql/schema.gql',
    'lib/schema.graphql',
    'lib/schema.gql',
    'schema.graphql',
    'schema.gql',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

void _printUsage(ArgParser parser) {
  stdout.writeln(
      'Usage: dart run mk_graphql_generator:introspect --url <URL> [options]');
  stdout.writeln('\nOptions:');
  stdout.writeln(parser.usage);
  stdout.writeln('\nExamples:');
  stdout.writeln(
      '  dart run mk_graphql_generator:introspect --url https://api.example.com/graphql');
  stdout.writeln(
      '  dart run mk_graphql_generator:introspect --url https://api.example.com/graphql -o lib/schema.graphql');
  stdout.writeln(
      '  dart run mk_graphql_generator:introspect --url https://graphql.anilist.co -H "Referer: https://anilist.co/graphiql"');
  stdout.writeln(
      '  dart run mk_graphql_generator:introspect -u https://api.example.com/graphql -c custom_build.yaml');
}

