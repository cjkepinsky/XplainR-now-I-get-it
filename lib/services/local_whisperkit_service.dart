import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const defaultLocalWhisperKitEndpoint =
    'http://127.0.0.1:50060/v1/audio/transcriptions';
const defaultLocalWhisperKitModel = 'whisperkit';
const _defaultLocalWhisperKitPort = 50060;

final localWhisperKitServer = LocalWhisperKitServerManager();

class LocalWhisperKitServerManager {
  Process? _process;
  Future<void>? _startFuture;
  final StringBuffer _recentOutput = StringBuffer();

  bool get isManagedProcessRunning => _process != null;

  Future<void> ensureRunning({
    String interfaceLanguage = 'pl',
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final endpoint = Uri.parse(defaultLocalWhisperKitEndpoint);
    final host = endpoint.host.isEmpty ? '127.0.0.1' : endpoint.host;
    final port = endpoint.hasPort ? endpoint.port : _defaultLocalWhisperKitPort;

    if (await _isPortOpen(host, port)) return;

    final managedProcess = _process;
    if (managedProcess != null) {
      if (await _hasExited(managedProcess)) {
        _process = null;
      } else {
        final ready = await _waitForPortOrExit(
          managedProcess,
          host: host,
          port: port,
          timeout: timeout,
        );
        if (ready) return;
        throw Exception(
          interfaceLanguage == 'en'
              ? 'WhisperKit is still starting or downloading a model. Try again in a moment.'
              : 'WhisperKit nadal się uruchamia albo pobiera model. Spróbuj za chwilę.',
        );
      }
    }

    final pendingStart = _startFuture;
    if (pendingStart != null) {
      await pendingStart;
      return;
    }

    final startFuture = _startAndWait(
      host: host,
      port: port,
      timeout: timeout,
      interfaceLanguage: interfaceLanguage,
    );
    _startFuture = startFuture;
    try {
      await startFuture;
    } finally {
      if (identical(_startFuture, startFuture)) {
        _startFuture = null;
      }
    }
  }

  Future<void> stopManagedProcess() async {
    final process = _process;
    _process = null;
    if (process == null) return;

    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> _startAndWait({
    required String host,
    required int port,
    required Duration timeout,
    required String interfaceLanguage,
  }) async {
    Object? lastError;
    for (final executable in _candidateExecutables()) {
      try {
        final process = await Process.start(
          executable,
          ['serve', '--host', host, '--port', port.toString()],
        );
        _process = process;
        _captureOutput(process);

        final ready = await _waitForPortOrExit(
          process,
          host: host,
          port: port,
          timeout: timeout,
        );
        if (ready) return;

        lastError = _recentOutput.toString().trim();
        if (await _hasExited(process)) {
          _process = null;
          continue;
        }

        throw _WhisperKitStillStartingException(
          interfaceLanguage == 'en'
              ? 'WhisperKit is still starting or downloading a model. Try again in a moment.'
              : 'WhisperKit nadal się uruchamia albo pobiera model. Spróbuj za chwilę.',
        );
      } catch (error) {
        lastError = error;
        final process = _process;
        if (error is _WhisperKitStillStartingException) {
          rethrow;
        }
        if (process != null && !await _isPortOpen(host, port)) {
          if (await _hasExited(process)) {
            _process = null;
          } else {
            await stopManagedProcess();
          }
        }
      }
    }

    throw Exception(
      interfaceLanguage == 'en'
          ? 'Could not start whisperkit-cli serve on port $port. $lastError'
          : 'Nie udało się uruchomić whisperkit-cli serve na porcie $port. $lastError',
    );
  }

  List<String> _candidateExecutables() {
    final configured = Platform.environment['WHISPERKIT_CLI_PATH']?.trim();
    return [
      if (configured != null && configured.isNotEmpty) configured,
      'whisperkit-cli',
      '/opt/homebrew/bin/whisperkit-cli',
      '/usr/local/bin/whisperkit-cli',
      '/opt/homebrew/bin/argmax-cli',
      '/usr/local/bin/argmax-cli',
    ];
  }

  void _captureOutput(Process process) {
    void appendOutput(List<int> bytes) {
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isEmpty) return;
      if (_recentOutput.length > 4000) {
        _recentOutput.clear();
      }
      _recentOutput.writeln(text);
    }

    process.stdout.listen(appendOutput);
    process.stderr.listen(appendOutput);
    unawaited(
      process.exitCode.then((_) {
        if (identical(_process, process)) {
          _process = null;
        }
      }),
    );
  }

  Future<bool> _waitForPortOrExit(
    Process process, {
    required String host,
    required int port,
    required Duration timeout,
  }) async {
    final startedAt = DateTime.now();
    while (DateTime.now().difference(startedAt) < timeout) {
      if (await _isPortOpen(host, port)) return true;
      if (await _hasExited(process)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return await _isPortOpen(host, port);
  }

  Future<bool> _hasExited(Process process) async {
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 1));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> _isPortOpen(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _WhisperKitStillStartingException implements Exception {
  final String message;

  const _WhisperKitStillStartingException(this.message);

  @override
  String toString() => message;
}

Future<String> transcribeWithLocalWhisperKit(
  Uint8List wavBytes, {
  required String languageCode,
  String endpoint = defaultLocalWhisperKitEndpoint,
  String model = defaultLocalWhisperKitModel,
  String interfaceLanguage = 'pl',
}) async {
  if (wavBytes.isEmpty) return '';

  final request = http.MultipartRequest('POST', Uri.parse(endpoint))
    ..fields['model'] = model
    ..fields['response_format'] = 'json'
    ..fields['language'] = languageCode
    ..files.add(
      http.MultipartFile.fromBytes(
        'file',
        wavBytes,
        filename: 'xplainr-local-whisperkit.wav',
      ),
    );

  final streamedResponse =
      await request.send().timeout(const Duration(seconds: 45));
  final response = await http.Response.fromStream(streamedResponse);

  if (response.statusCode != 200) {
    final responseBody = response.body.length > 500
        ? '${response.body.substring(0, 500)}...'
        : response.body;
    throw Exception(
      interfaceLanguage == 'en'
          ? 'Local WhisperKit transcription failed: ${response.statusCode} $responseBody'
          : 'Lokalna transkrypcja WhisperKit nie powiodła się: ${response.statusCode} $responseBody',
    );
  }

  final trimmedBody = response.body.trim();
  if (trimmedBody.isEmpty) return '';

  try {
    final decoded = jsonDecode(trimmedBody);
    if (decoded is Map<String, dynamic>) {
      return (decoded['text'] as String? ?? '').trim();
    }
  } catch (_) {
    // Some local OpenAI-compatible servers return plain text despite JSON mode.
  }

  return trimmedBody;
}
