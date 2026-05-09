import 'dart:convert';
import 'dart:io';

import '../models/explanation_citation.dart';

class LocalExplanationRecord {
  final String term;
  final String? explanation;
  final String? error;
  final List<ExplanationCitation> citations;

  const LocalExplanationRecord({
    required this.term,
    this.explanation,
    this.error,
    this.citations = const [],
  });
}

class LocalSessionSnapshot {
  final Directory directory;
  final String transcription;
  final String sessionContext;
  final List<LocalExplanationRecord> explanations;
  final String project;

  const LocalSessionSnapshot({
    required this.directory,
    required this.transcription,
    required this.sessionContext,
    required this.explanations,
    required this.project,
  });
}

class LocalSessionSummary {
  final Directory directory;
  final DateTime startedAt;
  final String project;
  final String? customTitle;
  final String title;
  final String preview;

  const LocalSessionSummary({
    required this.directory,
    required this.startedAt,
    required this.project,
    this.customTitle,
    required this.title,
    required this.preview,
  });
}

class LocalAutoCorrectionRule {
  final String id;
  final String original;
  final String replacement;
  final bool enabled;
  final DateTime createdAt;

  const LocalAutoCorrectionRule({
    required this.id,
    required this.original,
    required this.replacement,
    required this.enabled,
    required this.createdAt,
  });

  LocalAutoCorrectionRule copyWith({
    String? replacement,
    bool? enabled,
  }) {
    return LocalAutoCorrectionRule(
      id: id,
      original: original,
      replacement: replacement ?? this.replacement,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'original': original,
      'replacement': replacement,
      'enabled': enabled,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  static LocalAutoCorrectionRule? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;

    final original = value['original'] as String?;
    final replacement = value['replacement'] as String?;
    if (original == null ||
        replacement == null ||
        original.trim().isEmpty ||
        replacement.trim().isEmpty) {
      return null;
    }

    final createdAt = DateTime.tryParse(value['createdAt'] as String? ?? '');
    return LocalAutoCorrectionRule(
      id: value['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      original: original.trim(),
      replacement: replacement.trim(),
      enabled: value['enabled'] as bool? ?? true,
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class LocalSessionService {
  static const defaultProject = 'Bez projektu';
  static const legacyAutoCorrectionsProject = 'Test Automation';

  Directory? _currentSessionDirectory;

  Directory? get currentSessionDirectory => _currentSessionDirectory;

  void clearCurrentSession() {
    _currentSessionDirectory = null;
  }

  Future<Directory> sessionsRoot() async {
    return _sessionsRoot();
  }

  Future<Directory> startNewSession({
    required String speechLanguage,
    required String answerLanguage,
    required String audioSource,
    String project = defaultProject,
  }) async {
    final now = DateTime.now();
    final root = await _sessionsRoot();
    final dayDirectory = Directory('${root.path}/${_formatDate(now)}');
    final sessionDirectory =
        Directory('${dayDirectory.path}/${_formatTime(now)}');

    await sessionDirectory.create(recursive: true);
    _currentSessionDirectory = sessionDirectory;

    await File('${sessionDirectory.path}/metadata.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'startedAt': now.toIso8601String(),
        'speechLanguage': speechLanguage,
        'answerLanguage': answerLanguage,
        'audioSource': audioSource,
        'project': project.trim().isEmpty ? defaultProject : project.trim(),
      }),
    );

    await File('${sessionDirectory.path}/transcription.txt').writeAsString('');
    await File('${sessionDirectory.path}/context.txt').writeAsString('');
    await File('${sessionDirectory.path}/explanations.jsonl').writeAsString('');
    return sessionDirectory;
  }

  Future<void> appendTranscriptSegment(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final directory = _currentSessionDirectory;
    if (directory == null) return;

    final file = File('${directory.path}/transcription.txt');
    await file.writeAsString('$trimmed\n\n', mode: FileMode.append);
  }

  Future<void> writeTranscriptSnapshot(String text) async {
    final directory = _currentSessionDirectory;
    if (directory == null) return;

    final file = File('${directory.path}/transcription.txt');
    await file.writeAsString(text.trimRight());
  }

  Future<void> writeSessionContext(String text) async {
    final directory = _currentSessionDirectory;
    if (directory == null) return;

    final file = File('${directory.path}/context.txt');
    await file.writeAsString(text.trimRight());
  }

  Future<void> appendExplanation({
    required String term,
    String? explanation,
    String? error,
    List<ExplanationCitation> citations = const [],
  }) async {
    final directory = _currentSessionDirectory;
    if (directory == null) return;

    final file = File('${directory.path}/explanations.jsonl');
    await file.writeAsString(
      '${jsonEncode({
            'createdAt': DateTime.now().toIso8601String(),
            'term': term,
            'explanation': explanation,
            'error': error,
            'citations':
                citations.map((citation) => citation.toJson()).toList(),
          })}\n',
      mode: FileMode.append,
    );
  }

