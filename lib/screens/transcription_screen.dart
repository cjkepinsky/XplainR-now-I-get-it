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
import '../l10n/app_strings.dart';
import '../models/explanation_citation.dart';

class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _SignalLevelIndicator extends StatelessWidget {
  final String label;
  final double level;
  final AppStrings strings;

  const _SignalLevelIndicator({
    required this.label,
    required this.level,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final roundedLevel = level.round().clamp(0, 100);
    final color = _signalColor(context, roundedLevel);

    return Tooltip(
      message: strings.pick(
        '$label: siła sygnału audio',
        '$label: audio signal level',
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style:
                Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
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
  final Set<String> _collapsedExplanationIds = {};
  final List<LocalSessionSummary> _sessionSummaries = [];
  final List<LocalAutoCorrectionRule> _autoCorrectionRules = [];
  final List<String> _projects = [LocalSessionService.defaultProject];
  final List<_PartialCorrection> _microphonePartialCorrections = [];
  final List<_PartialCorrection> _systemAudioPartialCorrections = [];
  final TextEditingController _transcriptionController =
      TextEditingController();
  final TextEditingController _translationController = TextEditingController();
  final TextEditingController _questionController = TextEditingController();
  final TextEditingController _sessionContextController =
      TextEditingController();
  final FocusNode _questionFocusNode = FocusNode();
  final TextEditingController _explanationLengthController =
      TextEditingController(text: '300');
  String _partialMicrophoneTranscription = '';
  String _partialSystemAudioTranscription = '';
  SpeechToText _speechToText = SpeechToText();
  final LocalSessionService _sessionService = LocalSessionService();
  bool _speechEnabled = false;
  bool _isSystemAudioListening = false;
  bool _isAskingQuestion = false;
  bool _isStartingListening = false;
  bool _isStoppingListening = false;
  bool _isSwitchingTranscriptionLanguage = false;
  bool _forceWebResearch = false;
  bool _transcriptTranslationEnabled = false;
  bool _languageAutoDetectionEnabled = false;
  bool _isLanguageDetectionProbeRunning = false;
  String _selectedLocaleId = 'en_US';
  String _selectedAnswerLanguage = 'pl';
  String _selectedInterfaceLanguage = 'pl';
  String _selectedTranscriptTranslationLanguage = 'pl';
  String _selectedExplanationModel = defaultExplanationModel;
  String _selectedSource = 'microphone';
  String _selectedProject = LocalSessionService.defaultProject;
  String _currentSessionProject = LocalSessionService.defaultProject;
  String? _currentSessionPath;
  String? _statusMessage;
  StreamSubscription<dynamic>? _systemAudioSubscription;
  Timer? _signalLevelTimer;
  Timer? _languageDetectionTimer;
  Timer? _transcriptionSaveDebounce;
  Timer? _translationSaveDebounce;
  Timer? _preferenceSaveDebounce;
  Timer? _partialRenderDebounce;
  Timer? _livePartialCommitTimer;
  Timer? _sessionLibraryRefreshDebounce;
  Timer? _sessionContextSaveDebounce;
  bool _suppressTranscriptSnapshot = false;
  bool _suppressTranslationSnapshot = false;
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
  String _latestRawMicrophoneTranscription = '';
  String _latestRawSystemAudioTranscription = '';
  String _committedRawMicrophoneTranscription = '';
  String _committedRawSystemAudioTranscription = '';
  RegExp? _autoCorrectionMatcher;
  Map<String, String> _autoCorrectionReplacements = {};
  Future<void> _translationQueue = Future.value();
  String? _languageDetectionCandidateLocaleId;
  int _languageDetectionCandidateCount = 0;
  DateTime? _lastAutoLanguageSwitchAt;
  String? _lastLanguageDetectionError;

  static const _systemAudioControl =
      MethodChannel('xplainr/system_audio_control');
  static const _systemAudioEvents = EventChannel('xplainr/system_audio_events');
  static const _visibleTranscriptWordLimit = 1500;
  static const _livePartialCommitInterval = Duration(seconds: 5);
  static const _livePartialCommitMinWords = 6;
  static const _languageDetectionInterval = Duration(seconds: 10);
  static const _languageDetectionCooldown = Duration(seconds: 30);
  static const _languageDetectionRequiredStableProbes = 1;

  String get _committedTranscription => _transcriptionController.text;
  String get _committedTranslation => _translationController.text;
  String get _sessionContext => _sessionContextController.text.trim();
  AppStrings get _t => AppStrings.forLanguage(_selectedInterfaceLanguage);

  String _displayProjectName(String project) {
    if (project == LocalSessionService.defaultProject) {
      return _t.pick('Bez projektu', 'No project');
    }
    return project;
  }

  String _newExplanationStableId(int runtimeId) {
    return '${DateTime.now().microsecondsSinceEpoch}-$runtimeId';
  }

  String get _transcription {
    return [
      _committedTranscription,
      _partialMicrophoneTranscription,
      _partialSystemAudioTranscription,
    ].where((part) => part.trim().isNotEmpty).join('\n\n');
  }

  ({List<TranscriptDisplaySegment> segments, bool isTruncated})
      get _visibleTranscript {
    final fullText = _transcription;
    if (fullText.trim().isEmpty) {
      return (segments: const <TranscriptDisplaySegment>[], isTruncated: false);
    }

    final tailStart =
        _tailStartForLastWords(fullText, _visibleTranscriptWordLimit);
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

  ({List<TranscriptDisplaySegment> segments, bool isTruncated})
      get _visibleTranslation {
    final fullText = _committedTranslation;
    if (fullText.trim().isEmpty) {
      return (segments: const <TranscriptDisplaySegment>[], isTruncated: false);
    }

    final tailStart =
        _tailStartForLastWords(fullText, _visibleTranscriptWordLimit);
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
    final matches =
        RegExp(r'[^\s](?:[\s\S]*?[^\s])?(?=\n{2,}|$)').allMatches(text);
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
    debugPrint('Initializing speech...');
    _transcriptionController.addListener(_scheduleTranscriptSnapshotSave);
    _translationController.addListener(_scheduleTranslationSnapshotSave);
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
      () => _sessionService
          .writeTranscriptSnapshot(_transcriptionController.text),
    );
  }

  void _scheduleTranslationSnapshotSave() {
    if (_suppressTranslationSnapshot) return;

    _translationSaveDebounce?.cancel();
    _translationSaveDebounce = Timer(
      const Duration(milliseconds: 700),
      () =>
          _sessionService.writeTranslationSnapshot(_translationController.text),
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
    final projects =
        await _sessionService.loadProjects(sessionSummaries: summaries);
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
    _livePartialCommitTimer?.cancel();
    _livePartialCommitTimer = null;
    _sessionContextSaveDebounce?.cancel();
    _sessionContextSaveDebounce = null;
    setState(() {
      _setVisibleTranscription(snapshot.transcription, persist: false);
      _setVisibleTranslation(snapshot.translation, persist: false);
      _setSessionContext(snapshot.sessionContext, persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _resetPartialRecognitionState();
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
              stableId: record.id,
              term: record.term,
              explanation: record.explanation,
              error: record.error,
              citations: record.citations,
            ),
          ),
        );
      _collapsedExplanationIds
        ..clear()
        ..addAll(snapshot.collapsedExplanationIds);
      _statusMessage = _t.pick(
        'Załadowano sesję: ${snapshot.directory.path}',
        'Loaded session: ${snapshot.directory.path}',
      );
    });
  }

  void _clearLoadedSession({
    required String project,
    String? statusMessage,
  }) {
    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;
    _livePartialCommitTimer?.cancel();
    _livePartialCommitTimer = null;
    _sessionContextSaveDebounce?.cancel();
    _sessionContextSaveDebounce = null;
    _sessionService.clearCurrentSession();

    setState(() {
      _setVisibleTranscription('', persist: false);
      _setVisibleTranslation('', persist: false);
      _setSessionContext('', persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _resetPartialRecognitionState();
      _transcriptionSegments.clear();
      _explanations.clear();
      _collapsedExplanationIds.clear();
      _microphonePartialCorrections.clear();
      _systemAudioPartialCorrections.clear();
      _currentSessionPath = null;
      _currentSessionProject = project;
      _selectedProject = project;
      _statusMessage = statusMessage ??
          _t.pick(
            'Projekt nie ma jeszcze transkrypcji.',
            'This project does not have any transcripts yet.',
          );
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

  int? _segmentIndexForCommittedRange(TextRange range) {
    if (!range.isValid) return null;

    final segments = _displaySegmentsFromText(_committedTranscription, 0);
    for (var index = 0; index < segments.length; index += 1) {
      final segment = segments[index];
      final start = segment.startOffset;
      final end = start + segment.text.length;
      if (range.start >= start && range.start <= end) {
        return index;
      }
    }
    return null;
  }

  String? _segmentTextAtIndex(String transcription, int index) {
    final segments = _displaySegmentsFromText(transcription, 0);
    if (index < 0 || index >= segments.length) return null;
    return segments[index].text.trim();
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

    final microphoneTarget =
        _speechToText.isListening ? _microphoneSignalRaw : 0.0;
    final systemTarget = _isSystemAudioListening ? _systemAudioSignalRaw : 0.0;

    setState(() {
      _microphoneSignalLevel =
          _smoothedLevel(_microphoneSignalLevel, microphoneTarget);
      _systemAudioSignalLevel =
          _smoothedLevel(_systemAudioSignalLevel, systemTarget);
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
      _selectedInterfaceLanguage = settings.interfaceLanguage;
      _selectedLocaleId = settings.speechLanguage;
      _selectedAnswerLanguage = settings.answerLanguage;
      _selectedSource = settings.audioSource;
      _selectedExplanationModel = settings.explanationModel;
      _transcriptTranslationEnabled = settings.transcriptTranslationEnabled;
      _selectedTranscriptTranslationLanguage =
          settings.transcriptTranslationLanguage;
      _languageAutoDetectionEnabled = settings.languageAutoDetectionEnabled;
      _transcriptionPanelFraction =
          settings.transcriptionPanelFraction.clamp(0.25, 0.8);
      _sidebarWidth = settings.sidebarWidth.clamp(220, 520).toDouble();
      _sidebarSessionFraction =
          settings.sidebarSessionFraction.clamp(0.25, 0.75).toDouble();
      _sidebarAutoCorrectionFraction =
          settings.sidebarAutoCorrectionFraction.clamp(0.25, 0.75).toDouble();
      _explanationCharacterTarget =
          settings.explanationCharacterTarget.clamp(120, 2500).toInt();
      _explanationLengthController.text =
          _explanationCharacterTarget.toString();
    });
  }

  void _initSpeech() async {
    _speechToText = SpeechToText();
    bool available = await _speechToText.initialize(
      onStatus: (status) => debugPrint('onStatus: $status'),
      onError: (errorNotification) => debugPrint('onError: $errorNotification'),
    );
    debugPrint('Speech recognition available: $available');
    setState(() {
      _speechEnabled = available;
      _statusMessage = available
          ? _t.pick(
              'Gotowe do transkrypcji z mikrofonu.',
              'Ready to transcribe from the microphone.',
            )
          : _t.pick(
              'Rozpoznawanie mowy nie jest dostępne.',
              'Speech recognition is not available.',
            );
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
    debugPrint('Recognized words: ${result.recognizedWords}');
  }

  Future<void> _handleTranscriptionLanguageChanged(String? value) async {
    final nextLocaleId = value ?? _selectedLocaleId;
    if (nextLocaleId == _selectedLocaleId || _isAudioTransitioning) return;

    if (!_isListening) {
      setState(() => _selectedLocaleId = nextLocaleId);
      await _saveCurrentPreferences();
      return;
    }

    await _switchTranscriptionLanguage(nextLocaleId);
  }

  Future<void> _switchTranscriptionLanguage(String nextLocaleId) async {
    final previousLocaleId = _selectedLocaleId;
    final nextLanguage = _transcriptionLanguageName(nextLocaleId);

    setState(() {
      _isSwitchingTranscriptionLanguage = true;
      _statusMessage = _t.pick(
        'Przełączanie języka transkrypcji na $nextLanguage...',
        'Switching transcription language to $nextLanguage...',
      );
    });

    final shouldResumeLanguageDetection = _languageAutoDetectionEnabled;

    await _sessionService.appendEvent(
      type: 'transcription_language_switch_started',
      details: {
        'from': previousLocaleId,
        'to': nextLocaleId,
        'audioSource': _selectedSource,
      },
    );

    try {
      await _stopLanguageDetection(resetState: false);
      await _stopSelectedAudioSources(
        updateStatus: false,
        refreshLibrary: false,
      );
      if (!mounted) return;

      setState(() {
        _selectedLocaleId = nextLocaleId;
        _resetPartialRecognitionState();
      });
      await _saveCurrentPreferences();

      final marker = _languageSwitchMarker(nextLocaleId);
      setState(() {
        _appendTranscriptSegment(marker);
        _statusMessage = _t.pick(
          'Język transkrypcji: $nextLanguage. Wznawiam nasłuchiwanie...',
          'Transcription language: $nextLanguage. Resuming listening...',
        );
      });
      await _sessionService.appendEvent(
        type: 'transcription_language_changed',
        details: {
          'from': previousLocaleId,
          'to': nextLocaleId,
          'audioSource': _selectedSource,
          'marker': marker,
        },
      );

      await _startSelectedAudioSources(updateStatus: false);
      if (shouldResumeLanguageDetection) {
        await _startLanguageDetectionIfNeeded();
      }
      if (!mounted) return;

      await _sessionService.appendEvent(
        type: 'transcription_language_switch_completed',
        details: {
          'from': previousLocaleId,
          'to': nextLocaleId,
          'audioSource': _selectedSource,
        },
      );
      setState(() {
        _statusMessage = _t.pick(
          'Język transkrypcji: $nextLanguage. Nasłuchiwanie wznowione.',
          'Transcription language: $nextLanguage. Listening resumed.',
        );
      });
      await _refreshSessionLibraryImmediately();
    } catch (error) {
      await _sessionService.appendEvent(
        type: 'transcription_language_switch_failed',
        details: {
          'from': previousLocaleId,
          'to': nextLocaleId,
          'audioSource': _selectedSource,
          'error': error.toString(),
        },
      );
      if (!mounted) return;
      setState(() {
        _statusMessage = _t.pick(
          'Nie udało się przełączyć języka transkrypcji: $error',
          'Could not switch transcription language: $error',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isSwitchingTranscriptionLanguage = false);
      }
    }
  }

  String _languageSwitchMarker(String localeId) {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    final language = _transcriptionLanguageName(localeId);
    return _t.pick(
      '[$hour:$minute:$second] Zmieniono język transkrypcji na: $language',
      '[$hour:$minute:$second] Transcription language changed to: $language',
    );
  }

  String _transcriptionLanguageName(String localeId) {
    return localeId.toLowerCase().startsWith('pl')
        ? _t.pick('Polski', 'Polish')
        : 'English';
  }

  Future<void> _startListening() async {
    if (_isAudioTransitioning) return;

    setState(() {
      _isStartingListening = true;
      _statusMessage = _t.pick(
        'Uruchamianie transkrypcji...',
        'Starting transcription...',
      );
    });

    try {
      await _ensureActiveSession();
      await _sessionService.appendEvent(
        type: 'transcription_start_requested',
        details: {
          'speechLanguage': _selectedLocaleId,
          'audioSource': _selectedSource,
        },
      );
      await _startSelectedAudioSources();
      await _startLanguageDetectionIfNeeded();
      await _sessionService.appendEvent(
        type: 'transcription_started',
        details: {
          'speechLanguage': _selectedLocaleId,
          'audioSource': _selectedSource,
        },
      );
    } finally {
      if (mounted) {
        setState(() => _isStartingListening = false);
      }
    }
  }

  Future<void> _startSelectedAudioSources({bool updateStatus = true}) async {
    if (_selectedSource == 'both') {
      await _startCombinedListening(updateStatus: updateStatus);
      return;
    }
    if (_selectedSource == 'system') {
      await _startSystemAudioListening(updateStatus: updateStatus);
      return;
    }

    await _startMicrophoneListening(updateStatus: updateStatus);
  }

  Future<void> _ensureActiveSession() async {
    if (_sessionService.currentSessionDirectory != null) {
      setState(() {
        _statusMessage = _t.pick(
          'Kontynuacja sesji: ${_sessionService.currentSessionDirectory!.path}',
          'Continuing session: ${_sessionService.currentSessionDirectory!.path}',
        );
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
      transcriptTranslationEnabled: _transcriptTranslationEnabled,
      transcriptTranslationLanguage: _selectedTranscriptTranslationLanguage,
      languageAutoDetectionEnabled: _languageAutoDetectionEnabled,
      project: project,
    );

    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;
    _livePartialCommitTimer?.cancel();
    _livePartialCommitTimer = null;
    _sessionContextSaveDebounce?.cancel();
    _sessionContextSaveDebounce = null;
    setState(() {
      _setVisibleTranscription('', persist: false);
      _setVisibleTranslation('', persist: false);
      _setSessionContext('', persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _resetPartialRecognitionState();
      _transcriptionSegments.clear();
      _explanations.clear();
      _collapsedExplanationIds.clear();
      _microphonePartialCorrections.clear();
      _systemAudioPartialCorrections.clear();
      _currentSessionPath = directory.path;
      _currentSessionProject = project;
      _selectedProject = project;
      _statusMessage = _t.pick(
        'Sesja zapisywana w ${directory.path}',
        'Session is being saved in ${directory.path}',
      );
    });
    await _loadAutoCorrections(project: project);
    await _refreshSessionLibrary();
  }

  Future<void> _startMicrophoneListening({bool updateStatus = true}) async {
    debugPrint('Start microphone listening');
    if (updateStatus) {
      setState(() => _statusMessage = _t.pick(
            'Nasłuchiwanie mikrofonu...',
            'Listening to the microphone...',
          ));
    }
    await _speechToText.listen(
      onResult: _onSpeechResult,
      onSoundLevelChange: _handleMicrophoneSoundLevel,
      localeId: _selectedLocaleId,
      listenOptions: SpeechListenOptions(listenMode: ListenMode.dictation),
    );
    setState(() {});
  }

  Future<void> _stopListening() async {
    if (_isAudioTransitioning) return;

    setState(() {
      _isStoppingListening = true;
      _statusMessage = _t.pick(
        'Zatrzymywanie transkrypcji...',
        'Stopping transcription...',
      );
    });

    try {
      await _stopLanguageDetection();
      await _stopSelectedAudioSources();
      await _sessionService.appendEvent(
        type: 'transcription_stopped',
        details: {
          'speechLanguage': _selectedLocaleId,
          'audioSource': _selectedSource,
        },
      );
    } finally {
      if (mounted) {
        setState(() => _isStoppingListening = false);
      }
    }
  }

  Future<void> _stopSelectedAudioSources({
    bool updateStatus = true,
    bool refreshLibrary = true,
  }) async {
    if (_selectedSource == 'both') {
      await _stopCombinedListening(
        updateStatus: updateStatus,
        refreshLibrary: refreshLibrary,
      );
      return;
    }

    if (_selectedSource == 'system') {
      await _stopSystemAudioListening(
        updateStatus: updateStatus,
        refreshLibrary: refreshLibrary,
      );
      return;
    }

    await _stopMicrophoneListening(
      updateStatus: updateStatus,
      refreshLibrary: refreshLibrary,
    );
  }

  Future<void> _stopMicrophoneListening({
    bool updateStatus = true,
    bool refreshLibrary = true,
  }) async {
    debugPrint('Stop microphone listening');
    await _speechToText.stop();
    setState(() {
      _commitPartialTranscript(
        '',
        source: _TranscriptSource.microphone,
      );
      _microphoneSignalRaw = 0;
      _microphoneSignalLevel = 0;
      if (updateStatus) {
        _statusMessage = _t.pick('Zatrzymano mikrofon.', 'Microphone stopped.');
      }
    });
    if (updateStatus && refreshLibrary) {
      await _refreshSessionLibraryImmediately();
    }
  }

  Future<void> _startCombinedListening({bool updateStatus = true}) async {
    debugPrint('Start combined listening');
    if (updateStatus) {
      setState(() => _statusMessage = _t.pick(
            'Uruchamianie mikrofonu i audio systemowego...',
            'Starting microphone and system audio...',
          ));
    }

    try {
      await _startSystemAudioListening(updateStatus: false);
      await _startMicrophoneListening(updateStatus: false);
      if (updateStatus) {
        setState(() => _statusMessage = _t.pick(
              'Nasłuchiwanie mikrofonu i audio systemowego...',
              'Listening to microphone and system audio...',
            ));
      }
    } catch (error) {
      setState(() => _statusMessage = _t.pick(
            'Nie udało się uruchomić trybu łączonego: $error',
            'Could not start combined mode: $error',
          ));
    }
  }

  Future<void> _stopCombinedListening({
    bool updateStatus = true,
    bool refreshLibrary = true,
  }) async {
    debugPrint('Stop combined listening');
    await _stopMicrophoneListening(updateStatus: false);
    await _stopSystemAudioListening(updateStatus: false);
    if (updateStatus) {
      setState(() => _statusMessage = _t.pick(
            'Zatrzymano mikrofon i audio systemowe.',
            'Microphone and system audio stopped.',
          ));
    }
    if (updateStatus && refreshLibrary) {
      await _refreshSessionLibraryImmediately();
    }
  }

  Future<void> _startSystemAudioListening({bool updateStatus = true}) async {
    debugPrint('Start system audio listening');
    setState(() {
      _isSystemAudioListening = true;
      if (updateStatus) {
        _statusMessage = _t.pick(
          'Uruchamianie przechwytywania audio systemowego...',
          'Starting system audio capture...',
        );
      }
    });

    await _systemAudioSubscription?.cancel();
    _systemAudioSubscription =
        _systemAudioEvents.receiveBroadcastStream().listen(
      _handleSystemAudioEvent,
      onError: (error) {
        setState(() {
          _isSystemAudioListening = false;
          _statusMessage = _t.pick(
            'Błąd audio systemowego: $error',
            'System audio error: $error',
          );
        });
      },
    );

    try {
      await _systemAudioControl.invokeMethod('start', {
        'localeId': _selectedLocaleId,
      });
      if (updateStatus) {
        setState(() => _statusMessage = _t.pick(
              'Nasłuchiwanie audio systemowego...',
              'Listening to system audio...',
            ));
      }
    } catch (error) {
      await _systemAudioSubscription?.cancel();
      _systemAudioSubscription = null;
      setState(() {
        _isSystemAudioListening = false;
        _statusMessage = _t.pick(
          'Nie udało się uruchomić audio systemowego: $error',
          'Could not start system audio: $error',
        );
      });
    }
  }

  Future<void> _stopSystemAudioListening({
    bool updateStatus = true,
    bool refreshLibrary = true,
  }) async {
    debugPrint('Stop system audio listening');
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
          _statusMessage = _t.pick(
            'Zatrzymano audio systemowe.',
            'System audio stopped.',
          );
        }
      });
      if (updateStatus && refreshLibrary) {
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
      setState(() => _statusMessage = _t.pick(
            'Błąd rozpoznawania: ${event['message']}',
            'Recognition error: ${event['message']}',
          ));
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

  Future<void> _startLanguageDetectionIfNeeded() async {
    if (!_languageAutoDetectionEnabled || !_isListening) return;

    _languageDetectionTimer?.cancel();
    _languageDetectionTimer = Timer.periodic(
      _languageDetectionInterval,
      (_) => unawaited(_runLanguageDetectionProbe()),
    );

    try {
      if (_selectedSource == 'microphone' || _selectedSource == 'both') {
        await _systemAudioControl.invokeMethod('startMicrophoneProbe');
      }
      await _sessionService.appendEvent(
        type: 'language_auto_detection_started',
        details: {
          'audioSource': _selectedSource,
          'speechLanguage': _selectedLocaleId,
          'model': defaultLanguageDetectionModel,
        },
      );
      unawaited(_runLanguageDetectionProbe());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = _t.pick(
          'Nie udało się uruchomić auto-detekcji języka: $error',
          'Could not start automatic language detection: $error',
        );
      });
    }
  }

  Future<void> _stopLanguageDetection({bool resetState = true}) async {
    _languageDetectionTimer?.cancel();
    _languageDetectionTimer = null;
    _isLanguageDetectionProbeRunning = false;

    try {
      await _systemAudioControl.invokeMethod('stopMicrophoneProbe');
    } catch (_) {
      // The probe may never have been started, which is harmless.
    }

    if (resetState) {
      _languageDetectionCandidateLocaleId = null;
      _languageDetectionCandidateCount = 0;
      _lastLanguageDetectionError = null;
    }
  }

  void _setLanguageAutoDetectionEnabled(bool enabled) {
    setState(() {
      _languageAutoDetectionEnabled = enabled;
      _languageDetectionCandidateLocaleId = null;
      _languageDetectionCandidateCount = 0;
      _lastLanguageDetectionError = null;
      _statusMessage = enabled
          ? _t.pick(
              'Auto-detekcja języka włączona dla kolejnych próbek audio.',
              'Automatic language detection enabled for upcoming audio probes.',
            )
          : _t.pick(
              'Auto-detekcja języka wyłączona.',
              'Automatic language detection disabled.',
            );
    });

    if (enabled && _isListening) {
      unawaited(_startLanguageDetectionIfNeeded());
    } else {
      unawaited(_stopLanguageDetection());
    }
    _saveCurrentPreferences();
  }

  Future<void> _runLanguageDetectionProbe() async {
    if (!_languageAutoDetectionEnabled ||
        !_isListening ||
        _isAudioTransitioning ||
        _isLanguageDetectionProbeRunning) {
      return;
    }

    final lastSwitchAt = _lastAutoLanguageSwitchAt;
    if (lastSwitchAt != null &&
        DateTime.now().difference(lastSwitchAt) < _languageDetectionCooldown) {
      return;
    }

    _isLanguageDetectionProbeRunning = true;
    try {
      final probeAudio = await _takeLanguageProbeAudio();
      if (probeAudio == null || probeAudio.isEmpty) return;

      final detected = await detectSpeechLanguageFromAudio(
        probeAudio,
        interfaceLanguage: _selectedInterfaceLanguage,
      );
      if (!_languageAutoDetectionEnabled ||
          !_isListening ||
          _isAudioTransitioning) {
        return;
      }
      if (detected == null) return;

      _lastLanguageDetectionError = null;
      final detectedLocaleId = _localeIdForDetectedLanguage(
        detected.languageCode,
      );
      if (detectedLocaleId == null) return;

      await _sessionService.appendEvent(
        type: 'language_detection_probe',
        details: {
          'detectedLanguage': detected.languageCode,
          'detectedLocaleId': detectedLocaleId,
          'currentLocaleId': _selectedLocaleId,
          'audioSource': _selectedSource,
          'sampleBytes': probeAudio.length,
          'text': detected.text,
        },
      );

      if (detectedLocaleId == _selectedLocaleId) {
        _languageDetectionCandidateLocaleId = null;
        _languageDetectionCandidateCount = 0;
        return;
      }

      if (_languageDetectionCandidateLocaleId == detectedLocaleId) {
        _languageDetectionCandidateCount += 1;
      } else {
        _languageDetectionCandidateLocaleId = detectedLocaleId;
        _languageDetectionCandidateCount = 1;
      }

      if (_languageDetectionCandidateCount <
          _languageDetectionRequiredStableProbes) {
        return;
      }

      final nextLanguage = _transcriptionLanguageName(detectedLocaleId);
      if (mounted) {
        setState(() {
          _statusMessage = _t.pick(
            'Auto-detekcja wykryła $nextLanguage. Przełączam transkrypcję...',
            'Auto-detection found $nextLanguage. Switching transcription...',
          );
        });
      }
      _lastAutoLanguageSwitchAt = DateTime.now();
      _languageDetectionCandidateLocaleId = null;
      _languageDetectionCandidateCount = 0;
      await _switchTranscriptionLanguage(detectedLocaleId);
    } catch (error) {
      final message = error.toString();
      if (_lastLanguageDetectionError != message) {
        _lastLanguageDetectionError = message;
        await _sessionService.appendEvent(
          type: 'language_detection_probe_failed',
          details: {
            'audioSource': _selectedSource,
            'error': message,
          },
        );
        if (mounted) {
          setState(() {
            _statusMessage = _t.pick(
              'Auto-detekcja języka nie zadziałała: $error',
              'Automatic language detection failed: $error',
            );
          });
        }
      }
    } finally {
      _isLanguageDetectionProbeRunning = false;
    }
  }

  Future<Uint8List?> _takeLanguageProbeAudio() async {
    final source = _languageProbeSource();
    final level =
        source == 'system' ? _systemAudioSignalLevel : _microphoneSignalLevel;
    if (level < 8) return null;

    final bytes = await _systemAudioControl.invokeMethod<Uint8List>(
      'takeLanguageProbe',
      {'source': source},
    );
    return bytes;
  }

  String _languageProbeSource() {
    if (_selectedSource != 'both') return _selectedSource;
    return _systemAudioSignalLevel >= _microphoneSignalLevel
        ? 'system'
        : 'microphone';
  }

  String? _localeIdForDetectedLanguage(String languageCode) {
    return switch (languageCode) {
      'pl' => 'pl_PL',
      'en' => 'en_US',
      _ => null,
    };
  }

  bool _appendTranscriptSegment(String text, {_TranscriptSource? source}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    final committedText = _committedTranscription.trim();
    final previousSegment =
        _transcriptionSegments.isNotEmpty ? _transcriptionSegments.last : '';
    final previousText = _stripTranscriptSourceLabel(previousSegment);
    final segmentText = source == null
        ? trimmed
        : '${_transcriptSourceLabel(source)}: $trimmed';
    if (committedText.isNotEmpty &&
        _transcriptionSegments.isNotEmpty &&
        previousSegment == segmentText) {
      return false;
    }
    if (committedText.isNotEmpty &&
        _transcriptionSegments.isNotEmpty &&
        _isLikelySameSegment(previousText, trimmed)) {
      return false;
    }
    if (committedText.isNotEmpty && committedText.endsWith(segmentText)) {
      return false;
    }

    _transcriptionSegments.add(segmentText);
    _appendTranscriptToController(segmentText);
    unawaited(_sessionService.appendTranscriptSegment(segmentText));
    _queueTranscriptTranslation(segmentText);
    _scheduleSessionLibraryRefresh();
    return true;
  }

  String _transcriptSourceLabel(_TranscriptSource source) {
    return source == _TranscriptSource.microphone
        ? _t.pick('Mikrofon', 'Microphone')
        : 'System audio';
  }

  String _stripTranscriptSourceLabel(String text) {
    return text
        .replaceFirst(
          RegExp(
            r'^\s*(Mikrofon|Microphone|Mic|System audio)\s*:\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  void _queueTranscriptTranslation(String segment) {
    if (!_transcriptTranslationEnabled) return;

    final targetLanguage = _selectedTranscriptTranslationLanguage;
    final sourceLanguage = _speechLanguageCode;
    final context = _sessionContext;
    _translationQueue = _translationQueue
        .catchError((_) {})
        .then(
          (_) => _translateAndAppendSegment(
            segment,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sessionContext: context,
          ),
        )
        .catchError((error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = _t.pick(
          'Błąd tłumaczenia transkrypcji: $error',
          'Transcript translation error: $error',
        );
      });
    });
  }

  String get _speechLanguageCode {
    return _selectedLocaleId.toLowerCase().startsWith('pl') ? 'pl' : 'en';
  }

  Future<void> _translateAndAppendSegment(
    String segment, {
    required String sourceLanguage,
    required String targetLanguage,
    required String sessionContext,
  }) async {
    final translated = await translateTranscriptSegment(
      segment,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      sessionContext: sessionContext,
      interfaceLanguage: _selectedInterfaceLanguage,
    );

    if (!mounted || translated.trim().isEmpty) return;

    setState(() {
      _appendTranslationToController(translated);
    });
    unawaited(_sessionService.appendTranslationSegment(translated));
  }

  void _queueTranscriptSegmentRetranslation(
    int segmentIndex,
    String segment,
  ) {
    if (!_transcriptTranslationEnabled || segment.trim().isEmpty) return;

    final targetLanguage = _selectedTranscriptTranslationLanguage;
    final sourceLanguage = _speechLanguageCode;
    final context = _sessionContext;
    _translationQueue = _translationQueue
        .catchError((_) {})
        .then(
          (_) => _retranslateSegmentAtIndex(
            segmentIndex,
            segment,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sessionContext: context,
          ),
        )
        .catchError((error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = _t.pick(
          'Błąd aktualizacji tłumaczenia: $error',
          'Translation update error: $error',
        );
      });
    });
  }

  Future<void> _retranslateSegmentAtIndex(
    int segmentIndex,
    String segment, {
    required String sourceLanguage,
    required String targetLanguage,
    required String sessionContext,
  }) async {
    final translated = await translateTranscriptSegment(
      segment,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      sessionContext: sessionContext,
      interfaceLanguage: _selectedInterfaceLanguage,
    );

    if (!mounted || translated.trim().isEmpty) return;

    final translationSegments =
        _segmentsFromTranscription(_committedTranslation);
    if (segmentIndex >= 0 && segmentIndex < translationSegments.length) {
      translationSegments[segmentIndex] = translated;
    } else {
      translationSegments.add(translated);
    }
    final nextTranslation = translationSegments.join('\n\n');

    setState(() {
      _setVisibleTranslation(nextTranslation, persist: false);
      _statusMessage = _t.pick(
        'Zaktualizowano tłumaczenie poprawionego fragmentu.',
        'Updated the corrected fragment translation.',
      );
    });
    unawaited(_sessionService.writeTranslationSnapshot(nextTranslation));
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
          currentRow[j] = previousRow[j] > currentRow[j - 1]
              ? previousRow[j]
              : currentRow[j - 1];
        }
      }
      for (var j = 0; j <= second.length; j += 1) {
        previousRow[j] = currentRow[j];
        currentRow[j] = 0;
      }
    }

    final longestCommonSubsequence = previousRow[second.length];
    final longestLength =
        first.length > second.length ? first.length : second.length;
    return longestCommonSubsequence / longestLength;
  }

  void _updatePartialTranscript(String text,
      {required _TranscriptSource source}) {
    final rawText = text.trim();
    _setLatestRawTextFor(source, rawText);
    final uncommittedText = _uncommittedRawTextFor(source, rawText);
    final trimmed = _applyPartialCorrections(uncommittedText.trim(), source);
    if (source == _TranscriptSource.microphone) {
      _pendingPartialMicrophoneTranscription = trimmed;
    } else {
      _pendingPartialSystemAudioTranscription = trimmed;
    }

    _partialRenderDebounce ??= Timer(
      const Duration(milliseconds: 250),
      _flushPendingPartialTranscripts,
    );
    _scheduleLivePartialCommit();
  }

  void _flushPendingPartialTranscripts() {
    _partialRenderDebounce = null;
    if (!mounted) return;

    setState(() {
      if (_pendingPartialMicrophoneTranscription.isNotEmpty ||
          _partialMicrophoneTranscription.isNotEmpty) {
        _partialMicrophoneTranscription =
            _pendingPartialMicrophoneTranscription;
      }
      if (_pendingPartialSystemAudioTranscription.isNotEmpty ||
          _partialSystemAudioTranscription.isNotEmpty) {
        _partialSystemAudioTranscription =
            _pendingPartialSystemAudioTranscription;
      }
    });
  }

  void _commitPartialTranscript(String text,
      {required _TranscriptSource source}) {
    _livePartialCommitTimer?.cancel();
    _livePartialCommitTimer = null;
    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;

    final pendingText = source == _TranscriptSource.microphone
        ? _pendingPartialMicrophoneTranscription
        : _pendingPartialSystemAudioTranscription;
    final displayText = source == _TranscriptSource.microphone
        ? _partialMicrophoneTranscription
        : _partialSystemAudioTranscription;
    final latestRawText = _latestRawTextFor(source);
    final rawText = text.trim().isNotEmpty
        ? text.trim()
        : latestRawText.trim().isNotEmpty
            ? latestRawText
            : '';
    final uncommittedRawText = rawText.trim().isNotEmpty
        ? _uncommittedRawTextFor(source, rawText)
        : '';
    final trimmed = _applyPartialCorrections(
      uncommittedRawText.trim().isNotEmpty
          ? uncommittedRawText
          : pendingText.trim().isNotEmpty
              ? pendingText
              : displayText,
      source,
    );
    if (trimmed.isEmpty) {
      if (source == _TranscriptSource.microphone) {
        _partialMicrophoneTranscription = '';
        _pendingPartialMicrophoneTranscription = '';
      } else {
        _partialSystemAudioTranscription = '';
        _pendingPartialSystemAudioTranscription = '';
      }
      _resetPartialRecognitionStateFor(source);
      return;
    }

    final appended = _appendTranscriptSegment(trimmed, source: source);
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
    _resetPartialRecognitionStateFor(source);
  }

  void _scheduleLivePartialCommit() {
    if (!_transcriptTranslationEnabled || !_isListening) return;
    _livePartialCommitTimer ??= Timer(
      _livePartialCommitInterval,
      _commitLivePartialTranscripts,
    );
  }

  void _commitLivePartialTranscripts() {
    _livePartialCommitTimer = null;
    if (!mounted || !_transcriptTranslationEnabled || !_isListening) return;

    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;

    var committedAny = false;
    setState(() {
      committedAny = _commitLivePartialFor(_TranscriptSource.microphone) ||
          _commitLivePartialFor(_TranscriptSource.systemAudio);
    });

    if (committedAny) {
      _scheduleSessionLibraryRefresh();
    }
    if (_hasUncommittedPartialText) {
      _scheduleLivePartialCommit();
    }
  }

  bool _commitLivePartialFor(_TranscriptSource source) {
    final rawText = _latestRawTextFor(source).trim();
    if (rawText.isEmpty) return false;

    final uncommittedText = _uncommittedRawTextFor(source, rawText).trim();
    final correctedText =
        _applyPartialCorrections(uncommittedText, source).trim();
    if (correctedText.isEmpty) return false;

    final wordCount = correctedText
        .split(RegExp(r'\s+'))
        .where((word) => word.trim().isNotEmpty)
        .length;
    if (wordCount < _livePartialCommitMinWords && correctedText.length < 48) {
      return false;
    }

    final appended = _appendTranscriptSegment(correctedText, source: source);
    _setCommittedRawTextFor(source, rawText);
    _setPartialTextFor(source, '');
    _partialCorrectionsFor(source).clear();
    return appended;
  }

  bool get _hasUncommittedPartialText {
    return _uncommittedRawTextFor(
          _TranscriptSource.microphone,
          _latestRawMicrophoneTranscription,
        ).trim().isNotEmpty ||
        _uncommittedRawTextFor(
          _TranscriptSource.systemAudio,
          _latestRawSystemAudioTranscription,
        ).trim().isNotEmpty;
  }

  String _latestRawTextFor(_TranscriptSource source) {
    return source == _TranscriptSource.microphone
        ? _latestRawMicrophoneTranscription
        : _latestRawSystemAudioTranscription;
  }

  void _setLatestRawTextFor(_TranscriptSource source, String text) {
    if (source == _TranscriptSource.microphone) {
      _latestRawMicrophoneTranscription = text;
    } else {
      _latestRawSystemAudioTranscription = text;
    }
  }

  String _committedRawTextFor(_TranscriptSource source) {
    return source == _TranscriptSource.microphone
        ? _committedRawMicrophoneTranscription
        : _committedRawSystemAudioTranscription;
  }

  void _setCommittedRawTextFor(_TranscriptSource source, String text) {
    if (source == _TranscriptSource.microphone) {
      _committedRawMicrophoneTranscription = text;
    } else {
      _committedRawSystemAudioTranscription = text;
    }
  }

  String _uncommittedRawTextFor(_TranscriptSource source, String rawText) {
    final raw = rawText.trim();
    if (raw.isEmpty) return '';

    final committedRaw = _committedRawTextFor(source).trim();
    if (committedRaw.isEmpty) return raw;

    if (raw.startsWith(committedRaw)) {
      return raw.substring(committedRaw.length).trimLeft();
    }

    if (raw.toLowerCase().startsWith(committedRaw.toLowerCase())) {
      return raw.substring(committedRaw.length).trimLeft();
    }

    final prefixLength = _commonPrefixLength(
      raw.toLowerCase(),
      committedRaw.toLowerCase(),
    );
    if (prefixLength / committedRaw.length >= 0.85) {
      return raw.substring(prefixLength).trimLeft();
    }

    _setCommittedRawTextFor(source, '');
    return raw;
  }

  int _commonPrefixLength(String first, String second) {
    final limit = first.length < second.length ? first.length : second.length;
    var index = 0;
    while (
        index < limit && first.codeUnitAt(index) == second.codeUnitAt(index)) {
      index += 1;
    }
    return index;
  }

  void _resetPartialRecognitionState() {
    _resetPartialRecognitionStateFor(_TranscriptSource.microphone);
    _resetPartialRecognitionStateFor(_TranscriptSource.systemAudio);
  }

  void _resetPartialRecognitionStateFor(_TranscriptSource source) {
    _setLatestRawTextFor(source, '');
    _setCommittedRawTextFor(source, '');
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
      return _autoCorrectionReplacements[matchedText.toLowerCase()] ??
          matchedText;
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
      for (final rule in enabledRules)
        rule.original.toLowerCase(): rule.replacement,
    };

    if (enabledRules.isEmpty) {
      _autoCorrectionMatcher = null;
      return;
    }

    final alternatives =
        enabledRules.map((rule) => RegExp.escape(rule.original)).join('|');
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
          ? _t.pick(
              'Włączono autokorektę: ${rule.original} -> ${rule.replacement}',
              'Enabled auto-correction: ${rule.original} -> ${rule.replacement}',
            )
          : _t.pick(
              'Wyłączono autokorektę: ${rule.original} -> ${rule.replacement}',
              'Disabled auto-correction: ${rule.original} -> ${rule.replacement}',
            );
    });
    _persistAutoCorrections();
  }

  void _deleteAutoCorrection(LocalAutoCorrectionRule rule) {
    setState(() {
      _autoCorrectionRules.removeWhere((item) => item.id == rule.id);
      _rebuildAutoCorrectionMatcher();
      _statusMessage = _t.pick(
        'Usunięto autokorektę: ${rule.original} -> ${rule.replacement}',
        'Deleted auto-correction: ${rule.original} -> ${rule.replacement}',
      );
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

  void _appendTranslationToController(String text) {
    final oldText = _translationController.text;
    final separator = oldText.trim().isEmpty ? '' : '\n\n';
    final newText = '$oldText$separator$text';

    _setVisibleTranslation(newText, persist: false);
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

  void _setVisibleTranslation(String text, {bool persist = true}) {
    _suppressTranslationSnapshot = !persist;
    _translationController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _suppressTranslationSnapshot = false;
    if (persist) {
      _sessionService.writeTranslationSnapshot(text);
    }
  }

  void _copyTranscription() {
    final text =
        _transcriptTranslationEnabled && _committedTranslation.trim().isNotEmpty
            ? [
                _t.pick('Oryginał', 'Original'),
                _transcription,
                _t.pick('Tłumaczenie', 'Translation'),
                _committedTranslation,
              ].join('\n\n')
            : _transcription;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _t.pick(
            'Transkrypcja skopiowana do schowka',
            'Transcript copied to clipboard',
          ),
        ),
      ),
    );
  }

  void _clearVisibleTranscription() {
    _partialRenderDebounce?.cancel();
    _partialRenderDebounce = null;
    _livePartialCommitTimer?.cancel();
    _livePartialCommitTimer = null;
    setState(() {
      _setVisibleTranscription('', persist: false);
      _setVisibleTranslation('', persist: false);
      _partialMicrophoneTranscription = '';
      _partialSystemAudioTranscription = '';
      _pendingPartialMicrophoneTranscription = '';
      _pendingPartialSystemAudioTranscription = '';
      _transcriptionSegments.clear();
      _microphonePartialCorrections.clear();
      _systemAudioPartialCorrections.clear();
      _statusMessage = _t.pick(
        'Wyczyszczono transkrypcję z widoku. Pliki lokalne zostały.',
        'Transcript cleared from the view. Local files were kept.',
      );
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
      SnackBar(
        content: Text(
          _t.pick(
              'Komunikat skopiowany do schowka', 'Message copied to clipboard'),
        ),
      ),
    );
  }

  Future<void> _saveCurrentPreferences() async {
    await saveAppPreferences(
      interfaceLanguage: _selectedInterfaceLanguage,
      speechLanguage: _selectedLocaleId,
      answerLanguage: _selectedAnswerLanguage,
      audioSource: _selectedSource,
      transcriptionPanelFraction: _transcriptionPanelFraction,
      sidebarWidth: _sidebarWidth,
      sidebarSessionFraction: _sidebarSessionFraction,
      sidebarAutoCorrectionFraction: _sidebarAutoCorrectionFraction,
      explanationCharacterTarget: _explanationCharacterTarget,
      explanationModel: _selectedExplanationModel,
      transcriptTranslationEnabled: _transcriptTranslationEnabled,
      transcriptTranslationLanguage: _selectedTranscriptTranslationLanguage,
      languageAutoDetectionEnabled: _languageAutoDetectionEnabled,
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
      setState(() => _statusMessage = _t.pick(
            'Zatrzymaj transkrypcję przed zmianą sesji.',
            'Stop transcription before changing sessions.',
          ));
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
      setState(() => _statusMessage = _t.pick(
            'Zatrzymaj transkrypcję przed zmianą projektu.',
            'Stop transcription before changing projects.',
          ));
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
        statusMessage: _t.pick(
          'Wybrany projekt nie ma jeszcze transkrypcji.',
          'The selected project does not have any transcripts yet.',
        ),
      );
      return;
    }

    final snapshot =
        await _sessionService.loadSession(projectSessions.first.directory);
    if (!mounted || _selectedProject != targetProject) return;

    _applySessionSnapshot(snapshot);
    await _loadAutoCorrections(project: snapshot.project);
    await _refreshSessionLibrary();
  }

  Future<void> _createNewSessionInSelectedProject() async {
    if (_isListening) {
      setState(() => _statusMessage = _t.pick(
            'Zatrzymaj transkrypcję przed utworzeniem nowej sesji.',
            'Stop transcription before creating a new session.',
          ));
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
          title: Text(_t.pick('Nowy projekt', 'New project')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: _t.pick('Nazwa projektu', 'Project name'),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_t.pick('Anuluj', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: Text(_t.pick('Utwórz', 'Create')),
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
      statusMessage: _t.pick(
        'Utworzono pusty projekt: $trimmed',
        'Created empty project: $trimmed',
      ),
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
          title: Text(_t.pick('Zmień nazwę transkrypcji', 'Rename transcript')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: _t.pick('Nazwa', 'Name'),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_t.pick('Anuluj', 'Cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(''),
              child: Text(_t.pick('Usuń nazwę', 'Clear name')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: Text(_t.pick('Zapisz', 'Save')),
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
            ? _t.pick(
                'Usunięto własną nazwę transkrypcji.',
                'Custom transcript name removed.',
              )
            : _t.pick(
                'Zmieniono nazwę transkrypcji.',
                'Transcript renamed.',
              );
      });
    }
  }

  Future<void> _deleteSession(LocalSessionSummary summary) async {
    if (_isListening) {
      setState(() => _statusMessage = _t.pick(
            'Zatrzymaj transkrypcję przed usunięciem sesji.',
            'Stop transcription before deleting a session.',
          ));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(_t.pick('Usunąć transkrypcję?', 'Delete transcript?')),
          content: Text(
            _t.pick(
              'Transkrypcja "${summary.title}" zostanie przeniesiona do Kosza.',
              'Transcript "${summary.title}" will be moved to Trash.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_t.pick('Anuluj', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_t.pick('Przenieś do Kosza', 'Move to Trash')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    final wasCurrentSession = summary.directory.path == _currentSessionPath;
    final trashedDirectory =
        await _sessionService.moveSessionToTrash(summary.directory);
    if (!mounted) return;

    if (wasCurrentSession) {
      setState(() {
        _setVisibleTranscription('', persist: false);
        _setVisibleTranslation('', persist: false);
        _setSessionContext('', persist: false);
        _partialMicrophoneTranscription = '';
        _partialSystemAudioTranscription = '';
        _pendingPartialMicrophoneTranscription = '';
        _pendingPartialSystemAudioTranscription = '';
        _transcriptionSegments.clear();
        _explanations.clear();
        _collapsedExplanationIds.clear();
        _microphonePartialCorrections.clear();
        _systemAudioPartialCorrections.clear();
        _currentSessionPath = null;
        _currentSessionProject = _selectedProject;
      });
    }

    setState(() {
      _statusMessage = _t.pick(
        'Przeniesiono transkrypcję do Kosza: ${trashedDirectory.path}',
        'Moved transcript to Trash: ${trashedDirectory.path}',
      );
    });
    await _refreshSessionLibrary();
  }

  Future<void> _deleteSelectedProject() async {
    final project = _selectedProject;
    if (project == LocalSessionService.defaultProject) return;

    if (_isListening) {
      setState(() => _statusMessage = _t.pick(
            'Zatrzymaj transkrypcję przed usunięciem projektu.',
            'Stop transcription before deleting a project.',
          ));
      return;
    }

    final sessionCount =
        _sessionSummaries.where((summary) => summary.project == project).length;
    final autoCorrectionCount = _autoCorrectionRules.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(_t.pick('Usunąć projekt?', 'Delete project?')),
          content: Text(
            _t.pick(
              'Projekt "$project" zostanie przeniesiony do Kosza razem z '
                  '$sessionCount transkrypcjami i $autoCorrectionCount autokorektami.',
              'Project "$project" will be moved to Trash together with '
                  '$sessionCount transcripts and $autoCorrectionCount auto-corrections.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_t.pick('Anuluj', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_t.pick('Przenieś do Kosza', 'Move to Trash')),
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
        _setVisibleTranslation('', persist: false);
        _setSessionContext('', persist: false);
        _partialMicrophoneTranscription = '';
        _partialSystemAudioTranscription = '';
        _pendingPartialMicrophoneTranscription = '';
        _pendingPartialSystemAudioTranscription = '';
        _transcriptionSegments.clear();
        _explanations.clear();
        _collapsedExplanationIds.clear();
        _microphonePartialCorrections.clear();
        _systemAudioPartialCorrections.clear();
        _currentSessionPath = null;
      }
      _statusMessage = _t.pick(
        'Przeniesiono projekt do Kosza: ${trashedDirectory.path}',
        'Moved project to Trash: ${trashedDirectory.path}',
      );
    });
    await _loadAutoCorrections(project: LocalSessionService.defaultProject);
    await _refreshSessionLibrary();
  }

  Future<void> _showSettingsDialog() async {
    final settings = await getOpenAiSettings();
    final controller = TextEditingController(text: settings.apiKey ?? '');
    var rememberApiKey = settings.rememberApiKey;
    var interfaceLanguage = _selectedInterfaceLanguage;
    var explanationModel = normalizeExplanationModel(_selectedExplanationModel);

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final dialogStrings = AppStrings.forLanguage(interfaceLanguage);
            return AlertDialog(
              title: Text(dialogStrings.pick('Ustawienia', 'Settings')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: interfaceLanguage,
                    decoration: InputDecoration(
                      labelText: dialogStrings.pick(
                        'Język interfejsu',
                        'Interface language',
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'pl', child: Text('Polski')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                    ],
                    onChanged: (value) {
                      setDialogState(() => interfaceLanguage = value ?? 'pl');
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: explanationModel,
                    decoration: InputDecoration(
                      labelText: dialogStrings.pick(
                        'Model wyjaśnień',
                        'Explanation model',
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    items: explanationModelOptions
                        .map(
                          (model) => DropdownMenuItem(
                            value: model,
                            child: Text(model),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setDialogState(
                        () =>
                            explanationModel = normalizeExplanationModel(value),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
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
                    title: Text(
                      dialogStrings.pick(
                        'Zapamiętaj API key na tym komputerze',
                        'Remember API key on this computer',
                      ),
                    ),
                    value: rememberApiKey,
                    onChanged: (value) {
                      setDialogState(() => rememberApiKey = value ?? true);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(dialogStrings.pick('Anuluj', 'Cancel')),
                ),
                FilledButton(
                  onPressed: () async {
                    await saveOpenAiSettings(
                      apiKey: controller.text,
                      rememberApiKey: rememberApiKey,
                      interfaceLanguage: interfaceLanguage,
                      speechLanguage: _selectedLocaleId,
                      answerLanguage: _selectedAnswerLanguage,
                      audioSource: _selectedSource,
                      transcriptionPanelFraction: _transcriptionPanelFraction,
                      sidebarWidth: _sidebarWidth,
                      sidebarSessionFraction: _sidebarSessionFraction,
                      sidebarAutoCorrectionFraction:
                          _sidebarAutoCorrectionFraction,
                      explanationCharacterTarget: _explanationCharacterTarget,
                      explanationModel: explanationModel,
                      transcriptTranslationEnabled:
                          _transcriptTranslationEnabled,
                      transcriptTranslationLanguage:
                          _selectedTranscriptTranslationLanguage,
                      languageAutoDetectionEnabled:
                          _languageAutoDetectionEnabled,
                    );
                    if (!context.mounted) return;
                    setState(() {
                      _selectedInterfaceLanguage = interfaceLanguage;
                      _selectedExplanationModel = explanationModel;
                    });
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          rememberApiKey
                              ? dialogStrings.pick(
                                  'API key zapisany lokalnie',
                                  'API key saved locally',
                                )
                              : dialogStrings.pick(
                                  'API key nie będzie zapamiętany',
                                  'API key will not be remembered',
                                ),
                        ),
                      ),
                    );
                  },
                  child: Text(dialogStrings.pick('Zapisz', 'Save')),
                ),
              ],
            );
          },
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

  bool get _isAudioTransitioning {
    return _isStartingListening ||
        _isStoppingListening ||
        _isSwitchingTranscriptionLanguage;
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
          _SignalLevelIndicator(
            label: 'Mic',
            level: _microphoneSignalLevel,
            strings: _t,
          ),
          const SizedBox(width: 12),
          _SignalLevelIndicator(
            label: 'System',
            level: _systemAudioSignalLevel,
            strings: _t,
          ),
        ],
      );
    }

    return _SignalLevelIndicator(
      label: _selectedSource == 'system' ? 'System' : 'Mic',
      level: _signalLevel,
      strings: _t,
    );
  }

  @override
  void dispose() {
    _signalLevelTimer?.cancel();
    _languageDetectionTimer?.cancel();
    _transcriptionSaveDebounce?.cancel();
    _translationSaveDebounce?.cancel();
    _preferenceSaveDebounce?.cancel();
    _partialRenderDebounce?.cancel();
    _livePartialCommitTimer?.cancel();
    _sessionLibraryRefreshDebounce?.cancel();
    _sessionContextSaveDebounce?.cancel();
    _transcriptionController.removeListener(_scheduleTranscriptSnapshotSave);
    _translationController.removeListener(_scheduleTranslationSnapshotSave);
    _sessionContextController.removeListener(_scheduleSessionContextSave);
    _systemAudioSubscription?.cancel();
    _systemAudioControl.invokeMethod('stopMicrophoneProbe');
    _systemAudioControl.invokeMethod('stop');
    _transcriptionController.dispose();
    _translationController.dispose();
    _questionController.dispose();
    _questionFocusNode.dispose();
    _sessionContextController.dispose();
    _explanationLengthController.dispose();
    super.dispose();
  }

  Future<void> _handleTokenTap(TranscriptToken token) async {
    final tokenRange = _termRangeForToken(token);
    final initialTerm = _normalizeTerm(token.text);
    if (initialTerm.isEmpty) {
      setState(() => _statusMessage = _t.pick(
            'Kliknięty fragment nie wygląda jak termin.',
            'The clicked fragment does not look like a term.',
          ));
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
              title: Text(_t.pick('Korekta terminu', 'Correct term')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: _t.pick('Termin lub fraza', 'Term or phrase'),
                      border: const OutlineInputBorder(),
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
                    title: Text(_t.pick(
                        'Dodaj do autokorekty', 'Add to auto-correction')),
                    onChanged: (value) {
                      setDialogState(
                          () => addToAutoCorrection = value ?? false);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(_t.pick('Anuluj', 'Cancel')),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('ok'),
                  child: const Text('OK'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop('explain'),
                  child: Text(_t.pick('Wyjaśnij', 'Explain')),
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
      setState(() => _statusMessage = _t.pick(
            'Termin jest pusty.',
            'The term is empty.',
          ));
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
    await _createExplanation(
        term, _wordIndexForOffset(_transcription, tokenRange.start));
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
          _statusMessage = _t.pick(
            'Nie udało się ustalić miejsca korekty w transkrypcji.',
            'Could not locate the correction range in the transcript.',
          );
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
      final segmentIndex = _segmentIndexForCommittedRange(effectiveRange);
      final newText = committedText.replaceRange(
        effectiveRange.start,
        effectiveRange.end,
        trimmed,
      );
      setState(() {
        final learnedAutoCorrection = addToAutoCorrection
            ? _upsertAutoCorrection(original, trimmed)
            : false;
        _transcriptionController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
            offset: (effectiveRange.start + trimmed.length)
                .clamp(0, newText.length)
                .toInt(),
          ),
        );
        _transcriptionSegments
          ..clear()
          ..addAll(_segmentsFromTranscription(newText));
        if (trimmed.isEmpty) {
          _statusMessage = _t.pick(
            'Usunięto termin: $original',
            'Deleted term: $original',
          );
        } else {
          _statusMessage = learnedAutoCorrection
              ? _t.pick(
                  'Poprawiono termin i dodano autokorektę: $original -> $trimmed',
                  'Corrected term and added auto-correction: $original -> $trimmed',
                )
              : _t.pick(
                  'Poprawiono termin: $trimmed',
                  'Corrected term: $trimmed',
                );
        }
      });
      if (addToAutoCorrection && original.trim() != trimmed) {
        _persistAutoCorrections();
      }
      _sessionService.writeTranscriptSnapshot(newText);
      final correctedSegment = segmentIndex == null
          ? null
          : _segmentTextAtIndex(newText, segmentIndex);
      if (correctedSegment != null) {
        _queueTranscriptSegmentRetranslation(segmentIndex!, correctedSegment);
      }
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
        final learnedAutoCorrection = addToAutoCorrection
            ? _upsertAutoCorrection(original, trimmed)
            : false;
        _partialCorrectionsFor(source).add(
          _PartialCorrection(
            original: original,
            replacement: trimmed,
            beforeWords: correctionContext.beforeWords,
            afterWords: correctionContext.afterWords,
          ),
        );
        if (learnedAutoCorrection) {
          _statusMessage = _t.pick(
            'Poprawiono roboczy termin i dodano autokorektę: '
                '$original -> $trimmed',
            'Corrected draft term and added auto-correction: '
                '$original -> $trimmed',
          );
          return;
        }
      }
      _statusMessage = trimmed.isEmpty
          ? _t.pick(
              'Usunięto roboczy termin: $original',
              'Deleted draft term: $original',
            )
          : _t.pick(
              'Poprawiono roboczy termin: $trimmed',
              'Corrected draft term: $trimmed',
            );
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
    if (!range.isValid || range.start < 0 || range.start >= range.end) {
      return null;
    }

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
    final before = _normalizedWords(
        text.substring(0, start.clamp(0, text.length).toInt()));
    final after =
        _normalizedWords(text.substring(end.clamp(0, text.length).toInt()));

    return (
      beforeWords:
          before.length <= 4 ? before : before.sublist(before.length - 4),
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
    final stableId = _newExplanationStableId(id);
    setState(() {
      _explanations.insert(
        0,
        ExplanationItem(
          id: id,
          stableId: stableId,
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
        interfaceLanguage: _selectedInterfaceLanguage,
        characterTarget: _explanationCharacterTarget,
        explanationModel: _selectedExplanationModel,
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
    List<ExplanationCitation> citations = const [],
    required bool isLoading,
  }) {
    setState(() {
      final index = _explanations.indexWhere((item) => item.id == id);
      if (index == -1) return;
      _explanations[index] = _explanations[index].copyWith(
        explanation: explanation,
        error: error,
        citations: citations,
        isLoading: isLoading,
      );

      if (!isLoading) {
        _sessionService.appendExplanation(
          id: _explanations[index].stableId,
          term: _explanations[index].term,
          explanation: explanation,
          error: error,
          citations: citations,
        );
      }
    });
  }

  Future<void> _askQuestion() async {
    final question = _questionController.text.trim();
    if (question.isEmpty || _isAskingQuestion) return;

    final useWebResearch =
        _forceWebResearch || _questionNeedsWebResearch(question);
    _questionController.clear();
    final id = _nextExplanationId++;
    final stableId = _newExplanationStableId(id);
    setState(() {
      _isAskingQuestion = true;
      _explanations.insert(
        0,
        ExplanationItem(
          id: id,
          stableId: stableId,
          term: _t.pick('Pytanie: $question', 'Question: $question'),
          isLoading: true,
        ),
      );
      _statusMessage = useWebResearch
          ? _t.pick(
              'Szukam w sieci i pytam OpenAI...',
              'Searching the web and asking OpenAI...',
            )
          : _t.pick(
              'Wysyłam pytanie do OpenAI...',
              'Sending question to OpenAI...',
            );
    });

    try {
      final answer = await askQuestionAboutTranscript(
        question,
        _transcription,
        explanationsContext: _explanationsContext(excludeId: id),
        sessionContext: _sessionContext,
        answerLanguage: _selectedAnswerLanguage,
        interfaceLanguage: _selectedInterfaceLanguage,
        characterTarget: _explanationCharacterTarget,
        useWebSearch: useWebResearch,
      );
      _updateExplanation(
        id,
        explanation: answer.text,
        citations: answer.citations,
        isLoading: false,
      );
      if (mounted) {
        setState(() {
          _isAskingQuestion = false;
          _statusMessage = _t.pick(
            useWebResearch
                ? 'Odpowiedź z web researchu dodana do wyjaśnień.'
                : 'Odpowiedź dodana do wyjaśnień.',
            useWebResearch
                ? 'Web research answer added to explanations.'
                : 'Answer added to explanations.',
          );
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
          _statusMessage = _t.pick(
            'Nie udało się uzyskać odpowiedzi.',
            'Could not get an answer.',
          );
        });
      }
    }
  }

  bool _questionNeedsWebResearch(String question) {
    final normalized = question.toLowerCase();
    const triggers = [
      'wyszukaj',
      'znajdź',
      'sprawdź w sieci',
      'sprawdz w sieci',
      'google',
      'internet',
      'www',
      'url',
      'link',
      'ile kosztuje',
      'cena',
      'koszt',
      'kup',
      'sklep',
      'aktualnie',
      'aktualna',
      'aktualny',
      'dzisiaj',
      'teraz',
      'najnowsz',
      'search',
      'find',
      'look up',
      'web',
      'online',
      'price',
      'cost',
      'buy',
      'latest',
      'current',
      'today',
    ];

    return triggers.any(normalized.contains);
  }

  String _explanationsContext({int? excludeId}) {
    return _explanations
        .where((item) => item.id != excludeId && !item.isLoading)
        .where((item) =>
            (item.explanation != null && item.explanation!.trim().isNotEmpty) ||
            (item.error != null && item.error!.trim().isNotEmpty))
        .map((item) {
      final body = item.error ?? item.explanation ?? '';
      final citations = item.citations
          .map((citation) => '${citation.title} ${citation.url}'.trim())
          .join('\n');
      return [
        item.term,
        body,
        if (citations.isNotEmpty) citations,
      ].join('\n');
    }).join('\n\n---\n\n');
  }

  KeyEventResult _handleQuestionKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isPasteShortcut = event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed);
    if (!isPasteShortcut) return KeyEventResult.ignored;

    unawaited(_pasteIntoQuestionField());
    return KeyEventResult.handled;
  }

  Future<void> _pasteIntoQuestionField() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final pastedText = clipboardData?.text;
    if (pastedText == null || pastedText.isEmpty) return;

    final value = _questionController.value;
    final currentText = value.text;
    final selection = value.selection;
    final selectionStart = selection.isValid
        ? selection.start.clamp(0, currentText.length).toInt()
        : currentText.length;
    final selectionEnd = selection.isValid
        ? selection.end.clamp(0, currentText.length).toInt()
        : currentText.length;
    final start = selectionStart < selectionEnd ? selectionStart : selectionEnd;
    final end = selectionStart < selectionEnd ? selectionEnd : selectionStart;
    final nextText = currentText.replaceRange(start, end, pastedText);
    final nextOffset = start + pastedText.length;

    _questionController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    _questionFocusNode.requestFocus();
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
              child: Focus(
                onKeyEvent: _handleQuestionKeyEvent,
                child: TextField(
                  controller: _questionController,
                  focusNode: _questionFocusNode,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    labelText: _t.pick(
                      'Zadaj pytanie do transkrypcji i wyjaśnień',
                      'Ask a question about the transcript and explanations',
                    ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _askQuestion(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: _t.pick(
                'Wymuś web research dla tego typu pytań.',
                'Force web research for questions like this.',
              ),
              child: FilterChip(
                avatar: const Icon(Icons.public, size: 16),
                label: const Text('Web'),
                selected: _forceWebResearch,
                onSelected: _isAskingQuestion
                    ? null
                    : (value) {
                        setState(() => _forceWebResearch = value);
                      },
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
              label: Text(_t.pick('Zapytaj', 'Ask')),
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
                  _t.pick('Sesje', 'Sessions'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  tooltip: _t.pick('Nowy projekt', 'New project'),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: _showCreateProjectDialog,
                ),
                IconButton(
                  tooltip: _t.pick(
                    'Nowa transkrypcja w projekcie',
                    'New transcript in project',
                  ),
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
                    decoration: InputDecoration(
                      labelText: _t.pick('Projekt', 'Project'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _projects
                        .map(
                          (project) => DropdownMenuItem(
                            value: project,
                            child: Text(
                              _displayProjectName(project),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      final project =
                          value ?? LocalSessionService.defaultProject;
                      _selectProject(project);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: _t.pick('Usuń projekt', 'Delete project'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed:
                      _selectedProject == LocalSessionService.defaultProject
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

                final availableHeight =
                    constraints.maxHeight - dividerHeight * 2;
                final sessionHeight =
                    (availableHeight * _sidebarSessionFraction)
                        .clamp(110.0, availableHeight - 220.0)
                        .toDouble();
                final lowerHeight = availableHeight - sessionHeight;
                final autoCorrectionsHeight =
                    (lowerHeight * _sidebarAutoCorrectionFraction)
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
            _t.pick(
              'Brak transkrypcji w tym projekcie.',
              'No transcripts in this project.',
            ),
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
          color:
              selected ? Theme.of(context).colorScheme.primaryContainer : null,
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
              tooltip: _t.pick('Opcje sesji', 'Session options'),
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
                PopupMenuItem(
                  value: const _SessionAction.rename(),
                  child: Text(_t.pick('Zmień nazwę', 'Rename')),
                ),
                PopupMenuItem(
                  value: const _SessionAction.delete(),
                  child: Text(_t.pick('Usuń', 'Delete')),
                ),
                const PopupMenuDivider(),
                ..._projects.map(
                  (project) => PopupMenuItem(
                    value: _SessionAction.move(project),
                    enabled: project != summary.project,
                    child: Text(
                      _t.pick(
                        'Przenieś do: ${_displayProjectName(project)}',
                        'Move to: ${_displayProjectName(project)}',
                      ),
                    ),
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
                _t.pick('Autokorekty', 'Auto-corrections'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _displayProjectName(_selectedProject),
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
                      _t.pick(
                        'Popraw termin w transkrypcji, a reguła pojawi się tutaj.',
                        'Correct a term in the transcript and the rule will appear here.',
                      ),
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
                          tooltip: _t.pick(
                            'Usuń autokorektę',
                            'Delete auto-correction',
                          ),
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
        decoration: InputDecoration(
          labelText: _t.pick('Kontekst sesji', 'Session context'),
          hintText: _t.pick(
            'Np. URL, temat spotkania albo krótka notatka',
            'E.g. URL, meeting topic, or a short note',
          ),
          border: const OutlineInputBorder(),
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

  void _toggleExplanationCollapsed(String id) {
    setState(() {
      if (!_collapsedExplanationIds.add(id)) {
        _collapsedExplanationIds.remove(id);
      }
    });
    unawaited(
      _sessionService.writeCollapsedExplanationIds(_collapsedExplanationIds),
    );
  }

  void _setTranscriptTranslationEnabled(bool enabled) {
    setState(() {
      _transcriptTranslationEnabled = enabled;
      _statusMessage = enabled
          ? _t.pick(
              'Tłumaczenie transkrypcji włączone dla kolejnych fragmentów.',
              'Transcript translation enabled for new fragments.',
            )
          : _t.pick(
              'Tłumaczenie transkrypcji wyłączone.',
              'Transcript translation disabled.',
            );
    });
    if (enabled) {
      _scheduleLivePartialCommit();
    } else {
      _livePartialCommitTimer?.cancel();
      _livePartialCommitTimer = null;
    }
    _saveCurrentPreferences();
  }

  void _setTranscriptTranslationLanguage(String language) {
    setState(() {
      _selectedTranscriptTranslationLanguage = language == 'en' ? 'en' : 'pl';
      _statusMessage = _t.pick(
        'Język tłumaczenia zmieniony. Dotyczy kolejnych fragmentów.',
        'Translation language changed. This applies to new fragments.',
      );
    });
    _saveCurrentPreferences();
  }

  Widget _buildResizablePanels() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const dividerWidth = 10.0;
        final availableWidth = constraints.maxWidth - dividerWidth;
        final transcriptionWidth = availableWidth * _transcriptionPanelFraction;
        final explanationWidth = availableWidth - transcriptionWidth;
        final visibleTranscript = _visibleTranscript;
        final visibleTranslation = _visibleTranslation;

        return Row(
          children: [
            SizedBox(
              width: transcriptionWidth,
              child: TranscriptionView(
                segments: visibleTranscript.segments,
                translationSegments: visibleTranslation.segments,
                isTruncated: visibleTranscript.isTruncated,
                translationIsTruncated: visibleTranslation.isTruncated,
                autoScroll: _isListening,
                translationEnabled: _transcriptTranslationEnabled,
                translationLanguage: _selectedTranscriptTranslationLanguage,
                strings: _t,
                onTranslationEnabledChanged: _setTranscriptTranslationEnabled,
                onTranslationLanguageChanged: _setTranscriptTranslationLanguage,
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
                    _transcriptionPanelFraction = (_transcriptionPanelFraction +
                            details.delta.dx / availableWidth)
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
                collapsedIds: _collapsedExplanationIds,
                strings: _t,
                onToggleCollapsed: _toggleExplanationCollapsed,
                onClear: () {
                  setState(() {
                    _explanations.clear();
                    _collapsedExplanationIds.clear();
                  });
                  unawaited(
                    _sessionService
                        .writeCollapsedExplanationIds(_collapsedExplanationIds),
                  );
                },
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
            tooltip: _t.pick('Ustawienia', 'Settings'),
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            tooltip: _t.pick(
              'Otwórz folder transkrypcji i wyjaśnień',
              'Open transcript and explanation folder',
            ),
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
                  items: [
                    const DropdownMenuItem(
                        value: 'en_US', child: Text('English')),
                    DropdownMenuItem(
                      value: 'pl_PL',
                      child: Text(_t.pick('Polski', 'Polish')),
                    ),
                  ],
                  onChanged: _isAudioTransitioning
                      ? null
                      : (value) =>
                          unawaited(_handleTranscriptionLanguageChanged(value)),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: _t.pick(
                    'Co 10 sekund sprawdza krótką próbkę audio przez OpenAI i przełącza PL/EN, gdy rozmowa zmieni język.',
                    'Every 10 seconds checks a short audio probe with OpenAI and switches PL/EN when the conversation changes language.',
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _languageAutoDetectionEnabled,
                        onChanged: _isAudioTransitioning
                            ? null
                            : (value) => _setLanguageAutoDetectionEnabled(
                                  value ?? false,
                                ),
                      ),
                      Text(_t.pick('Auto język', 'Auto language')),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                DropdownButton<String>(
                  value: _selectedSource,
                  items: [
                    DropdownMenuItem(
                      value: 'microphone',
                      child: Text(_t.pick('Mikrofon', 'Microphone')),
                    ),
                    const DropdownMenuItem(
                        value: 'system', child: Text('System audio')),
                    DropdownMenuItem(
                      value: 'both',
                      child: Text(
                        _t.pick(
                          'Mikrofon + system audio',
                          'Microphone + system audio',
                        ),
                      ),
                    ),
                  ],
                  onChanged: (_isListening || _isAudioTransitioning)
                      ? null
                      : (value) {
                          setState(
                              () => _selectedSource = value ?? 'microphone');
                          _saveCurrentPreferences();
                        },
                ),
                const SizedBox(width: 16),
                DropdownButton<String>(
                  value: _selectedAnswerLanguage,
                  items: [
                    DropdownMenuItem(
                      value: 'pl',
                      child:
                          Text(_t.pick('Wyjaśnienia: PL', 'Explanations: PL')),
                    ),
                    const DropdownMenuItem(
                        value: 'en', child: Text('Explanations: EN')),
                  ],
                  onChanged: (_isListening || _isAudioTransitioning)
                      ? null
                      : (value) {
                          setState(
                              () => _selectedAnswerLanguage = value ?? 'pl');
                          _saveCurrentPreferences();
                        },
                ),
                const SizedBox(width: 16),
                Tooltip(
                  message: _t.pick(
                    'Model używany do wyjaśnień klikniętych terminów',
                    'Model used for clicked-term explanations',
                  ),
                  child: DropdownButton<String>(
                    value: _selectedExplanationModel,
                    items: explanationModelOptions
                        .map(
                          (model) => DropdownMenuItem(
                            value: model,
                            child: Text(model),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(
                        () => _selectedExplanationModel =
                            normalizeExplanationModel(value),
                      );
                      _saveCurrentPreferences();
                    },
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 118,
                  child: TextField(
                    controller: _explanationLengthController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: _t.pick('Znaki', 'Chars'),
                      border: const OutlineInputBorder(),
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
                  tooltip: _t.pick('Kopiuj komunikat', 'Copy message'),
                  icon: const Icon(Icons.content_copy),
                  onPressed:
                      (_statusMessage == null || _statusMessage!.trim().isEmpty)
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
                          color:
                              Theme.of(context).dividerColor.withOpacity(0.45),
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
        onPressed: (!_speechEnabled || _isAudioTransitioning)
            ? null
            : _isListening
                ? () => unawaited(_stopListening())
                : () => unawaited(_startListening()),
        child: _isAudioTransitioning
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            : Icon(_isListening ? Icons.stop : Icons.mic),
      ),
    );
  }
}
