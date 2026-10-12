import 'package:dio/dio.dart' as dio;

/// Represents an uploaded file scalar in GraphQL operations.
///
/// Under the hood, this uses [dio.MultipartFile] to transmit file contents
/// adhering to the GraphQL Multipart Request Specification.
typedef Upload = dio.MultipartFile;

/// Custom scalar converters for standard & custom GraphQL scalar types.
class DateTimeScalarConverter {
  const DateTimeScalarConverter();

  /// Parses a server date and returns it in the device's local time zone.
  static DateTime fromJson(String json) => DateTime.parse(json).toLocal();

  /// Serializes a date as a UTC ISO-8601 string (with trailing `Z`).
  static String toJson(DateTime object) => object.toUtc().toIso8601String();
}

class JsonScalarConverter {
  const JsonScalarConverter();

  static Map<String, dynamic> fromJson(Map<String, dynamic> json) => json;
  static Map<String, dynamic> toJson(Map<String, dynamic> object) => object;
}

class BigIntScalarConverter {
  const BigIntScalarConverter();

  static BigInt fromJson(dynamic json) => BigInt.parse(json.toString());
  static String toJson(BigInt object) => object.toString();
}