  Future<LocalSessionSnapshot?> loadLatestSession() async {
    final summaries = await loadSessionSummaries();
    if (summaries.isEmpty) return null;
    return loadSession(summaries.first.directory);
  }

  Future<LocalSessionSnapshot> loadSession(Directory sessionDirectory) async {
    final transcriptionFile =
        File('${sessionDirectory.path}/transcription.txt');
    final contextFile = File('${sessionDirectory.path}/context.txt');
    final explanationsFile =
        File('${sessionDirectory.path}/explanations.jsonl');
    final metadata = await _readMetadata(sessionDirectory);
    final transcription = await transcriptionFile.exists()
        ? await transcriptionFile.readAsString()
        : '';
    final sessionContext =
        await contextFile.exists() ? await contextFile.readAsString() : '';
    final explanations = await _readExplanations(explanationsFile);

    _currentSessionDirectory = sessionDirectory;
    return LocalSessionSnapshot(
      directory: sessionDirectory,
      transcription: transcription.trimRight(),
      sessionContext: sessionContext.trimRight(),
      explanations: explanations,
      project: _projectFromMetadata(metadata),
    );
  }

  Future<List<LocalSessionSummary>> loadSessionSummaries() async {
    final root = await _sessionsRoot();
    if (!await root.exists()) return const [];

    final dayDirectories = await root
        .list()
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    if (dayDirectories.isEmpty) return const [];
    dayDirectories.sort((a, b) => b.path.compareTo(a.path));

    final summaries = <LocalSessionSummary>[];
    for (final dayDirectory in dayDirectories) {
      final sessionDirectories = await dayDirectory
          .list()
          .where((entity) => entity is Directory)
          .cast<Directory>()
          .toList();
      sessionDirectories.sort((a, b) => b.path.compareTo(a.path));

      for (final sessionDirectory in sessionDirectories) {
        final transcriptionFile =
            File('${sessionDirectory.path}/transcription.txt');
        final explanationsFile =
            File('${sessionDirectory.path}/explanations.jsonl');
        final metadata = await _readMetadata(sessionDirectory);
        final transcription = await transcriptionFile.exists()
            ? await transcriptionFile.readAsString()
            : '';
        final explanations = await _readExplanations(explanationsFile);

        if (transcription.trim().isNotEmpty || explanations.isNotEmpty) {
          summaries.add(
            LocalSessionSummary(
              directory: sessionDirectory,
              startedAt: _startedAtFromSession(sessionDirectory, metadata),
              project: _projectFromMetadata(metadata),
              customTitle: _customTitleFromMetadata(metadata),
              title:
                  _titleForSession(sessionDirectory, metadata, transcription),
              preview: _previewForSession(transcription, explanations),
            ),
          );
        }
      }
    }

    summaries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return summaries;
  }

