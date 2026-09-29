import 'package:flutter/foundation.dart';

enum _LogLevel {
  debug('DEBUG', '🐛', '\x1B[36m'),
  info('INFO', '💡', '\x1B[34m'),
  warning('WARNING', '⚠️', '\x1B[33m'),
  error('ERROR', '⛔', '\x1B[31m'),
  success('SUCCESS', '✅', '\x1B[32m');

  final String label;
  final String icon;
  final String colorCode;

  const _LogLevel(this.label, this.icon, this.colorCode);

  bool get canLogInProduction =>
      this == error || this == warning || this == info;
}

/// Internal console logger formatted with boxed borders and log levels.
class Logger {
  const Logger._();

  static const _topLine =
      '┌──────────────────────────────────────────────────────────────────────────────────────────';
  static const _divider =
      '├──────────────────────────────────────────────────────────────────────────────────────────';
  static const _bottomLine =
      '└──────────────────────────────────────────────────────────────────────────────────────────';
  static const _leftLine = '│  ';
  static const _resetCode = '\x1B[0m';

  static const _sensitiveKeys = {
    'password',
    'token',
    'accesstoken',
    'refreshtoken',
    'authorization',
    'secret',
    'apikey',
    'api_key',
    'privatekey',
    'private_key',
  };

  static void d(dynamic message, {String? tag}) =>
      _log(_LogLevel.debug, message, tag: tag);

  static void i(dynamic message, {String? tag}) =>
      _log(_LogLevel.info, message, tag: tag);

  static void w(dynamic message, {String? tag}) =>
      _log(_LogLevel.warning, message, tag: tag);

  static void s(dynamic message, {String? tag}) =>
      _log(_LogLevel.success, message, tag: tag);

  static void e(
    dynamic message, {
    Object? error,
    StackTrace? stackTrace,
    String? tag,
  }) => _log(
    _LogLevel.error,
    message,
    error: error,
    stackTrace: stackTrace,
    tag: tag,
  );

  /// Whether ANSI terminal color codes should be included.
  /// Defaults to `false` to ensure clean output in Flutter console and IDEs.
  static bool useAnsiColors = false;

  static String _colorCode(_LogLevel level) =>
      useAnsiColors ? level.colorCode : '';
  static String get _resetCodeStr => useAnsiColors ? _resetCode : '';

  static void boxed(List<String> messages, {String? tag, bool redact = false}) {
    if (kReleaseMode) return;

    final formattedTag = tag != null ? '[$tag]' : '';
    final timeStr = _formatTime(DateTime.now());
    final tagLine = '$_leftLine[INFO 💡] [$timeStr] $formattedTag';

    final outputLines = <String>[_topLine, tagLine, _divider];

    for (var i = 0; i < messages.length; i++) {
      final msg = redact ? _redactString(messages[i]) : messages[i];
      for (final line in msg.split('\n')) {
        outputLines.add('$_leftLine$line');
      }
      if (i < messages.length - 1) {
        outputLines.add(_divider);
      }
    }

    outputLines.add(_bottomLine);

    final color = _colorCode(_LogLevel.info);
    final reset = _resetCodeStr;
    final buffer = StringBuffer();
    for (var i = 0; i < outputLines.length; i++) {
      if (color.isNotEmpty) buffer.write(color);
      buffer.write(outputLines[i]);
      if (reset.isNotEmpty) buffer.write(reset);
      if (i < outputLines.length - 1) buffer.writeln();
    }
    debugPrint(buffer.toString());
  }

  static void _log(
    _LogLevel level,
    dynamic message, {
    Object? error,
    StackTrace? stackTrace,
    String? tag,
  }) {
    if (kReleaseMode && !level.canLogInProduction) return;

    final formattedTag = tag != null ? '[$tag]' : '';
    final timeStr = _formatTime(DateTime.now());
    final tagLine =
        '$_leftLine[${level.label} ${level.icon}] [$timeStr] $formattedTag';

    final errorLines = error?.toString().split('\n');
    final stackLines = stackTrace != null
        ? stackTrace
              .toString()
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .take(5)
              .toList()
        : null;

    final msgStr = message.toString();
    final messageLines = msgStr.split('\n').map((l) => '$_leftLine$l');

    final output = <String>[
      _topLine,
      tagLine,
      _divider,
      ...messageLines,
      if (errorLines != null) ...[
        _divider,
        ...errorLines.map((e) => '$_leftLine$e'),
      ],
      if (stackLines != null) ...[
        _divider,
        ...stackLines.map((s) => '$_leftLine$s'),
      ],
      _bottomLine,
    ];

    final color = _colorCode(level);
    final reset = _resetCodeStr;
    final buffer = StringBuffer();
    for (var i = 0; i < output.length; i++) {
      if (color.isNotEmpty) buffer.write(color);
      buffer.write(output[i]);
      if (reset.isNotEmpty) buffer.write(reset);
      if (i < output.length - 1) buffer.writeln();
    }
    debugPrint(buffer.toString());
  }

  static String _formatTime(DateTime time) {
    final year = time.year;
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour24 = time.hour;
    final hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24);
    final period = hour24 >= 12 ? 'PM' : 'AM';
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    final offset = time.timeZoneOffset;
    final offsetSign = offset.isNegative ? '-' : '+';
    final offsetHours = offset.inHours.abs().toString().padLeft(2, '0');
    final offsetMinutes = (offset.inMinutes.abs() % 60).toString().padLeft(
      2,
      '0',
    );

    return '$year-$month-$day ${hour12.toString().padLeft(2, '0')}:$minute:$second $period $offsetSign$offsetHours:$offsetMinutes';
  }

  static String _redactString(String input) {
    var result = input;
    for (final key in _sensitiveKeys) {
      result = result.replaceAllMapped(
        RegExp('"$key"\\s*:\\s*"[^"]*"', caseSensitive: false),
        (m) => '"$key": "******"',
      );
    }
    return result;
  }
}
