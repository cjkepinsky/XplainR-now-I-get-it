import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import '../widgets/transcription_view.dart';
import '../widgets/explanation_history_view.dart';
import '../services/openai_service.dart';
import '../services/local_session_service.dart';

class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _SignalLevelIndicator extends StatelessWidget {
  final String label;
  final double level;

  const _SignalLevelIndicator({
    required this.label,
    required this.level,
  });

  @override
  Widget build(BuildContext context) {
    final roundedLevel = level.round().clamp(0, 100);
    final color = _signalColor(context, roundedLevel);

    return Tooltip(
      message: '$label: siła sygnału audio',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 58,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: roundedLevel / 100,
                minHeight: 6,
                color: color,
                backgroundColor: color.withOpacity(0.18),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 36,
            child: Text(
              '$roundedLevel%',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }

  Color _signalColor(BuildContext context, int level) {
    if (level < 20) return Theme.of(context).colorScheme.error;
    if (level < 45) return Colors.amber.shade700;
    return Colors.green.shade600;
  }
}

enum _TranscriptSource {
  microphone,
  systemAudio,
}

class _TranscriptLocation {
  final _TranscriptSource? source;
  final TextRange localRange;

  const _TranscriptLocation({
    required this.source,
    required this.localRange,
  });

  bool get isCommitted => source == null;
}

class _PartialCorrection {
  final String original;
  final String replacement;
  final List<String> beforeWords;
  final List<String> afterWords;

  const _PartialCorrection({
    required this.original,
    required this.replacement,
    required this.beforeWords,
    required this.afterWords,
  });
}

class _SessionAction {
  final bool rename;
  final bool delete;
  final String? project;

  const _SessionAction.rename()
      : rename = true,
        delete = false,
        project = null;

  const _SessionAction.delete()
      : rename = false,
        delete = true,
        project = null;

  const _SessionAction.move(this.project)
      : rename = false,
        delete = false;
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  final List<String> _transcriptionSegments = [];
  final List<ExplanationItem> _explanations = [];
  final List<LocalSessionSummary> _sessionSummaries = [];
  final List<LocalAutoCorrectionRule> _autoCorrectionRules = [];
  final List<String> _projects = [LocalSessionService.defaultProject];
  final List<_PartialCorrection> _microphonePartialCorrections = [];
  final List<_PartialCorrection> _systemAudioPartialCorrections = [];
  final TextEditingController _transcriptionController = TextEditingController();
  final TextEditingController _questionController = TextEditingController();
  final TextEditingController _sessionContextController = TextEditingController();
  final TextEditingController _explanationLengthController =
      TextEditingController(text: '300');
  String _partialMicrophoneTranscription = '';
  String _partialSystemAudioTranscription = '';
  SpeechToText _speechToText = SpeechToText();
  final LocalSessionService _sessionService = LocalSessionService();
  bool _speechEnabled = false;
  bool _isSystemAudioListening = false;
  bool _isAskingQuestion = false;
  String _selectedLocaleId = 'en_US';
  String _selectedAnswerLanguage = 'pl';
  String _selectedSource = 'microphone';
  String _selectedProject = LocalSessionService.defaultProject;
  String _currentSessionProject = LocalSessionService.defaultProject;
  String? _currentSessionPath;
  String? _statusMessage;
  StreamSubscription<dynamic>? _systemAudioSubscription;
  Timer? _signalLevelTimer;
  Timer? _transcriptionSaveDebounce;
  Timer? _preferenceSaveDebounce;
  Timer? _partialRenderDebounce;
  Timer? _sessionLibraryRefreshDebounce;
  Timer? _sessionContextSaveDebounce;
  bool _suppressTranscriptSnapshot = false;
  bool _suppressSessionContextSave = false;
  int _nextExplanationId = 1;
  int _explanationCharacterTarget = 300;
  double _sidebarWidth = 300;
  double _sidebarSessionFraction = 0.48;
  double _sidebarAutoCorrectionFraction = 0.56;
  double _transcriptionPanelFraction = 0.6;
  double _microphoneSignalRaw = 0;
  double _systemAudioSignalRaw = 0;
  double _microphoneSignalLevel = 0;
  double _systemAudioSignalLevel = 0;
  String _pendingPartialMicrophoneTranscription = '';
  String _pendingPartialSystemAudioTranscription = '';
  RegExp? _autoCorrectionMatcher;
  Map<String, String> _autoCorrectionReplacements = {};

  static const _systemAudioControl = MethodChannel('xplainr/system_audio_control');
  static const _systemAudioEvents = EventChannel('xplainr/system_audio_events');
  static const _visibleTranscriptWordLimit = 1500;

  String get _committedTranscription => _transcriptionController.text;
  String get _sessionContext => _sessionContextController.text.trim();

  String get _transcription {
    return [
      _committedTranscription,
      _partialMicrophoneTranscription,
      _partialSystemAudioTranscription,
    ].where((part) => part.trim().isNotEmpty).join('\n\n');
  }

  ({List<TranscriptDisplaySegment> segments, bool isTruncated}) get _visibleTranscript {
    final fullText = _transcription;
    if (fullText.trim().isEmpty) {
      return (segments: const <TranscriptDisplaySegment>[], isTruncated: false);
    }

    final tailStart = _tailStartForLastWords(fullText, _visibleTranscriptWordLimit);
    if (tailStart == 0) {
      return (
        segments: _displaySegmentsFromText(fullText, 0),
        isTruncated: false,
      );
    }

    var start = tailStart;
    while (start > 0 && fullText[start - 1] != '\n') {
      start -= 1;
    }
    while (start < fullText.length && fullText[start].trim().isEmpty) {
      start += 1;
    }

    return (
      segments: _displaySegmentsFromText(fullText.substring(start), start),
      isTruncated: true,
    );
  }

  int _tailStartForLastWords(String text, int wordLimit) {
    var wordsSeen = 0;
    var inWord = false;

    for (var index = text.length - 1; index >= 0; index -= 1) {
      final isWhitespace = text.codeUnitAt(index) <= 32;
      if (isWhitespace) {
        if (inWord) {
          wordsSeen += 1;
          if (wordsSeen >= wordLimit) return index + 1;
        }
        inWord = false;
      } else {
        inWord = true;
      }
    }

    return 0;
  }

  List<TranscriptDisplaySegment> _displaySegmentsFromText(
    String text,
    int baseOffset,
  ) {
    final matches = RegExp(r'[^\s](?:[\s\S]*?[^\s])?(?=\n{2,}|$)').allMatches(text);
    return matches
        .map(
          (match) => TranscriptDisplaySegment(
            text: match.group(0) ?? '',
            startOffset: baseOffset + match.start,
          ),
        )
        .where((segment) => segment.text.trim().isNotEmpty)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    print('Initializing speech...');
    _transcriptionController.addListener(_scheduleTranscriptSnapshotSave);
    _sessionContextController.addListener(_scheduleSessionContextSave);
    _loadSavedPreferences();
    _refreshSessionLibrary();
    _loadLatestLocalSession();
    _loadAutoCorrections();
    _startSignalLevelTimer();
    _initSpeech();
  }

  void _scheduleTranscriptSnapshotSave() {
    if (_suppressTranscriptSnapshot) return;

    _transcriptionSaveDebounce?.cancel();
    _transcriptionSaveDebounce = Timer(
      const Duration(milliseconds: 700),
      () => _sessionService.writeTranscriptSnapshot(_transcriptionController.text),
    );
  }

  void _scheduleSessionContextSave() {
    if (_suppressSessionContextSave) return;

    _sessionContextSaveDebounce?.cancel();
    _sessionContextSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => _sessionService.writeSessionContext(_sessionContextController.text),
    );
  }

  Future<void> _loadLatestLocalSession() async {
    final snapshot = await _sessionService.loadLatestSession();
    if (!mounted || snapshot == null) return;

    _applySessionSnapshot(snapshot);
    await _loadAutoCorrections(project: snapshot.project);
    await _refreshSessionLibrary();
  }

  Future<void> _refreshSessionLibrary() async {
    final summaries = await _sessionService.loadSessionSummaries();
    final projects = await _sessionService.loadProjects(sessionSummaries: summaries);
    if (!mounted) return;

    final previousProject = _selectedProject;
    setState(() {
      _projects
        ..clear()
        ..addAll(projects);
      _sessionSummaries
        ..clear()
        ..addAll(summaries);
      if (!_projects.contains(_selectedProject)) {
        _selectedProject = LocalSessionService.defaultProject;
      }
    });
    if (previousProject != _selectedProject) {
      await _loadAutoCorrections(project: _selectedProject);
    }
  }

  Future<void> _loadAutoCorrections({String? project}) async {
    final targetProject = project ?? _selectedProject;
    final rules = await _sessionService.loadAutoCorrections(targetProject);
    if (!mounted || targetProject != _selectedProject) return;

    setState(() {
      _autoCorrectionRules
        ..clear()
        ..addAll(rules);
      _rebuildAutoCorrectionMatcher();
    });
  }

  void _applySessionSnapshot(LocalSessionSnapshot snapshot) {
    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;
    _sessionContextSaveDebounce?.cancel();
    _sessionContextSaveDebounce = null;
    setState(() {
      _setVisibleTranscription(snapshot.transcription, persist: false);
      _setSessionContext(snapshot.sessionContext, persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _microphonePartialCorrections.clear();
      _systemAudioPartialCorrections.clear();
      _currentSessionPath = snapshot.directory.path;
      _currentSessionProject = snapshot.project;
      _selectedProject = snapshot.project;
      _transcriptionSegments
        ..clear()
        ..addAll(_segmentsFromTranscription(snapshot.transcription));
      _explanations
        ..clear()
        ..addAll(
          snapshot.explanations.reversed.map(
            (record) => ExplanationItem(
              id: _nextExplanationId++,
              term: record.term,
              explanation: record.explanation,
              error: record.error,
            ),
          ),
        );
      _statusMessage = 'Załadowano sesję: ${snapshot.directory.path}';
    });
  }

  void _clearLoadedSession({
    required String project,
    String? statusMessage,
  }) {
    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;
    _sessionContextSaveDebounce?.cancel();
    _sessionContextSaveDebounce = null;
    _sessionService.clearCurrentSession();

    setState(() {
      _setVisibleTranscription('', persist: false);
      _setSessionContext('', persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _transcriptionSegments.clear();
      _explanations.clear();
      _microphonePartialCorrections.clear();
      _systemAudioPartialCorrections.clear();
      _currentSessionPath = null;
      _currentSessionProject = project;
      _selectedProject = project;
      _statusMessage = statusMessage ?? 'Projekt nie ma jeszcze transkrypcji.';
    });
  }

  void _setSessionContext(String text, {bool persist = true}) {
    _suppressSessionContextSave = !persist;
    _sessionContextController.text = text;
    _suppressSessionContextSave = false;
    if (persist) {
      unawaited(_sessionService.writeSessionContext(text));
    }
  }

  List<String> _segmentsFromTranscription(String transcription) {
    return transcription
        .split(RegExp(r'\n{2,}'))
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
  }

  void _startSignalLevelTimer() {
    _signalLevelTimer?.cancel();
    _signalLevelTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _refreshSignalLevels(),
    );
  }

  void _refreshSignalLevels() {
    if (!mounted) return;

    final microphoneTarget = _speechToText.isListening ? _microphoneSignalRaw : 0.0;
    final systemTarget = _isSystemAudioListening ? _systemAudioSignalRaw : 0.0;

    setState(() {
      _microphoneSignalLevel = _smoothedLevel(_microphoneSignalLevel, microphoneTarget);
      _systemAudioSignalLevel = _smoothedLevel(_systemAudioSignalLevel, systemTarget);
    });
  }

  double _smoothedLevel(double current, double target) {
    if (target == 0 && current < 1) return 0;
    return (current * 0.55 + target * 0.45).clamp(0, 100).toDouble();
  }

  Future<void> _loadSavedPreferences() async {
    final settings = await getOpenAiSettings();
    if (!mounted) return;

    setState(() {
      _selectedLocaleId = settings.speechLanguage;
      _selectedAnswerLanguage = settings.answerLanguage;
      _selectedSource = settings.audioSource;
      _transcriptionPanelFraction =
          settings.transcriptionPanelFraction.clamp(0.25, 0.8);
      _sidebarWidth = settings.sidebarWidth.clamp(220, 520).toDouble();
      _sidebarSessionFraction =
          settings.sidebarSessionFraction.clamp(0.25, 0.75).toDouble();
      _sidebarAutoCorrectionFraction =
          settings.sidebarAutoCorrectionFraction.clamp(0.25, 0.75).toDouble();
      _explanationCharacterTarget =
          settings.explanationCharacterTarget.clamp(120, 2500).toInt();
      _explanationLengthController.text = _explanationCharacterTarget.toString();
    });
  }

  void _initSpeech() async {
    _speechToText = SpeechToText();
    bool available = await _speechToText.initialize(
      onStatus: (status) => print('onStatus: $status'),
      onError: (errorNotification) => print('onError: $errorNotification'),
    );
    print('Speech recognition available: $available');
    setState(() {
      _speechEnabled = available;
      _statusMessage = available
          ? 'Gotowe do transkrypcji z mikrofonu.'
          : 'Rozpoznawanie mowy nie jest dostępne.';
    });
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (result.finalResult) {
      setState(() {
        _commitPartialTranscript(
          result.recognizedWords,
          source: _TranscriptSource.microphone,
        );
      });
    } else {
      _updatePartialTranscript(
        result.recognizedWords,
        source: _TranscriptSource.microphone,
      );
    }
    print('Recognized words: ${result.recognizedWords}');
  }

  void _startListening() async {
    await _ensureActiveSession();

    if (_selectedSource == 'both') {
      await _startCombinedListening();
      return;
    }

    if (_selectedSource == 'system') {
      await _startSystemAudioListening();
      return;
    }

    await _startMicrophoneListening();
  }

  Future<void> _ensureActiveSession() async {
    if (_sessionService.currentSessionDirectory != null) {
      setState(() {
        _statusMessage =
            'Kontynuacja sesji: ${_sessionService.currentSessionDirectory!.path}';
      });
      return;
    }

    await _startNewLocalSession(project: _selectedProject);
  }

  Future<void> _startNewLocalSession({required String project}) async {
    final directory = await _sessionService.startNewSession(
      speechLanguage: _selectedLocaleId,
      answerLanguage: _selectedAnswerLanguage,
      audioSource: _selectedSource,
      project: project,
    );

    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;
    _sessionContextSaveDebounce?.cancel();
    _sessionContextSaveDebounce = null;
    setState(() {
      _setVisibleTranscription('', persist: false);
      _setSessionContext('', persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _transcriptionSegments.clear();
      _explanations.clear();
      _microphonePartialCorrections.clear();
      _systemAudioPartialCorrections.clear();
      _currentSessionPath = directory.path;
      _currentSessionProject = project;
      _selectedProject = project;
      _statusMessage = 'Sesja zapisywana w ${directory.path}';
    });
    await _loadAutoCorrections(project: project);
    await _refreshSessionLibrary();
  }

Future<void> _startMicrophoneListening({bool updateStatus = true}) async {
  print('Start microphone listening');
  if (updateStatus) {
    setState(() => _statusMessage = 'Nasłuchiwanie mikrofonu...');
  }
  await _speechToText.listen(
    onResult: _onSpeechResult,
    onSoundLevelChange: _handleMicrophoneSoundLevel,
    localeId: _selectedLocaleId,
    listenMode: ListenMode.dictation,
  );
  setState(() {});
}

void _stopListening() async {
  if (_selectedSource == 'both') {
    await _stopCombinedListening();
    return;
  }

  if (_selectedSource == 'system') {
    await _stopSystemAudioListening();
    return;
  }

  await _stopMicrophoneListening();
}

Future<void> _stopMicrophoneListening({bool updateStatus = true}) async {
  print('Stop microphone listening');
  await _speechToText.stop();
  setState(() {
    _commitPartialTranscript(
      '',
      source: _TranscriptSource.microphone,
    );
    _microphoneSignalRaw = 0;
    _microphoneSignalLevel = 0;
    if (updateStatus) {
      _statusMessage = 'Zatrzymano mikrofon.';
    }
  });
  if (updateStatus) {
    await _refreshSessionLibraryImmediately();
  }
}

  Future<void> _startCombinedListening() async {
    print('Start combined listening');
    setState(() => _statusMessage = 'Uruchamianie mikrofonu i audio systemowego...');

    try {
      await _startSystemAudioListening(updateStatus: false);
      await _startMicrophoneListening(updateStatus: false);
      setState(() => _statusMessage = 'Nasłuchiwanie mikrofonu i audio systemowego...');
    } catch (error) {
      setState(() => _statusMessage = 'Nie udało się uruchomić trybu łączonego: $error');
    }
  }

  Future<void> _stopCombinedListening() async {
    print('Stop combined listening');
    await _stopMicrophoneListening(updateStatus: false);
    await _stopSystemAudioListening(updateStatus: false);
    setState(() => _statusMessage = 'Zatrzymano mikrofon i audio systemowe.');
    await _refreshSessionLibraryImmediately();
  }

  Future<void> _startSystemAudioListening({bool updateStatus = true}) async {
    print('Start system audio listening');
    setState(() {
      _isSystemAudioListening = true;
      if (updateStatus) {
        _statusMessage = 'Uruchamianie przechwytywania audio systemowego...';
      }
    });

    await _systemAudioSubscription?.cancel();
    _systemAudioSubscription = _systemAudioEvents.receiveBroadcastStream().listen(
      _handleSystemAudioEvent,
      onError: (error) {
        setState(() {
          _isSystemAudioListening = false;
          _statusMessage = 'Błąd audio systemowego: $error';
        });
      },
    );

    try {
      await _systemAudioControl.invokeMethod('start', {
        'localeId': _selectedLocaleId,
      });
      if (updateStatus) {
        setState(() => _statusMessage = 'Nasłuchiwanie audio systemowego...');
      }
    } catch (error) {
      await _systemAudioSubscription?.cancel();
      _systemAudioSubscription = null;
      setState(() {
        _isSystemAudioListening = false;
        _statusMessage = 'Nie udało się uruchomić audio systemowego: $error';
      });
    }
  }

  Future<void> _stopSystemAudioListening({bool updateStatus = true}) async {
    print('Stop system audio listening');
    try {
      await _systemAudioControl.invokeMethod('stop');
    } finally {
      await _systemAudioSubscription?.cancel();
      _systemAudioSubscription = null;
      setState(() {
        _isSystemAudioListening = false;
        _commitPartialTranscript(
          '',
          source: _TranscriptSource.systemAudio,
        );
        _systemAudioSignalRaw = 0;
        _systemAudioSignalLevel = 0;
        if (updateStatus) {
          _statusMessage = 'Zatrzymano audio systemowe.';
        }
      });
      if (updateStatus) {
        await _refreshSessionLibraryImmediately();
      }
    }
  }

  void _handleSystemAudioEvent(dynamic event) {
    if (event is! Map) return;

    final type = event['type'];
    if (type == 'transcript') {
      final text = (event['text'] as String? ?? '').trim();
      final isFinal = event['final'] == true;
      if (isFinal) {
        setState(() {
          _commitPartialTranscript(
            text,
            source: _TranscriptSource.systemAudio,
          );
        });
      } else {
        _updatePartialTranscript(
          text,
          source: _TranscriptSource.systemAudio,
        );
      }
    } else if (type == 'status') {
      setState(() => _statusMessage = event['message'] as String?);
    } else if (type == 'error') {
      setState(() => _statusMessage = 'Błąd rozpoznawania: ${event['message']}');
    } else if (type == 'level') {
      final level = event['level'];
      if (level is num) {
        _systemAudioSignalRaw = level.toDouble().clamp(0, 100);
      }
    }
  }

  void _handleMicrophoneSoundLevel(double level) {
    final normalizedLevel = ((level + 60) / 60 * 100).clamp(0, 100).toDouble();
    _microphoneSignalRaw = normalizedLevel;
  }

  bool _appendTranscriptSegment(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    final committedText = _committedTranscription.trim();
    if (committedText.isNotEmpty &&
        _transcriptionSegments.isNotEmpty &&
        _transcriptionSegments.last == trimmed) {
      return false;
    }
    if (committedText.isNotEmpty &&
        _transcriptionSegments.isNotEmpty &&
        _isLikelySameSegment(_transcriptionSegments.last, trimmed)) {
      return false;
    }
    if (committedText.isNotEmpty && committedText.endsWith(trimmed)) return false;

    _transcriptionSegments.add(trimmed);
    _appendTranscriptToController(trimmed);
    unawaited(_sessionService.appendTranscriptSegment(trimmed));
    _scheduleSessionLibraryRefresh();
    return true;
  }

  void _scheduleSessionLibraryRefresh() {
    _sessionLibraryRefreshDebounce?.cancel();
    _sessionLibraryRefreshDebounce = Timer(const Duration(seconds: 3), () {
      _sessionLibraryRefreshDebounce = null;
      unawaited(_refreshSessionLibrary());
    });
  }

  Future<void> _refreshSessionLibraryImmediately() async {
    _sessionLibraryRefreshDebounce?.cancel();
    _sessionLibraryRefreshDebounce = null;
    await _refreshSessionLibrary();
  }

  bool _isLikelySameSegment(String previous, String next) {
    final previousWords = _normalizedWords(previous);
    final nextWords = _normalizedWords(next);
    if (previousWords.isEmpty || nextWords.isEmpty) return false;

    final minLength = previousWords.length < nextWords.length
        ? previousWords.length
        : nextWords.length;
    final maxLength = previousWords.length > nextWords.length
        ? previousWords.length
        : nextWords.length;
    final lengthRatio = minLength / maxLength;
    if (lengthRatio < 0.72) return false;

    final similarity = _wordSequenceSimilarity(previousWords, nextWords);
    return similarity >= 0.82;
  }

  List<String> _normalizedWords(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r"""[^\p{L}\p{N}\s]+""", unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
  }

  double _wordSequenceSimilarity(List<String> first, List<String> second) {
    final previousRow = List<int>.filled(second.length + 1, 0);
    final currentRow = List<int>.filled(second.length + 1, 0);

    for (var i = 1; i <= first.length; i += 1) {
      for (var j = 1; j <= second.length; j += 1) {
        if (first[i - 1] == second[j - 1]) {
          currentRow[j] = previousRow[j - 1] + 1;
        } else {
          currentRow[j] =
              previousRow[j] > currentRow[j - 1] ? previousRow[j] : currentRow[j - 1];
        }
      }
      for (var j = 0; j <= second.length; j += 1) {
        previousRow[j] = currentRow[j];
        currentRow[j] = 0;
      }
    }

    final longestCommonSubsequence = previousRow[second.length];
    final longestLength = first.length > second.length ? first.length : second.length;
    return longestCommonSubsequence / longestLength;
  }

  void _updatePartialTranscript(String text, {required _TranscriptSource source}) {
    final trimmed = _applyPartialCorrections(text.trim(), source);
    if (source == _TranscriptSource.microphone) {
      _pendingPartialMicrophoneTranscription = trimmed;
    } else {
      _pendingPartialSystemAudioTranscription = trimmed;
    }

    _partialRenderDebounce ??= Timer(
      const Duration(milliseconds: 250),
      _flushPendingPartialTranscripts,
    );
  }

  void _flushPendingPartialTranscripts() {
    _partialRenderDebounce = null;
    if (!mounted) return;

    setState(() {
      if (_pendingPartialMicrophoneTranscription.isNotEmpty ||
          _partialMicrophoneTranscription.isNotEmpty) {
        _partialMicrophoneTranscription = _pendingPartialMicrophoneTranscription;
      }
      if (_pendingPartialSystemAudioTranscription.isNotEmpty ||
          _partialSystemAudioTranscription.isNotEmpty) {
        _partialSystemAudioTranscription = _pendingPartialSystemAudioTranscription;
      }
    });
  }

  void _setPartialTranscriptImmediately(String text, _TranscriptSource source) {
    final trimmed = _applyPartialCorrections(text.trim(), source);
    if (source == _TranscriptSource.microphone) {
      _partialMicrophoneTranscription = trimmed;
      _pendingPartialMicrophoneTranscription = trimmed;
    } else {
      _partialSystemAudioTranscription = trimmed;
      _pendingPartialSystemAudioTranscription = trimmed;
    }
  }

  void _commitPartialTranscript(String text, {required _TranscriptSource source}) {
    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;

    final pendingText = source == _TranscriptSource.microphone
        ? _pendingPartialMicrophoneTranscription
        : _pendingPartialSystemAudioTranscription;
    final displayText = source == _TranscriptSource.microphone
        ? _partialMicrophoneTranscription
        : _partialSystemAudioTranscription;
    final rawText = text.trim().isNotEmpty ? text : pendingText;
    final trimmed =
        _applyPartialCorrections(rawText.trim().isNotEmpty ? rawText : displayText, source);
    if (trimmed.isEmpty) {
      if (source == _TranscriptSource.microphone) {
        _partialMicrophoneTranscription = '';
        _pendingPartialMicrophoneTranscription = '';
      } else {
        _partialSystemAudioTranscription = '';
        _pendingPartialSystemAudioTranscription = '';
      }
      return;
    }

    final appended = _appendTranscriptSegment(trimmed);
    if (!appended && _committedTranscription.trim().isEmpty) {
      return;
    }

    if (source == _TranscriptSource.microphone) {
      _partialMicrophoneTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _microphonePartialCorrections.clear();
    } else {
      _partialSystemAudioTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _systemAudioPartialCorrections.clear();
    }
  }

  String _applyPartialCorrections(String text, _TranscriptSource source) {
    var corrected = _applyAutoCorrections(text);
    for (final correction in _partialCorrectionsFor(source)) {
      corrected = _replaceOccurrence(
        corrected,
        correction.original,
        correction.replacement,
        correction.beforeWords,
        correction.afterWords,
      );
    }
    return corrected;
  }

  String _applyAutoCorrections(String text) {
    final matcher = _autoCorrectionMatcher;
    if (matcher == null || text.isEmpty) return text;

    return text.replaceAllMapped(matcher, (match) {
      final matchedText = match.group(0) ?? '';
      return _autoCorrectionReplacements[matchedText.toLowerCase()] ?? matchedText;
    });
  }

  List<_PartialCorrection> _partialCorrectionsFor(_TranscriptSource source) {
    return source == _TranscriptSource.microphone
        ? _microphonePartialCorrections
        : _systemAudioPartialCorrections;
  }

  String _replaceOccurrence(
    String text,
    String original,
    String replacement,
    List<String> beforeWords,
    List<String> afterWords,
  ) {
    if (original.isEmpty || original == replacement) {
      return text;
    }

    final candidates = RegExp(
      '(?<![\\p{L}\\p{N}])${RegExp.escape(original)}(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    ).allMatches(text).toList();
    if (candidates.isEmpty) return text;

    Match? bestMatch;
    var bestScore = -1;
    for (final candidate in candidates) {
      final score = _contextScore(
        text,
        candidate.start,
        candidate.end,
        beforeWords,
        afterWords,
      );
      if (score > bestScore) {
        bestScore = score;
        bestMatch = candidate;
      }
    }

    final match = bestMatch ?? candidates.first;
    return text.replaceRange(match.start, match.end, replacement);
  }

  bool _upsertAutoCorrection(String original, String replacement) {
    final normalizedOriginal = original.trim();
    final normalizedReplacement = replacement.trim();
    if (normalizedOriginal.isEmpty ||
        normalizedReplacement.isEmpty ||
        normalizedOriginal == normalizedReplacement) {
      return false;
    }

    final existingIndex = _autoCorrectionRules.indexWhere(
      (rule) => rule.original.toLowerCase() == normalizedOriginal.toLowerCase(),
    );

    if (existingIndex >= 0) {
      final existing = _autoCorrectionRules[existingIndex];
      if (existing.replacement == normalizedReplacement && existing.enabled) {
        return false;
      }
      _autoCorrectionRules[existingIndex] = existing.copyWith(
        replacement: normalizedReplacement,
        enabled: true,
      );
      _rebuildAutoCorrectionMatcher();
      return true;
    }

    _autoCorrectionRules.insert(
      0,
      LocalAutoCorrectionRule(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        original: normalizedOriginal,
        replacement: normalizedReplacement,
        enabled: true,
        createdAt: DateTime.now(),
      ),
    );
    _rebuildAutoCorrectionMatcher();
    return true;
  }

  void _rebuildAutoCorrectionMatcher() {
    final enabledRules = _autoCorrectionRules
        .where((rule) =>
            rule.enabled &&
            rule.original.trim().isNotEmpty &&
            rule.replacement.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => b.original.length.compareTo(a.original.length));

    _autoCorrectionReplacements = {
      for (final rule in enabledRules) rule.original.toLowerCase(): rule.replacement,
    };

    if (enabledRules.isEmpty) {
      _autoCorrectionMatcher = null;
      return;
    }

    final alternatives = enabledRules
        .map((rule) => RegExp.escape(rule.original))
        .join('|');
    _autoCorrectionMatcher = RegExp(
      '(?<![\\p{L}\\p{N}])(?:$alternatives)(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    );
  }

  void _persistAutoCorrections() {
    unawaited(
      _sessionService.writeAutoCorrections(
        _selectedProject,
        _autoCorrectionRules,
      ),
    );
  }

  void _toggleAutoCorrection(LocalAutoCorrectionRule rule, bool enabled) {
    final index = _autoCorrectionRules.indexWhere((item) => item.id == rule.id);
    if (index < 0) return;

    setState(() {
      _autoCorrectionRules[index] = _autoCorrectionRules[index].copyWith(
        enabled: enabled,
      );
      _rebuildAutoCorrectionMatcher();
      _statusMessage = enabled
          ? 'Włączono autokorektę: ${rule.original} -> ${rule.replacement}'
          : 'Wyłączono autokorektę: ${rule.original} -> ${rule.replacement}';
    });
    _persistAutoCorrections();
  }

  void _deleteAutoCorrection(LocalAutoCorrectionRule rule) {
    setState(() {
      _autoCorrectionRules.removeWhere((item) => item.id == rule.id);
      _rebuildAutoCorrectionMatcher();
      _statusMessage = 'Usunięto autokorektę: ${rule.original} -> ${rule.replacement}';
    });
    _persistAutoCorrections();
  }

  void _appendTranscriptToController(String text) {
    final oldValue = _transcriptionController.value;
    final oldText = oldValue.text;
    final separator = oldText.trim().isEmpty ? '' : '\n\n';
    final newText = '$oldText$separator$text';

    _setVisibleTranscription(newText, persist: false);
  }

  void _setVisibleTranscription(String text, {bool persist = true}) {
    _suppressTranscriptSnapshot = !persist;
    _transcriptionController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _suppressTranscriptSnapshot = false;
    if (persist) {
      _sessionService.writeTranscriptSnapshot(text);
    }
  }

  void _copyTranscription() {
    Clipboard.setData(ClipboardData(text: _transcription));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Transkrypcja skopiowana do schowka')),
    );
  }

  void _clearVisibleTranscription() {
    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;
    setState(() {
      _setVisibleTranscription('', persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _transcriptionSegments.clear();
      _microphonePartialCorrections.clear();
      _systemAudioPartialCorrections.clear();
      _statusMessage = 'Wyczyszczono transkrypcję z widoku. Pliki lokalne zostały.';
    });
  }

  Future<void> _openSessionsFolder() async {
    final directory = await _sessionService.sessionsRoot();
    await Process.run('open', [directory.path]);
  }

  void _copyStatusMessage() {
    final message = _statusMessage;
    if (message == null || message.trim().isEmpty) return;

    Clipboard.setData(ClipboardData(text: message));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Komunikat skopiowany do schowka')),
    );
  }

  Future<void> _saveCurrentPreferences() async {
    await saveAppPreferences(
      speechLanguage: _selectedLocaleId,
      answerLanguage: _selectedAnswerLanguage,
      audioSource: _selectedSource,
      transcriptionPanelFraction: _transcriptionPanelFraction,
      sidebarWidth: _sidebarWidth,
      sidebarSessionFraction: _sidebarSessionFraction,
      sidebarAutoCorrectionFraction: _sidebarAutoCorrectionFraction,
      explanationCharacterTarget: _explanationCharacterTarget,
    );
  }

  void _schedulePreferenceSave() {
    _preferenceSaveDebounce?.cancel();
    _preferenceSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      _saveCurrentPreferences,
    );
  }

  void _updateExplanationLength(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null) return;

    final clamped = parsed.clamp(120, 2500).toInt();
    setState(() => _explanationCharacterTarget = clamped);
    _schedulePreferenceSave();
  }

  Future<void> _loadSession(LocalSessionSummary summary) async {
    if (_isListening) {
      setState(() => _statusMessage = 'Zatrzymaj transkrypcję przed zmianą sesji.');
      return;
    }

    final snapshot = await _sessionService.loadSession(summary.directory);
    if (!mounted) return;
    _applySessionSnapshot(snapshot);
    await _loadAutoCorrections(project: snapshot.project);
    await _refreshSessionLibrary();
  }

  Future<void> _selectProject(String project) async {
    if (_isListening) {
      setState(() => _statusMessage = 'Zatrzymaj transkrypcję przed zmianą projektu.');
      return;
    }

    final targetProject = _projects.contains(project)
        ? project
        : LocalSessionService.defaultProject;
    setState(() => _selectedProject = targetProject);
    await _loadAutoCorrections(project: targetProject);

    final projectSessions = _sessionSummaries
        .where((summary) => summary.project == targetProject)
        .toList();
    if (projectSessions.isEmpty) {
      _clearLoadedSession(
        project: targetProject,
        statusMessage: 'Wybrany projekt nie ma jeszcze transkrypcji.',
      );
      return;
    }

    final snapshot = await _sessionService.loadSession(projectSessions.first.directory);
    if (!mounted || _selectedProject != targetProject) return;

    _applySessionSnapshot(snapshot);
    await _loadAutoCorrections(project: snapshot.project);
    await _refreshSessionLibrary();
  }

  Future<void> _createNewSessionInSelectedProject() async {
    if (_isListening) {
      setState(() => _statusMessage = 'Zatrzymaj transkrypcję przed utworzeniem nowej sesji.');
      return;
    }

    await _startNewLocalSession(project: _selectedProject);
  }

  Future<void> _showCreateProjectDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Nowy projekt'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nazwa projektu',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Utwórz'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;

    await _sessionService.createProject(trimmed);
    if (!mounted) return;
    _clearLoadedSession(
      project: trimmed,
      statusMessage: 'Utworzono pusty projekt: $trimmed',
    );
    await _loadAutoCorrections(project: trimmed);
    await _refreshSessionLibrary();
  }

  Future<void> _moveSessionToProject(
    LocalSessionSummary summary,
    String project,
  ) async {
    await _sessionService.setSessionProject(summary.directory, project);
    if (_currentSessionPath == summary.directory.path) {
      setState(() {
        _currentSessionProject = project;
        _selectedProject = project;
      });
      await _loadAutoCorrections(project: project);
    }
    await _refreshSessionLibrary();
  }

  Future<void> _renameSession(LocalSessionSummary summary) async {
    final controller = TextEditingController(text: summary.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Zmień nazwę transkrypcji'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nazwa',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Anuluj'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(''),
              child: const Text('Usuń nazwę'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Zapisz'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (newTitle == null) return;
    await _sessionService.renameSession(summary.directory, newTitle);
    await _refreshSessionLibrary();

    if (summary.directory.path == _currentSessionPath && mounted) {
      setState(() {
        _statusMessage = newTitle.trim().isEmpty
            ? 'Usunięto własną nazwę transkrypcji.'
            : 'Zmieniono nazwę transkrypcji.';
      });
    }
  }

  Future<void> _deleteSession(LocalSessionSummary summary) async {
    if (_isListening) {
      setState(() => _statusMessage = 'Zatrzymaj transkrypcję przed usunięciem sesji.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Usunąć transkrypcję?'),
          content: Text(
            'Transkrypcja "${summary.title}" zostanie przeniesiona do Kosza.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Przenieś do Kosza'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    final wasCurrentSession = summary.directory.path == _currentSessionPath;
    final trashedDirectory = await _sessionService.moveSessionToTrash(summary.directory);
    if (!mounted) return;

    if (wasCurrentSession) {
      setState(() {
        _setVisibleTranscription('', persist: false);
        _setSessionContext('', persist: false);
        _partialMicrophoneTranscription = '';
        _partialSystemAudioTranscription = '';
        _pendingPartialMicrophoneTranscription = '';
        _pendingPartialSystemAudioTranscription = '';
        _transcriptionSegments.clear();
        _explanations.clear();
        _microphonePartialCorrections.clear();
        _systemAudioPartialCorrections.clear();
        _currentSessionPath = null;
        _currentSessionProject = _selectedProject;
      });
    }

    setState(() {
      _statusMessage = 'Przeniesiono transkrypcję do Kosza: ${trashedDirectory.path}';
    });
    await _refreshSessionLibrary();
  }

  Future<void> _deleteSelectedProject() async {
    final project = _selectedProject;
    if (project == LocalSessionService.defaultProject) return;

    if (_isListening) {
      setState(() => _statusMessage = 'Zatrzymaj transkrypcję przed usunięciem projektu.');
      return;
    }

    final sessionCount = _sessionSummaries
        .where((summary) => summary.project == project)
        .length;
    final autoCorrectionCount = _autoCorrectionRules.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Usunąć projekt?'),
          content: Text(
            'Projekt "$project" zostanie przeniesiony do Kosza razem z '
            '$sessionCount transkrypcjami i $autoCorrectionCount autokorektami.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Przenieś do Kosza'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    final shouldClearCurrentSession = _currentSessionProject == project;
    final trashedDirectory = await _sessionService.moveProjectToTrash(project);
    if (!mounted) return;

    setState(() {
      _selectedProject = LocalSessionService.defaultProject;
      _currentSessionProject = shouldClearCurrentSession
          ? LocalSessionService.defaultProject
          : _currentSessionProject;
      if (shouldClearCurrentSession) {
        _setVisibleTranscription('', persist: false);
        _setSessionContext('', persist: false);
        _partialMicrophoneTranscription = '';
        _partialSystemAudioTranscription = '';
        _pendingPartialMicrophoneTranscription = '';
        _pendingPartialSystemAudioTranscription = '';
        _transcriptionSegments.clear();
        _explanations.clear();
        _microphonePartialCorrections.clear();
        _systemAudioPartialCorrections.clear();
        _currentSessionPath = null;
      }
      _statusMessage = 'Przeniesiono projekt do Kosza: ${trashedDirectory.path}';
    });
    await _loadAutoCorrections(project: LocalSessionService.defaultProject);
    await _refreshSessionLibrary();
  }

  Future<void> _showSettingsDialog() async {
    final settings = await getOpenAiSettings();
    final controller = TextEditingController(text: settings.apiKey ?? '');
    var rememberApiKey = settings.rememberApiKey;

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Ustawienia OpenAI'),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'OpenAI API key',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Zapamiętaj API key na tym komputerze'),
                    value: rememberApiKey,
                    onChanged: (value) {
                      setDialogState(() => rememberApiKey = value ?? true);
                    },
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () async {
                await saveOpenAiSettings(
                  apiKey: controller.text,
                  rememberApiKey: rememberApiKey,
                  speechLanguage: _selectedLocaleId,
                  answerLanguage: _selectedAnswerLanguage,
                  audioSource: _selectedSource,
                  transcriptionPanelFraction: _transcriptionPanelFraction,
                  sidebarWidth: _sidebarWidth,
                  sidebarSessionFraction: _sidebarSessionFraction,
                  sidebarAutoCorrectionFraction: _sidebarAutoCorrectionFraction,
                  explanationCharacterTarget: _explanationCharacterTarget,
                );
                if (!context.mounted) return;
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      rememberApiKey
                          ? 'API key zapisany lokalnie'
                          : 'API key nie będzie zapamiętany',
                    ),
                  ),
                );
              },
              child: const Text('Zapisz'),
            ),
          ],
        );
      },
    );

    controller.dispose();
  }

  bool get _isListening {
    if (_selectedSource == 'both') {
      return _speechToText.isListening || _isSystemAudioListening;
    }

    return _selectedSource == 'system'
        ? _isSystemAudioListening
        : _speechToText.isListening;
  }

  double get _signalLevel {
    if (_selectedSource == 'both') {
      return [_microphoneSignalLevel, _systemAudioSignalLevel]
          .reduce((current, next) => current > next ? current : next);
    }

    return _selectedSource == 'system'
        ? _systemAudioSignalLevel
        : _microphoneSignalLevel;
  }

  Widget _buildSignalIndicators() {
    if (_selectedSource == 'both') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SignalLevelIndicator(label: 'Mic', level: _microphoneSignalLevel),
          const SizedBox(width: 12),
          _SignalLevelIndicator(label: 'System', level: _systemAudioSignalLevel),
        ],
      );
    }

    return _SignalLevelIndicator(
      label: _selectedSource == 'system' ? 'System' : 'Mic',
      level: _signalLevel,
    );
  }

  @override
  void dispose() {
    _signalLevelTimer?.cancel();
    _transcriptionSaveDebounce?.cancel();
    _preferenceSaveDebounce?.cancel();
    _partialRenderDebounce?.cancel();
    _sessionLibraryRefreshDebounce?.cancel();
    _sessionContextSaveDebounce?.cancel();
    _transcriptionController.removeListener(_scheduleTranscriptSnapshotSave);
    _sessionContextController.removeListener(_scheduleSessionContextSave);
    _systemAudioSubscription?.cancel();
    _systemAudioControl.invokeMethod('stop');
    _transcriptionController.dispose();
    _questionController.dispose();
    _sessionContextController.dispose();
    _explanationLengthController.dispose();
    super.dispose();
  }

  Future<void> _handleTokenTap(TranscriptToken token) async {
    final tokenRange = _termRangeForToken(token);
    final initialTerm = _normalizeTerm(token.text);
    if (initialTerm.isEmpty) {
      setState(() => _statusMessage = 'Kliknięty fragment nie wygląda jak termin.');
      return;
    }

    final controller = TextEditingController(text: initialTerm);
    String? submittedTerm;
    var addToAutoCorrection = false;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Korekta terminu'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Termin lub fraza',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) {
                      submittedTerm = value;
                      Navigator.of(dialogContext).pop('ok');
                    },
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: addToAutoCorrection,
                    title: const Text('Dodaj do autokorekty'),
                    onChanged: (value) {
                      setDialogState(() => addToAutoCorrection = value ?? false);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Anuluj'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('ok'),
                  child: const Text('OK'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop('explain'),
                  child: const Text('Wyjaśnij'),
                ),
              ],
            );
          },
        );
      },
    );

    final term = _normalizeReplacement(submittedTerm ?? controller.text);
    controller.dispose();

    if (action == null) return;
    if (term.isEmpty && action != 'ok') {
      setState(() => _statusMessage = 'Termin jest pusty.');
      return;
    }

    if (action == 'ok') {
      _applyTokenCorrection(
        tokenRange,
        term,
        addToAutoCorrection: addToAutoCorrection,
      );
      return;
    }

    _applyTokenCorrection(
      tokenRange,
      term,
      quietIfUnavailable: true,
      addToAutoCorrection: addToAutoCorrection,
    );
    await _createExplanation(term, _wordIndexForOffset(_transcription, tokenRange.start));
  }

  TextRange _termRangeForToken(TranscriptToken token) {
    var leading = 0;
    var trailing = token.text.length;

    while (leading < trailing && _isTermEdgeChar(token.text[leading])) {
      leading += 1;
    }
    while (trailing > leading && _isTermEdgeChar(token.text[trailing - 1])) {
      trailing -= 1;
    }

    return TextRange(
      start: token.start + leading,
      end: token.start + trailing,
    );
  }

  bool _isTermEdgeChar(String char) {
    return RegExp(r"""[\s\.,;:!?()\[\]{}"'`]""").hasMatch(char);
  }

  bool _applyTokenCorrection(
    TextRange range,
    String replacement, {
    bool quietIfUnavailable = false,
    bool addToAutoCorrection = false,
  }) {
    final trimmed = replacement.trim();
    final location = _locationForDisplayRange(range);

    if (location == null) {
      if (!quietIfUnavailable) {
        setState(() {
          _statusMessage = 'Nie udało się ustalić miejsca korekty w transkrypcji.';
        });
      }
      return false;
    }

    if (location.isCommitted) {
      final committedText = _committedTranscription;
      final original = committedText.substring(
        location.localRange.start,
        location.localRange.end,
      );
      final effectiveRange = trimmed.isEmpty
          ? _rangeForDeletion(committedText, location.localRange)
          : location.localRange;
      final newText = committedText.replaceRange(
        effectiveRange.start,
        effectiveRange.end,
        trimmed,
      );
      setState(() {
        final learnedAutoCorrection =
            addToAutoCorrection ? _upsertAutoCorrection(original, trimmed) : false;
        _transcriptionController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
            offset: (effectiveRange.start + trimmed.length)
                .clamp(0, newText.length)
                .toInt(),
          ),
        );
        if (trimmed.isEmpty) {
          _statusMessage = 'Usunięto termin: $original';
        } else {
          _statusMessage = learnedAutoCorrection
              ? 'Poprawiono termin i dodano autokorektę: $original -> $trimmed'
              : 'Poprawiono termin: $trimmed';
        }
      });
      if (addToAutoCorrection && original.trim() != trimmed) {
        _persistAutoCorrections();
      }
      _sessionService.writeTranscriptSnapshot(newText);
      return true;
    }

    final source = location.source!;
    final partial = _partialTextFor(source);
    final original = partial.substring(
      location.localRange.start,
      location.localRange.end,
    );
    final effectiveRange = trimmed.isEmpty
        ? _rangeForDeletion(partial, location.localRange)
        : location.localRange;
    final correctedPartial = partial.replaceRange(
      effectiveRange.start,
      effectiveRange.end,
      trimmed,
    );
    final correctionContext = _correctionContext(
      partial,
      location.localRange.start,
      location.localRange.end,
    );

    setState(() {
      _setPartialTextFor(source, correctedPartial);
      if (original != trimmed) {
        final learnedAutoCorrection =
            addToAutoCorrection ? _upsertAutoCorrection(original, trimmed) : false;
        _partialCorrectionsFor(source).add(
          _PartialCorrection(
            original: original,
            replacement: trimmed,
            beforeWords: correctionContext.beforeWords,
            afterWords: correctionContext.afterWords,
          ),
        );
        if (learnedAutoCorrection) {
          _statusMessage = 'Poprawiono roboczy termin i dodano autokorektę: '
              '$original -> $trimmed';
          return;
        }
      }
      _statusMessage =
          trimmed.isEmpty ? 'Usunięto roboczy termin: $original' : 'Poprawiono roboczy termin: $trimmed';
    });
    if (addToAutoCorrection && original != trimmed) {
      _persistAutoCorrections();
    }
    return true;
  }

  TextRange _rangeForDeletion(String text, TextRange range) {
    var start = range.start.clamp(0, text.length).toInt();
    var end = range.end.clamp(start, text.length).toInt();

    if (end < text.length && _isInlineWhitespace(text[end])) {
      while (end < text.length && _isInlineWhitespace(text[end])) {
        end += 1;
      }
      return TextRange(start: start, end: end);
    }

    if (start > 0 && _isInlineWhitespace(text[start - 1])) {
      while (start > 0 && _isInlineWhitespace(text[start - 1])) {
        start -= 1;
      }
    }

    return TextRange(start: start, end: end);
  }

  bool _isInlineWhitespace(String char) {
    return char != '\n' && char != '\r' && char.trim().isEmpty;
  }

  _TranscriptLocation? _locationForDisplayRange(TextRange range) {
    if (!range.isValid || range.start < 0 || range.start >= range.end) return null;

    final committedText = _committedTranscription;
    if (range.end <= committedText.length) {
      return _TranscriptLocation(source: null, localRange: range);
    }

    var cursor = committedText.length;
    var hasPrevious = committedText.trim().isNotEmpty;

    _TranscriptLocation? checkPartial(_TranscriptSource source) {
      final partial = _partialTextFor(source);
      if (partial.trim().isEmpty) return null;
      if (hasPrevious) cursor += 2;
      final start = cursor;
      final end = start + partial.length;
      cursor = end;
      hasPrevious = true;

      if (range.start >= start && range.end <= end) {
        return _TranscriptLocation(
          source: source,
          localRange: TextRange(
            start: range.start - start,
            end: range.end - start,
          ),
        );
      }
      return null;
    }

    return checkPartial(_TranscriptSource.microphone) ??
        checkPartial(_TranscriptSource.systemAudio);
  }

  String _partialTextFor(_TranscriptSource source) {
    return source == _TranscriptSource.microphone
        ? _partialMicrophoneTranscription
        : _partialSystemAudioTranscription;
  }

  void _setPartialTextFor(_TranscriptSource source, String text) {
    if (source == _TranscriptSource.microphone) {
      _partialMicrophoneTranscription = text;
      _pendingPartialMicrophoneTranscription = text;
    } else {
      _partialSystemAudioTranscription = text;
      _pendingPartialSystemAudioTranscription = text;
    }
  }

  ({List<String> beforeWords, List<String> afterWords}) _correctionContext(
    String text,
    int start,
    int end,
  ) {
    final before = _normalizedWords(text.substring(0, start.clamp(0, text.length).toInt()));
    final after = _normalizedWords(text.substring(end.clamp(0, text.length).toInt()));

    return (
      beforeWords: before.length <= 4 ? before : before.sublist(before.length - 4),
      afterWords: after.length <= 4 ? after : after.sublist(0, 4),
    );
  }

  int _contextScore(
    String text,
    int start,
    int end,
    List<String> beforeWords,
    List<String> afterWords,
  ) {
    final candidateContext = _correctionContext(text, start, end);
    var score = 0;

    final candidateBefore = candidateContext.beforeWords.reversed.toList();
    final expectedBefore = beforeWords.reversed.toList();
    final beforeLimit = candidateBefore.length < expectedBefore.length
        ? candidateBefore.length
        : expectedBefore.length;
    for (var index = 0; index < beforeLimit; index += 1) {
      if (candidateBefore[index] == expectedBefore[index]) {
        score += 2;
      } else {
        break;
      }
    }

    final afterLimit = candidateContext.afterWords.length < afterWords.length
        ? candidateContext.afterWords.length
        : afterWords.length;
    for (var index = 0; index < afterLimit; index += 1) {
      if (candidateContext.afterWords[index] == afterWords[index]) {
        score += 2;
      } else {
        break;
      }
    }

    return score;
  }

  Future<void> _createExplanation(String term, int wordIndex) async {
    final localContext = _buildLocalContext(wordIndex);

    final id = _nextExplanationId++;
    setState(() {
      _explanations.insert(
        0,
        ExplanationItem(
          id: id,
          term: term,
          isLoading: true,
        ),
      );
    });

    try {
      final explanation = await getWordExplanation(
        term,
        _transcription,
        localContext: localContext,
        sessionContext: _sessionContext,
        answerLanguage: _selectedAnswerLanguage,
        characterTarget: _explanationCharacterTarget,
      );
      _updateExplanation(
        id,
        explanation: explanation,
        isLoading: false,
      );
    } catch (error) {
      _updateExplanation(
        id,
        error: error.toString(),
        isLoading: false,
      );
    }
  }

  int _wordIndexForOffset(String text, int offset) {
    final prefix = text.substring(0, offset.clamp(0, text.length).toInt());
    return prefix.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
  }

  String _normalizeTerm(String word) {
    return word
        .replaceAll(RegExp(r"""^[\s\.,;:!?()\[\]{}"'`]+"""), '')
        .replaceAll(RegExp(r"""[\s\.,;:!?()\[\]{}"'`]+$"""), '')
        .trim();
  }

  String _normalizeReplacement(String value) {
    return value.trim();
  }

  String _buildLocalContext(int wordIndex) {
    final words = _transcription
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();

    if (words.isEmpty) return '';

    final safeIndex = wordIndex.clamp(0, words.length - 1);
    final start = (safeIndex - 12).clamp(0, words.length);
    final end = (safeIndex + 13).clamp(0, words.length);
    return words.sublist(start, end).join(' ');
  }

  void _updateExplanation(
    int id, {
    String? explanation,
    String? error,
    required bool isLoading,
  }) {
    setState(() {
      final index = _explanations.indexWhere((item) => item.id == id);
      if (index == -1) return;
      _explanations[index] = _explanations[index].copyWith(
        explanation: explanation,
        error: error,
        isLoading: isLoading,
      );

      if (!isLoading) {
        _sessionService.appendExplanation(
          term: _explanations[index].term,
          explanation: explanation,
          error: error,
        );
      }
    });
  }

  Future<void> _askQuestion() async {
    final question = _questionController.text.trim();
    if (question.isEmpty || _isAskingQuestion) return;

    _questionController.clear();
    final id = _nextExplanationId++;
    setState(() {
      _isAskingQuestion = true;
      _explanations.insert(
        0,
        ExplanationItem(
          id: id,
          term: 'Pytanie: $question',
          isLoading: true,
        ),
      );
      _statusMessage = 'Wysyłam pytanie do OpenAI...';
    });

    try {
      final answer = await askQuestionAboutTranscript(
        question,
        _transcription,
        explanationsContext: _explanationsContext(excludeId: id),
        sessionContext: _sessionContext,
        answerLanguage: _selectedAnswerLanguage,
        characterTarget: _explanationCharacterTarget,
      );
      _updateExplanation(
        id,
        explanation: answer,
        isLoading: false,
      );
      if (mounted) {
        setState(() {
          _isAskingQuestion = false;
          _statusMessage = 'Odpowiedź dodana do wyjaśnień.';
        });
      }
    } catch (error) {
      _updateExplanation(
        id,
        error: error.toString(),
        isLoading: false,
      );
      if (mounted) {
        setState(() {
          _isAskingQuestion = false;
          _statusMessage = 'Nie udało się uzyskać odpowiedzi.';
        });
      }
    }
  }

  String _explanationsContext({int? excludeId}) {
    return _explanations
        .where((item) => item.id != excludeId && !item.isLoading)
        .where((item) =>
            (item.explanation != null && item.explanation!.trim().isNotEmpty) ||
            (item.error != null && item.error!.trim().isNotEmpty))
        .map((item) {
          final body = item.error ?? item.explanation ?? '';
          return '${item.term}\n$body';
        })
        .join('\n\n---\n\n');
  }

  Widget _buildQuestionBar() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 88, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _questionController,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  labelText: 'Zadaj pytanie do transkrypcji i wyjaśnień',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _askQuestion(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _isAskingQuestion ? null : _askQuestion,
              icon: _isAskingQuestion
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: const Text('Zapytaj'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionSidebar() {
    final visibleSessions = _sessionSummaries
        .where((summary) => summary.project == _selectedProject)
        .toList();

    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Row(
              children: [
                Text(
                  'Sesje',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Nowy projekt',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: _showCreateProjectDialog,
                ),
                IconButton(
                  tooltip: 'Nowa transkrypcja w projekcie',
                  icon: const Icon(Icons.note_add_outlined),
                  onPressed: _createNewSessionInSelectedProject,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _projects.contains(_selectedProject)
                        ? _selectedProject
                        : LocalSessionService.defaultProject,
                    decoration: const InputDecoration(
                      labelText: 'Projekt',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _projects
                        .map(
                          (project) => DropdownMenuItem(
                            value: project,
                            child: Text(
                              project,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      final project = value ?? LocalSessionService.defaultProject;
                      _selectProject(project);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Usuń projekt',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _selectedProject == LocalSessionService.defaultProject
                      ? null
                      : _deleteSelectedProject,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const dividerHeight = 10.0;
                if (constraints.maxHeight < 470) {
                  return Column(
                    children: [
                      Expanded(child: _buildSessionList(visibleSessions)),
                      Divider(height: 1, color: Theme.of(context).dividerColor),
                      Expanded(child: _buildAutoCorrectionsPanel()),
                    ],
                  );
                }

                final availableHeight = constraints.maxHeight - dividerHeight * 2;
                final sessionHeight = (availableHeight * _sidebarSessionFraction)
                    .clamp(110.0, availableHeight - 220.0)
                    .toDouble();
                final lowerHeight = availableHeight - sessionHeight;
                final autoCorrectionsHeight = (lowerHeight * _sidebarAutoCorrectionFraction)
                    .clamp(100.0, lowerHeight - 110.0)
                    .toDouble();
                final contextHeight = lowerHeight - autoCorrectionsHeight;

                return Column(
                  children: [
                    SizedBox(
                      height: sessionHeight,
                      child: _buildSessionList(visibleSessions),
                    ),
                    _buildHorizontalResizeHandle(
                      onDragUpdate: (details) {
                        setState(() {
                          _sidebarSessionFraction =
                              ((_sidebarSessionFraction * availableHeight +
                                          details.delta.dy) /
                                      availableHeight)
                                  .clamp(0.25, 0.75)
                                  .toDouble();
                        });
                      },
                    ),
                    SizedBox(
                      height: autoCorrectionsHeight,
                      child: _buildAutoCorrectionsPanel(),
                    ),
                    _buildHorizontalResizeHandle(
                      onDragUpdate: (details) {
                        setState(() {
                          _sidebarAutoCorrectionFraction =
                              ((_sidebarAutoCorrectionFraction * lowerHeight +
                                          details.delta.dy) /
                                      lowerHeight)
                                  .clamp(0.25, 0.75)
                                  .toDouble();
                        });
                      },
                    ),
                    SizedBox(
                      height: contextHeight,
                      child: _buildSessionContextPanel(),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHorizontalResizeHandle({
    required GestureDragUpdateCallback onDragUpdate,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: onDragUpdate,
        onVerticalDragEnd: (_) => _saveCurrentPreferences(),
        child: Container(
          height: 10,
          color: Theme.of(context).dividerColor.withOpacity(0.35),
          child: Center(
            child: Container(
              height: 2,
              width: 36,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSessionList(List<LocalSessionSummary> visibleSessions) {
    if (visibleSessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            'Brak transkrypcji w tym projekcie.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      itemCount: visibleSessions.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final summary = visibleSessions[index];
        final selected = summary.directory.path == _currentSessionPath;
        return Card(
          margin: EdgeInsets.zero,
          color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
          child: ListTile(
            dense: true,
            selected: selected,
            title: Text(
              summary.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_formatSessionTime(summary.startedAt)),
            onTap: () => _loadSession(summary),
            trailing: PopupMenuButton<_SessionAction>(
              tooltip: 'Opcje sesji',
              onSelected: (action) {
                if (action.rename) {
                  _renameSession(summary);
                } else if (action.delete) {
                  _deleteSession(summary);
                } else if (action.project != null) {
                  _moveSessionToProject(summary, action.project!);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _SessionAction.rename(),
                  child: Text('Zmień nazwę'),
                ),
                const PopupMenuItem(
                  value: _SessionAction.delete(),
                  child: Text('Usuń'),
                ),
                const PopupMenuDivider(),
                ..._projects.map(
                  (project) => PopupMenuItem(
                    value: _SessionAction.move(project),
                    enabled: project != summary.project,
                    child: Text('Przenieś do: $project'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAutoCorrectionsPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Row(
            children: [
              Text(
                'Autokorekty',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _selectedProject,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              Text(
                '${_autoCorrectionRules.where((rule) => rule.enabled).length}'
                '/${_autoCorrectionRules.length}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
        Expanded(
          child: _autoCorrectionRules.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      'Popraw termin w transkrypcji, a reguła pojawi się tutaj.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: _autoCorrectionRules.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final rule = _autoCorrectionRules[index];
                    return Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        dense: true,
                        leading: Checkbox(
                          value: rule.enabled,
                          onChanged: (value) =>
                              _toggleAutoCorrection(rule, value ?? false),
                        ),
                        title: Text(
                          '${rule.original} -> ${rule.replacement}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'Usuń autokorektę',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteAutoCorrection(rule),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSessionContextPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: TextField(
        controller: _sessionContextController,
        expands: true,
        minLines: null,
        maxLines: null,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          labelText: 'Kontekst sesji',
          hintText: 'Np. URL, temat spotkania albo krótka notatka',
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
      ),
    );
  }

  String _formatSessionTime(DateTime value) {
    final date = [
      value.year.toString().padLeft(4, '0'),
      value.month.toString().padLeft(2, '0'),
      value.day.toString().padLeft(2, '0'),
    ].join('-');
    final time = [
      value.hour.toString().padLeft(2, '0'),
      value.minute.toString().padLeft(2, '0'),
    ].join(':');
    return '$date $time';
  }

  Widget _buildResizablePanels() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const dividerWidth = 10.0;
        final availableWidth = constraints.maxWidth - dividerWidth;
        final transcriptionWidth = availableWidth * _transcriptionPanelFraction;
        final explanationWidth = availableWidth - transcriptionWidth;
        final visibleTranscript = _visibleTranscript;

        return Row(
          children: [
            SizedBox(
              width: transcriptionWidth,
              child: TranscriptionView(
                segments: visibleTranscript.segments,
                isTruncated: visibleTranscript.isTruncated,
                autoScroll: _isListening,
                onTokenTap: _handleTokenTap,
                onCopy: _copyTranscription,
                onClear: _clearVisibleTranscription,
              ),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _transcriptionPanelFraction =
                        (_transcriptionPanelFraction + details.delta.dx / availableWidth)
                            .clamp(0.25, 0.8);
                  });
                },
                onHorizontalDragEnd: (_) => _saveCurrentPreferences(),
                child: Container(
                  width: dividerWidth,
                  color: Theme.of(context).dividerColor.withOpacity(0.45),
                  child: Center(
                    child: Container(
                      width: 2,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: explanationWidth,
              child: ExplanationHistoryView(
                explanations: _explanations,
                onClear: () => setState(_explanations.clear),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('XplainR'),
            const SizedBox(width: 16),
            _buildSignalIndicators(),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Ustawienia OpenAI',
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            tooltip: 'Otwórz folder transkrypcji i wyjaśnień',
            icon: const Icon(Icons.folder_open),
            onPressed: _openSessionsFolder,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                DropdownButton<String>(
                  value: _selectedLocaleId,
                  items: const [
                    DropdownMenuItem(value: 'en_US', child: Text('English')),
                    DropdownMenuItem(value: 'pl_PL', child: Text('Polski')),
                  ],
                  onChanged: _isListening
                      ? null
                      : (value) {
                          setState(() => _selectedLocaleId = value ?? 'en_US');
                          _saveCurrentPreferences();
                        },
                ),
                const SizedBox(width: 16),
                DropdownButton<String>(
                  value: _selectedSource,
                  items: const [
                    DropdownMenuItem(value: 'microphone', child: Text('Mikrofon')),
                    DropdownMenuItem(value: 'system', child: Text('System audio')),
                    DropdownMenuItem(value: 'both', child: Text('Mikrofon + system audio')),
                  ],
                  onChanged: _isListening
                      ? null
                      : (value) {
                          setState(() => _selectedSource = value ?? 'microphone');
                          _saveCurrentPreferences();
                        },
                ),
                const SizedBox(width: 16),
                DropdownButton<String>(
                  value: _selectedAnswerLanguage,
                  items: const [
                    DropdownMenuItem(value: 'pl', child: Text('Wyjaśnienia: PL')),
                    DropdownMenuItem(value: 'en', child: Text('Explanations: EN')),
                  ],
                  onChanged: _isListening
                      ? null
                      : (value) {
                          setState(() => _selectedAnswerLanguage = value ?? 'pl');
                          _saveCurrentPreferences();
                        },
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 118,
                  child: TextField(
                    controller: _explanationLengthController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Znaki',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: _updateExplanationLength,
                    onSubmitted: _updateExplanationLength,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    _statusMessage ?? '',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Kopiuj komunikat',
                  icon: const Icon(Icons.content_copy),
                  onPressed: (_statusMessage == null || _statusMessage!.trim().isEmpty)
                      ? null
                      : _copyStatusMessage,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const dividerWidth = 10.0;
                final dynamicMaxSidebarWidth = constraints.maxWidth < 760
                    ? constraints.maxWidth * 0.42
                    : 560.0;
                final maxSidebarWidth = dynamicMaxSidebarWidth < 220
                    ? 220.0
                    : dynamicMaxSidebarWidth;
                final sidebarWidth =
                    _sidebarWidth.clamp(220.0, maxSidebarWidth).toDouble();

                return Row(
                  children: [
                    SizedBox(
                      width: sidebarWidth,
                      child: _buildSessionSidebar(),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          setState(() {
                            _sidebarWidth = (_sidebarWidth + details.delta.dx)
                                .clamp(220.0, maxSidebarWidth)
                                .toDouble();
                          });
                        },
                        onHorizontalDragEnd: (_) => _saveCurrentPreferences(),
                        child: Container(
                          width: dividerWidth,
                          color: Theme.of(context).dividerColor.withOpacity(0.45),
                          child: Center(
                            child: Container(
                              width: 2,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: _buildResizablePanels(),
                          ),
                          _buildQuestionBar(),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
   floatingActionButton: FloatingActionButton(
     onPressed: (_speechEnabled && !_isListening)
         ? _startListening
         : _stopListening,
     child: Icon(_isListening ? Icons.stop : Icons.mic),
   ),
    );
  }
}