  Future<List<String>> loadProjects(
      {List<LocalSessionSummary>? sessionSummaries}) async {
    final projects = <String>{defaultProject};
    final summaries = sessionSummaries ?? await loadSessionSummaries();
    for (final summary in summaries) {
      projects.add(summary.project);
    }

    final file = await _projectsFile();
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          for (final project in decoded) {
            if (project is String && project.trim().isNotEmpty) {
              projects.add(project.trim());
            }
          }
        }
      } catch (_) {
        // Ignore malformed project metadata; sessions still carry their project names.
      }
    }

    final sorted = projects.toList()..sort();
    sorted.remove(defaultProject);
    return [defaultProject, ...sorted];
  }

  Future<List<LocalAutoCorrectionRule>> loadAutoCorrections(
      String project) async {
    await _migrateLegacyAutoCorrectionsIfNeeded();

    try {
      final file = await _autoCorrectionsByProjectFile();
      if (!await file.exists()) return const [];

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const [];
      final projectRules = decoded[_projectName(project)];
      if (projectRules is! List) return const [];

      final rules = projectRules
          .map(LocalAutoCorrectionRule.fromJson)
          .whereType<LocalAutoCorrectionRule>()
          .toList();
      rules.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return rules;
    } catch (_) {
      return const [];
    }
  }

  Future<void> writeAutoCorrections(
    String project,
    List<LocalAutoCorrectionRule> rules,
  ) async {
    await _migrateLegacyAutoCorrectionsIfNeeded();

    final file = await _autoCorrectionsByProjectFile();
    final data = await _readAutoCorrectionsByProject(file);
    data[_projectName(project)] = rules.map((rule) => rule.toJson()).toList();

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
  }

  Future<void> createProject(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final projects = (await loadProjects()).toSet()..add(trimmed);
    await _writeProjects(projects.toList());
  }

  Future<void> setCurrentSessionProject(String project) async {
    final directory = _currentSessionDirectory;
    if (directory == null) return;
    await setSessionProject(directory, project);
  }

  Future<void> setSessionProject(
      Directory sessionDirectory, String project) async {
    final metadata = await _readMetadata(sessionDirectory);
    metadata['project'] =
        project.trim().isEmpty ? defaultProject : project.trim();
    final file = File('${sessionDirectory.path}/metadata.json');
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));

    final projects = (await loadProjects()).toSet()
      ..add(metadata['project'] as String);
    await _writeProjects(projects.toList());
  }

  Future<void> renameSession(Directory sessionDirectory, String title) async {
    final metadata = await _readMetadata(sessionDirectory);
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      metadata.remove('title');
    } else {
      metadata['title'] = trimmed;
    }

    final file = File('${sessionDirectory.path}/metadata.json');
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));
  }

  Future<Directory> moveSessionToTrash(Directory sessionDirectory) async {
    final trashDirectory = await _trashDirectory();
    final destination =
        await _trashDestinationFor(sessionDirectory, trashDirectory);
    final movedDirectory = await sessionDirectory.rename(destination.path);

    if (_currentSessionDirectory?.path == sessionDirectory.path) {
      _currentSessionDirectory = null;
    }

    return movedDirectory;
  }

  Future<Directory> moveProjectToTrash(String project) async {
    await _migrateLegacyAutoCorrectionsIfNeeded();

    final normalizedProject = _projectName(project);
    final trashDirectory = await _trashDirectory();
    final destination = await _trashProjectDestinationFor(
      normalizedProject,
      trashDirectory,
    );
    await destination.create(recursive: true);

    await File('${destination.path}/project.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'project': normalizedProject,
        'deletedAt': DateTime.now().toIso8601String(),
      }),
    );

    final autoCorrectionsFile = await _autoCorrectionsByProjectFile();
    final autoCorrections =
        await _readAutoCorrectionsByProject(autoCorrectionsFile);
    final projectAutoCorrections = autoCorrections.remove(normalizedProject);
    if (projectAutoCorrections != null) {
      await File('${destination.path}/autocorrections.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(projectAutoCorrections),
      );
      await autoCorrectionsFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(autoCorrections),
      );
    }

    final summaries = await loadSessionSummaries();
    final projectSummaries = summaries
        .where((summary) => summary.project == normalizedProject)
        .toList();
    final sessionsDestination = Directory('${destination.path}/sessions');

    for (final summary in projectSummaries) {
      final sessionDirectory = summary.directory;
      if (!await sessionDirectory.exists()) continue;

      final pathParts = sessionDirectory.path.split(Platform.pathSeparator);
      final sessionName = pathParts.isNotEmpty ? pathParts.last : 'session';
      final dayName = pathParts.length >= 2
          ? pathParts[pathParts.length - 2]
          : 'unknown-date';
      final dayDestination = Directory('${sessionsDestination.path}/$dayName');
      await dayDestination.create(recursive: true);
      final sessionDestination = await _uniqueDirectory(
        Directory('${dayDestination.path}/$sessionName'),
      );

      await sessionDirectory.rename(sessionDestination.path);
      if (_currentSessionDirectory?.path == sessionDirectory.path) {
        _currentSessionDirectory = null;
      }
    }

    await _removeProjectFromProjectsFile(normalizedProject);
    return destination;
  }

  Future<List<LocalExplanationRecord>> _readExplanations(File file) async {
    if (!await file.exists()) return const [];

    final records = <LocalExplanationRecord>[];
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) continue;
        records.add(
          LocalExplanationRecord(
            term: decoded['term'] as String? ?? '',
            explanation: decoded['explanation'] as String?,
            error: decoded['error'] as String?,
            citations: _readCitations(decoded['citations']),
          ),
        );
      } catch (_) {
        // Ignore a malformed line and keep the rest of the local history usable.
      }
    }

    return records.where((record) => record.term.trim().isNotEmpty).toList();
  }

  List<ExplanationCitation> _readCitations(Object? value) {
    if (value is! List) return const [];
    return value
        .map(ExplanationCitation.fromJson)
        .whereType<ExplanationCitation>()
        .toList();
  }

  Future<Directory> _sessionsRoot() async {
    final directory = Directory('${(await _appRoot()).path}/sessions');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<Directory> _appRoot() async {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final directory = Directory('$home/.xplainr');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> _autoCorrectionsFile() async {
    final root = await _appRoot();
    return File('${root.path}/autocorrections.json');
  }

  Future<File> _autoCorrectionsByProjectFile() async {
    final root = await _appRoot();
    return File('${root.path}/autocorrections-by-project.json');
  }

  Future<void> _migrateLegacyAutoCorrectionsIfNeeded() async {
    final targetFile = await _autoCorrectionsByProjectFile();
    if (await targetFile.exists()) return;

    final legacyFile = await _autoCorrectionsFile();
    if (!await legacyFile.exists()) return;

    final legacyRules = await _readAutoCorrectionRules(legacyFile);
    if (legacyRules.isEmpty) return;

    await targetFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        legacyAutoCorrectionsProject:
            legacyRules.map((rule) => rule.toJson()).toList(),
      }),
    );

    final projects = (await loadProjects()).toSet()
      ..add(legacyAutoCorrectionsProject);
    await _writeProjects(projects.toList());
  }

  Future<List<LocalAutoCorrectionRule>> _readAutoCorrectionRules(
      File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return decoded
          .map(LocalAutoCorrectionRule.fromJson)
          .whereType<LocalAutoCorrectionRule>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>> _readAutoCorrectionsByProject(File file) async {
    if (!await file.exists()) return <String, dynamic>{};

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Keep the app usable if the project dictionary is malformed.
    }
    return <String, dynamic>{};
  }

  Future<Directory> _trashDirectory() async {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final directory = Directory('$home/.Trash');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<Directory> _trashDestinationFor(
    Directory sessionDirectory,
    Directory trashDirectory,
  ) async {
    final parts = sessionDirectory.path.split(Platform.pathSeparator);
    final sessionName = parts.isNotEmpty ? parts.last : 'session';
    final dayName =
        parts.length >= 2 ? parts[parts.length - 2] : 'unknown-date';
    final baseName = 'XplainR-$dayName-$sessionName';

    var candidate = Directory('${trashDirectory.path}/$baseName');
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = Directory('${trashDirectory.path}/$baseName-$suffix');
      suffix += 1;
    }
    return candidate;
  }

  Future<Directory> _trashProjectDestinationFor(
    String project,
    Directory trashDirectory,
  ) async {
    final safeProject = _safeTrashName(project);
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return _uniqueDirectory(
      Directory(
          '${trashDirectory.path}/XplainR-project-$safeProject-$timestamp'),
    );
  }

  Future<Directory> _uniqueDirectory(Directory initialDirectory) async {
    var candidate = initialDirectory;
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = Directory('${initialDirectory.path}-$suffix');
      suffix += 1;
    }
    return candidate;
  }

  String _safeTrashName(String value) {
    final trimmed = value.trim().isEmpty ? 'project' : value.trim();
    return trimmed.replaceAll(RegExp(r'[/\\:]'), '_');
  }

  Future<File> _projectsFile() async {
    final root = await _sessionsRoot();
    return File('${root.path}/projects.json');
  }

  Future<void> _removeProjectFromProjectsFile(String project) async {
    final file = await _projectsFile();
    if (!await file.exists()) return;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      final normalizedProject = _projectName(project);
      final projects = decoded
          .whereType<String>()
          .where((item) => _projectName(item) != normalizedProject)
          .toList();
      await _writeProjects(projects);
    } catch (_) {
      // Ignore malformed project metadata; session metadata remains authoritative.
    }
  }

  Future<void> _writeProjects(List<String> projects) async {
    final normalized = projects
        .map((project) => project.trim())
        .where((project) => project.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    normalized.remove(defaultProject);
    await (await _projectsFile()).writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert([defaultProject, ...normalized]),
    );
  }

  Future<Map<String, dynamic>> _readMetadata(Directory sessionDirectory) async {
    final file = File('${sessionDirectory.path}/metadata.json');
    if (!await file.exists()) return <String, dynamic>{};

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Fall back to path-based metadata.
    }
    return <String, dynamic>{};
  }

  String _projectFromMetadata(Map<String, dynamic> metadata) {
    final project = metadata['project'] as String?;
    return _projectName(project);
  }

  String _projectName(String? project) {
    return project == null || project.trim().isEmpty
        ? defaultProject
        : project.trim();
  }

  String? _customTitleFromMetadata(Map<String, dynamic> metadata) {
    final title = metadata['title'] as String?;
    if (title == null || title.trim().isEmpty) return null;
    return title.trim();
  }

  DateTime _startedAtFromSession(
    Directory sessionDirectory,
    Map<String, dynamic> metadata,
  ) {
    final startedAt = metadata['startedAt'] as String?;
    if (startedAt != null) {
      final parsed = DateTime.tryParse(startedAt);
      if (parsed != null) return parsed;
    }

    final parts = sessionDirectory.path.split(Platform.pathSeparator);
    if (parts.length >= 2) {
      final date = parts[parts.length - 2];
      final time = parts.last.replaceAll('-', ':');
      final parsed = DateTime.tryParse('${date}T$time');
      if (parsed != null) return parsed;
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _titleForSession(
    Directory sessionDirectory,
    Map<String, dynamic> metadata,
    String transcription,
  ) {
    final customTitle = _customTitleFromMetadata(metadata);
    if (customTitle != null) return customTitle;

    final startedAt = _startedAtFromSession(sessionDirectory, metadata);
    final date = _formatDate(startedAt);
    final time = _formatTime(startedAt).replaceAll('-', ':');
    final firstWords = transcription
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .take(7)
        .join(' ');

    if (firstWords.isEmpty) return '$date $time';
    return firstWords.length > 52
        ? '${firstWords.substring(0, 52)}...'
        : firstWords;
  }

  String _previewForSession(
    String transcription,
    List<LocalExplanationRecord> explanations,
  ) {
    final preview = transcription.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (preview.isNotEmpty) {
      return preview.length > 120 ? '${preview.substring(0, 120)}...' : preview;
    }

    if (explanations.isNotEmpty) {
      return explanations.first.term;
    }

    return 'Pusta sesja';
  }

  String _formatDate(DateTime value) {
    return [
      value.year.toString().padLeft(4, '0'),
      value.month.toString().padLeft(2, '0'),
      value.day.toString().padLeft(2, '0'),
    ].join('-');
  }

  String _formatTime(DateTime value) {
    return [
      value.hour.toString().padLeft(2, '0'),
      value.minute.toString().padLeft(2, '0'),
      value.second.toString().padLeft(2, '0'),
    ].join('-');
  }
}
