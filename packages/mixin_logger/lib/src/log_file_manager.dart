import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

abstract class LogFileManager {
  static LogFileManager? _instance;

  static LogFileManager? get instance => _instance ??= _fromOtherIsolate();

  static const _logPortName = 'one.mixin.logger.send_port';

  static LogFileManager? _fromOtherIsolate() {
    final sendPort = IsolateNameServer.lookupPortByName(_logPortName);
    if (sendPort == null) {
      debugPrint('[mixin_logger] no logger isolate found');
      return null;
    }
    return _LogFileMangerForOtherIsolate(sendPort);
  }

  static Future<void> init(
    String logDir,
    int maxFileCount,
    int maxFileLength, {
    String? fileLeading,
  }) async {
    final receiver = ReceivePort();
    await Isolate.spawn(
      _logIsolate,
      [
        receiver.sendPort,
        logDir,
        maxFileCount,
        maxFileLength,
        fileLeading,
      ],
    );
    final completer = Completer<void>();
    receiver.listen((message) {
      if (message is SendPort) {
        final sendPort = message;
        final removed = IsolateNameServer.removePortNameMapping(_logPortName);
        if (removed) {
          debugPrint(
              'Removed old logger isolate. this is ok if hot restarted app');
        }
        IsolateNameServer.registerPortWithName(sendPort, _logPortName);
        completer.complete();
      } else {
        assert(false, 'unknown message: $message');
      }
    });

    return completer.future;
  }

  static Future<void> _logIsolate(List<dynamic> args) async {
    final responsePort = args[0] as SendPort;
    final messageReceiver = ReceivePort();
    final dir = args[1] as String;
    final maxFileCount = args[2] as int;
    final maxFileLength = args[3] as int;
    final fileLeading = args[4] as String?;

    final logFileHandler = LogFileHandler(
      dir,
      maxFileCount: maxFileCount,
      maxFileLength: maxFileLength,
      fileLeading: fileLeading,
    );
    LogFileManager._instance = _LogFileManagerForLogIsolate(logFileHandler);
    messageReceiver.listen((message) {
      if (message is String) {
        logFileHandler.write(message);
      }
    });
    responsePort.send(messageReceiver.sendPort);
  }

  Future<void> write(String message);
}

class _LogFileMangerForOtherIsolate implements LogFileManager {
  _LogFileMangerForOtherIsolate(this._sendPort);

  final SendPort _sendPort;

  @override
  Future<void> write(String message) async {
    _sendPort.send(message);
  }
}

class _LogFileManagerForLogIsolate implements LogFileManager {
  _LogFileManagerForLogIsolate(this.handler);

  final LogFileHandler handler;

  @override
  Future<void> write(String message) {
    handler.write(message);
    return Future.value();
  }
}

final _fileNameRegex = RegExp(r'^log_\d+.log$');
final _fileNumberExtractRegex = RegExp(r'(?<=_)\d+(?=.log)');

String _generateFileName(int number) => 'log_$number.log';

class LogFileHandler {
  LogFileHandler(
    this.directory, {
    this.maxFileCount = 10,
    this.maxFileLength = 1024 * 1024 * 10, // 10 MB
    this.fileLeading,
  })  : assert(maxFileCount >= 1),
        assert(maxFileLength >= 0) {
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    } else if (!FileSystemEntity.isDirectorySync(directory)) {
      debugPrint('$directory is not a directory');
      return;
    }
    final files = dir
        .listSync(followLinks: false)
        .where((f) => f is File && _fileNameRegex.hasMatch(p.basename(f.path)))
        .map((e) {
          final number =
              _fileNumberExtractRegex.stringMatch(p.basename(e.path));
          assert(number != null, '${e.path} is not a log file');
          if (number == null) {
            return null;
          }
          final index = int.tryParse(number);
          assert(index != null, '${e.path} is not a log file');
          if (index == null) {
            return null;
          }
          return MapEntry(index, e as File);
        })
        .where((element) => element != null)
        .cast<MapEntry<int, File>>()
        .toList();
    this.files.addEntries(files);
    _prepareOutputFile();
  }

  void _prepareOutputFile() {
    final File outputFile;
    var newFileCreated = false;
    if (files.isEmpty) {
      final file = File(p.join(directory, _generateFileName(0)));
      files[0] = file;
      outputFile = file;
      newFileCreated = true;
    } else {
      final max = files.keys.reduce(math.max);
      final file = files[max];
      assert(file != null, '$max is not a valid file index');
      if (file != null && file.lengthSync() < maxFileLength) {
        outputFile = file;
      } else {
        final nextIndex = max + 1;
        final file = File(p.join(directory, _generateFileName(nextIndex)));
        files[nextIndex] = file;
        outputFile = file;
        newFileCreated = true;
      }
      if (files.length > maxFileCount) {
        final min = files.keys.reduce(math.min);
        final file = files[min];
        assert(file != null, '$min is not a valid file index');
        if (file != null) {
          file.deleteSync();
          files.remove(min);
        }
      }
    }
    try {
      outputFile.createSync();
    } catch (e) {
      debugPrint('Failed to create log file: $e');
      return;
    }
    _logFile = outputFile;
    _currentFileLength = outputFile.lengthSync();
    if (newFileCreated && fileLeading != null) {
      write(fileLeading!);
      write('\n');
    }
  }

  final String directory;

  File? _logFile;
  int _currentFileLength = 0;

  final Map<int, File> files = {};

  final int maxFileCount;

  final int maxFileLength;

  final String? fileLeading;

  void write(String message) {
    assert(_logFile != null, 'Log file is null');
    final bytes = utf8.encode('$message\n');
    _logFile!.writeAsBytesSync(bytes, mode: FileMode.append, flush: true);
    _currentFileLength += bytes.length;
    if (_currentFileLength > maxFileLength) {
      _prepareOutputFile();
    }
  }
}
