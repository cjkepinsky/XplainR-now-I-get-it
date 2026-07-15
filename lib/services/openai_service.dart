import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/explanation_citation.dart';

const defaultExplanationModel = 'gpt-4.1-mini';
const defaultLanguageDetectionModel = 'whisper-1';
const defaultTranscriptionEngine = 'appleSpeech';
const localWhisperKitTranscriptionEngine = 'localWhisperKit';
const explanationModelOptions = <String>[
  defaultExplanationModel,
  'gpt-4.1',
];
const _fastOpenAiModel = defaultExplanationModel;
const _questionOpenAiModel = 'gpt-4.1';

String normalizeExplanationModel(String? model) {
  final trimmed = model?.trim();
  if (trimmed != null && explanationModelOptions.contains(trimmed)) {
    return trimmed;
  }
  return defaultExplanationModel;
}

String normalizeTranscriptionEngine(String? engine) {
  return engine == localWhisperKitTranscriptionEngine
      ? localWhisperKitTranscriptionEngine
      : defaultTranscriptionEngine;
}

class OpenAiAnswer {
  final String text;
  final List<ExplanationCitation> citations;

  const OpenAiAnswer({
    required this.text,
    this.citations = const [],
  });
}

class DetectedAudioLanguage {
  final String languageCode;
  final String text;

  const DetectedAudioLanguage({
    required this.languageCode,
    required this.text,
  });
}

class OpenAiSettings {
  final String? apiKey;
  final bool rememberApiKey;
  final String interfaceLanguage;
  final String speechLanguage;
  final String answerLanguage;
  final String audioSource;
  final double transcriptionPanelFraction;
  final double sidebarWidth;
  final double sidebarSessionFraction;
  final double sidebarAutoCorrectionFraction;
  final int explanationCharacterTarget;
  final String explanationModel;
  final bool transcriptTranslationEnabled;
  final String transcriptTranslationLanguage;
  final bool languageAutoDetectionEnabled;
  final String transcriptionEngine;

  const OpenAiSettings({
    this.apiKey,
    this.rememberApiKey = true,
    this.interfaceLanguage = 'pl',
    this.speechLanguage = 'en_US',
    this.answerLanguage = 'pl',
    this.audioSource = 'microphone',
    this.transcriptionPanelFraction = 0.6,
    this.sidebarWidth = 300,
    this.sidebarSessionFraction = 0.48,
    this.sidebarAutoCorrectionFraction = 0.56,
    this.explanationCharacterTarget = 300,
    this.explanationModel = defaultExplanationModel,
    this.transcriptTranslationEnabled = false,
    this.transcriptTranslationLanguage = 'pl',
    this.languageAutoDetectionEnabled = false,
    this.transcriptionEngine = defaultTranscriptionEngine,
  });

  OpenAiSettings copyWith({
    String? apiKey,
    bool? rememberApiKey,
    String? interfaceLanguage,
    String? speechLanguage,
    String? answerLanguage,
    String? audioSource,
    double? transcriptionPanelFraction,
    double? sidebarWidth,
    double? sidebarSessionFraction,
    double? sidebarAutoCorrectionFraction,
    int? explanationCharacterTarget,
    String? explanationModel,
    bool? transcriptTranslationEnabled,
    String? transcriptTranslationLanguage,
    bool? languageAutoDetectionEnabled,
    String? transcriptionEngine,
  }) {
    return OpenAiSettings(
      apiKey: apiKey ?? this.apiKey,
      rememberApiKey: rememberApiKey ?? this.rememberApiKey,
      interfaceLanguage: interfaceLanguage ?? this.interfaceLanguage,
      speechLanguage: speechLanguage ?? this.speechLanguage,
      answerLanguage: answerLanguage ?? this.answerLanguage,
      audioSource: audioSource ?? this.audioSource,
      transcriptionPanelFraction:
          transcriptionPanelFraction ?? this.transcriptionPanelFraction,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      sidebarSessionFraction:
          sidebarSessionFraction ?? this.sidebarSessionFraction,
      sidebarAutoCorrectionFraction:
          sidebarAutoCorrectionFraction ?? this.sidebarAutoCorrectionFraction,
      explanationCharacterTarget:
          explanationCharacterTarget ?? this.explanationCharacterTarget,
      explanationModel:
          normalizeExplanationModel(explanationModel ?? this.explanationModel),
      transcriptTranslationEnabled:
          transcriptTranslationEnabled ?? this.transcriptTranslationEnabled,
      transcriptTranslationLanguage:
          transcriptTranslationLanguage ?? this.transcriptTranslationLanguage,
      languageAutoDetectionEnabled:
          languageAutoDetectionEnabled ?? this.languageAutoDetectionEnabled,
      transcriptionEngine: normalizeTranscriptionEngine(
          transcriptionEngine ?? this.transcriptionEngine),
    );
  }
}

Future<Directory> _applicationSupportDirectory() async {
  final home = _userHomePath();
  final directory = Directory('$home/Library/Application Support/XplainR');
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

Future<File> _settingsFileForWrite() async {
  final directory = await _applicationSupportDirectory();
  return File('${directory.path}/settings.json');
}

List<File> _settingsFilesForRead() {
  final home = _userHomePath();
  return [
    File('$home/Library/Application Support/XplainR/settings.json'),
    File('$home/.xplainr/settings.json'),
  ];
}

String _userHomePath() {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  final containerMarker = '${Platform.pathSeparator}Library'
      '${Platform.pathSeparator}Containers'
      '${Platform.pathSeparator}';
  final dataSuffix = '${Platform.pathSeparator}Data';
  final containerIndex = home.indexOf(containerMarker);
  if (containerIndex > 0 && home.endsWith(dataSuffix)) {
    return home.substring(0, containerIndex);
  }
  return home;
}

Future<OpenAiSettings> _getSavedOpenAiSettings() async {
  for (final file in _settingsFilesForRead()) {
    if (!await file.exists()) continue;

    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final rememberApiKey = data['rememberApiKey'] as bool? ?? true;
    final key = data['openAiApiKey'] as String?;
    return OpenAiSettings(
      apiKey: rememberApiKey ? key?.trim() : null,
      rememberApiKey: rememberApiKey,
      interfaceLanguage: data['interfaceLanguage'] as String? ?? 'pl',
      speechLanguage: data['speechLanguage'] as String? ?? 'en_US',
      answerLanguage: data['answerLanguage'] as String? ?? 'pl',
      audioSource: data['audioSource'] as String? ?? 'microphone',
      transcriptionPanelFraction:
          (data['transcriptionPanelFraction'] as num?)?.toDouble() ?? 0.6,
      sidebarWidth: (data['sidebarWidth'] as num?)?.toDouble() ?? 300,
      sidebarSessionFraction:
          (data['sidebarSessionFraction'] as num?)?.toDouble() ?? 0.48,
      sidebarAutoCorrectionFraction:
          (data['sidebarAutoCorrectionFraction'] as num?)?.toDouble() ?? 0.56,
      explanationCharacterTarget:
          (data['explanationCharacterTarget'] as num?)?.toInt() ?? 300,
      explanationModel:
          normalizeExplanationModel(data['explanationModel'] as String?),
      transcriptTranslationEnabled:
          data['transcriptTranslationEnabled'] as bool? ?? false,
      transcriptTranslationLanguage:
          data['transcriptTranslationLanguage'] as String? ?? 'pl',
      languageAutoDetectionEnabled:
          data['languageAutoDetectionEnabled'] as bool? ?? false,
      transcriptionEngine:
          normalizeTranscriptionEngine(data['transcriptionEngine'] as String?),
    );
  }

  return const OpenAiSettings();
}

Future<OpenAiSettings> getOpenAiSettings() async {
  final savedSettings = await _getSavedOpenAiSettings();
  final envKey = Platform.environment['OPENAI_API_KEY'];
  if (envKey != null && envKey.trim().isNotEmpty) {
    return savedSettings.copyWith(
      apiKey: envKey.trim(),
      rememberApiKey: false,
    );
  }

  return savedSettings;
}

Future<String?> getOpenAiApiKey() async {
  return (await getOpenAiSettings()).apiKey;
}

Future<void> saveOpenAiSettings({
  required String apiKey,
  required bool rememberApiKey,
  String? interfaceLanguage,
  String? speechLanguage,
  String? answerLanguage,
  String? audioSource,
  double? transcriptionPanelFraction,
  double? sidebarWidth,
  double? sidebarSessionFraction,
  double? sidebarAutoCorrectionFraction,
  int? explanationCharacterTarget,
  String? explanationModel,
  bool? transcriptTranslationEnabled,
  String? transcriptTranslationLanguage,
  bool? languageAutoDetectionEnabled,
  String? transcriptionEngine,
}) async {
  final currentSettings = await getOpenAiSettings();
  final file = await _settingsFileForWrite();
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'openAiApiKey': rememberApiKey ? apiKey.trim() : '',
      'rememberApiKey': rememberApiKey,
      'interfaceLanguage':
          interfaceLanguage ?? currentSettings.interfaceLanguage,
      'speechLanguage': speechLanguage ?? currentSettings.speechLanguage,
      'answerLanguage': answerLanguage ?? currentSettings.answerLanguage,
      'audioSource': audioSource ?? currentSettings.audioSource,
      'transcriptionPanelFraction': transcriptionPanelFraction ??
          currentSettings.transcriptionPanelFraction,
      'sidebarWidth': sidebarWidth ?? currentSettings.sidebarWidth,
      'sidebarSessionFraction':
          sidebarSessionFraction ?? currentSettings.sidebarSessionFraction,
      'sidebarAutoCorrectionFraction': sidebarAutoCorrectionFraction ??
          currentSettings.sidebarAutoCorrectionFraction,
      'explanationCharacterTarget': explanationCharacterTarget ??
          currentSettings.explanationCharacterTarget,
      'explanationModel': normalizeExplanationModel(
          explanationModel ?? currentSettings.explanationModel),
      'transcriptTranslationEnabled': transcriptTranslationEnabled ??
          currentSettings.transcriptTranslationEnabled,
      'transcriptTranslationLanguage': transcriptTranslationLanguage ??
          currentSettings.transcriptTranslationLanguage,
      'languageAutoDetectionEnabled': languageAutoDetectionEnabled ??
          currentSettings.languageAutoDetectionEnabled,
      'transcriptionEngine': normalizeTranscriptionEngine(
        transcriptionEngine ?? currentSettings.transcriptionEngine,
      ),
    }),
  );
}

Future<void> saveAppPreferences({
  required String interfaceLanguage,
  required String speechLanguage,
  required String answerLanguage,
  required String audioSource,
  required double transcriptionPanelFraction,
  required double sidebarWidth,
  required double sidebarSessionFraction,
  required double sidebarAutoCorrectionFraction,
  required int explanationCharacterTarget,
  required String explanationModel,
  required bool transcriptTranslationEnabled,
  required String transcriptTranslationLanguage,
  required bool languageAutoDetectionEnabled,
  required String transcriptionEngine,
}) async {
  final settings = await getOpenAiSettings();
  await saveOpenAiSettings(
    apiKey: settings.apiKey ?? '',
    rememberApiKey: settings.rememberApiKey,
    interfaceLanguage: interfaceLanguage,
    speechLanguage: speechLanguage,
    answerLanguage: answerLanguage,
    audioSource: audioSource,
    transcriptionPanelFraction: transcriptionPanelFraction,
    sidebarWidth: sidebarWidth,
    sidebarSessionFraction: sidebarSessionFraction,
    sidebarAutoCorrectionFraction: sidebarAutoCorrectionFraction,
    explanationCharacterTarget: explanationCharacterTarget,
    explanationModel: explanationModel,
    transcriptTranslationEnabled: transcriptTranslationEnabled,
    transcriptTranslationLanguage: transcriptTranslationLanguage,
    languageAutoDetectionEnabled: languageAutoDetectionEnabled,
    transcriptionEngine: transcriptionEngine,
  );
}

String? _normalizeDetectedLanguage(dynamic value) {
  final raw = value?.toString().trim().toLowerCase();
  if (raw == null || raw.isEmpty) return null;

  if (raw == 'pl' || raw == 'polish' || raw == 'polski') {
    return 'pl';
  }
  if (raw == 'en' || raw == 'eng' || raw == 'english') {
    return 'en';
  }
  return null;
}

Future<DetectedAudioLanguage?> detectSpeechLanguageFromAudio(
  Uint8List wavBytes, {
  String interfaceLanguage = 'pl',
}) async {
  final apiKey = await getOpenAiApiKey();
  if (apiKey == null) {
    throw Exception(
      interfaceLanguage == 'en'
          ? 'OpenAI API key is not configured.'
          : 'Brak skonfigurowanego OpenAI API key.',
    );
  }
  if (wavBytes.isEmpty) return null;

  final request = http.MultipartRequest(
    'POST',
    Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
  )
    ..headers['Authorization'] = 'Bearer $apiKey'
    ..fields['model'] = defaultLanguageDetectionModel
    ..fields['response_format'] = 'verbose_json'
    ..files.add(
      http.MultipartFile.fromBytes(
        'file',
        wavBytes,
        filename: 'xplainr-language-probe.wav',
      ),
    );

  final streamedResponse =
      await request.send().timeout(const Duration(seconds: 25));
  final response = await http.Response.fromStream(streamedResponse);

  if (response.statusCode != 200) {
    final responseBody = response.body.length > 500
        ? '${response.body.substring(0, 500)}...'
        : response.body;
    throw Exception(
      interfaceLanguage == 'en'
          ? 'Could not detect speech language: ${response.statusCode} $responseBody'
          : 'Nie udało się wykryć języka mowy: ${response.statusCode} $responseBody',
    );
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final languageCode = _normalizeDetectedLanguage(data['language']);
  if (languageCode == null) return null;

  return DetectedAudioLanguage(
    languageCode: languageCode,
    text: (data['text'] as String? ?? '').trim(),
  );
}

int _maxTokensForCharacterTarget(int targetCharacters) {
  final safeTarget = targetCharacters.clamp(120, 2500).toInt();
  return (safeTarget / 3.0).ceil() + 80;
}

int _maxTokensForQuestionTarget(int targetCharacters) {
  final safeTarget = targetCharacters.clamp(120, 6000).toInt();
  return (safeTarget / 3.0).ceil() + 120;
}

int _maxTokensForTranslation(String text) {
  final estimatedCharacters = (text.length * 1.35).ceil();
  return (estimatedCharacters / 3.2).ceil().clamp(120, 2500).toInt();
}

int _effectiveQuestionCharacterTarget(String question, int requestedTarget) {
  if (_looksLikeExhaustiveTranscriptQuestion(question)) {
    return requestedTarget < 3500 ? 3500 : requestedTarget;
  }
  return requestedTarget;
}

bool _looksLikeExhaustiveTranscriptQuestion(String question) {
  final normalized = question.toLowerCase();
  const exhaustiveMarkers = [
    'wszystkie',
    'wszystko',
    'każde',
    'kazde',
    'pełn',
    'peln',
    'szczegół',
    'szczegol',
    'wylistuj',
    'wypisz',
    'lista',
    'list',
    'all',
    'every',
    'complete',
    'detailed',
  ];
  const transcriptExtractionMarkers = [
    'wniosk',
    'pytan',
    'pytań',
    'decyz',
    'ustal',
    'zadani',
    'action item',
    'question',
    'conclusion',
    'decision',
    'takeaway',
  ];

  return exhaustiveMarkers.any(normalized.contains) &&
      transcriptExtractionMarkers.any(normalized.contains);
}

String _numberedTranscriptContext(String transcriptContext) {
  final segments = transcriptContext
      .split(RegExp(r'\n{2,}'))
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty) return '';

  return [
    for (var index = 0; index < segments.length; index += 1)
      '[T${(index + 1).toString().padLeft(3, '0')}] ${segments[index]}',
  ].join('\n\n');
}

String _strictTranscriptQaInstructions({
  required String instructionLanguage,
  required int characterTarget,
  required bool useWebSearch,
}) {
  final webRule = useWebSearch
      ? 'For current external facts found through web search, cite web sources. For facts about the meeting itself, still require transcript evidence.'
      : 'Do not use outside knowledge or web facts.';

  return 'You are a strict evidence-based analyst of live meeting transcripts. '
      'The numbered transcript fragments are the only source of truth for what happened in the meeting. '
      'Never invent questions, conclusions, decisions, names, dates, numbers, technologies, or action items. '
      'Existing explanations and previous Q&A are secondary notes only; use them only to understand terminology, never as evidence that something happened. '
      'Every factual bullet or listed item must include at least one transcript fragment id, such as [T012], and a very short quote or paraphrase from that fragment. '
      'If a claim cannot be tied to a transcript fragment id, omit it. '
      'For requests like "list all questions", include only explicit questions or clear requests from speakers. '
      'For requests like "list all conclusions/takeaways", include only conclusions, decisions, or takeaways directly stated or tightly entailed by a cited fragment; do not infer broad themes. '
      'If the transcript does not contain enough evidence, say that directly instead of guessing. '
      '$webRule '
      'Format the answer as scannable sections. Each section must use exactly this structure: '
      'a Markdown H3 heading line in the form "### <1-4 word heading>", then one concise paragraph, then a separate evidence line. '
      'For Polish answers use "Dowód: [T012] \\"short quote or paraphrase\\"". For English answers use "Evidence: [T012] \\"short quote or paraphrase\\"". '
      'Put the evidence line directly below the paragraph, not inside the same paragraph. '
      'Do not use bullet points unless the user explicitly asks for a checklist. Prefer several short headed sections over one long list. '
      'Answer in $instructionLanguage. Aim for about $characterTarget characters, but prefer an incomplete evidence-backed answer over a complete-looking invented answer. '
      'No preamble, no generic summary section, no “if you want” follow-up.';
}

Future<String> translateTranscriptSegment(
  String segment, {
  required String targetLanguage,
  required String sourceLanguage,
  required String sessionContext,
  String interfaceLanguage = 'pl',
}) async {
  final apiKey = await getOpenAiApiKey();
  if (apiKey == null) {
    throw Exception(
      interfaceLanguage == 'en'
          ? 'OpenAI API key is not configured.'
          : 'Brak skonfigurowanego OpenAI API key.',
    );
  }

  final normalizedSegment = segment.trim();
  if (normalizedSegment.isEmpty) return '';

  final targetName = targetLanguage == 'en' ? 'English' : 'Polish';
  final configuredSourceName = sourceLanguage == 'pl' ? 'Polish' : 'English';

  final response = await http.post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': _fastOpenAiModel,
      'temperature': 0.1,
      'max_tokens': _maxTokensForTranslation(normalizedSegment),
      'messages': [
        {
          'role': 'system',
          'content': 'You translate live meeting transcript fragments into $targetName. '
              'The configured speech recognition language is $configuredSourceName, but the fragment may contain Polish, English, or mixed technical speech, so detect the source language automatically. '
              'Preserve meaning, speaker intent, technical terms, code identifiers, product names, framework names, file names, commands, and acronyms. '
              'If the fragment is already in $targetName, return a cleaned-up same-language version without changing the meaning. '
              'Do not add explanations, commentary, summaries, markdown, or quotes. '
              'Return only the translated transcript fragment.',
        },
        {
          'role': 'user',
          'content': 'Session context, if useful:\n"$sessionContext"\n\n'
              'Transcript fragment:\n"$normalizedSegment"',
        }
      ],
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return (data['choices'][0]['message']['content'] as String? ?? '').trim();
  }

  final responseBody = response.body.length > 500
      ? '${response.body.substring(0, 500)}...'
      : response.body;
  throw Exception(
    interfaceLanguage == 'en'
        ? 'Could not translate transcript: ${response.statusCode} $responseBody'
        : 'Nie udało się przetłumaczyć transkrypcji: ${response.statusCode} $responseBody',
  );
}

Future<String> getWordExplanation(
  String word,
  String transcriptContext, {
  required String localContext,
  required String sessionContext,
  String answerLanguage = 'pl',
  String interfaceLanguage = 'pl',
  int characterTarget = 300,
  String explanationModel = defaultExplanationModel,
}) async {
  final apiKey = await getOpenAiApiKey();
  if (apiKey == null) {
    throw Exception(
      interfaceLanguage == 'en'
          ? 'OpenAI API key is not configured.'
          : 'Brak skonfigurowanego OpenAI API key.',
    );
  }

  final languageName = answerLanguage == 'en' ? 'English' : 'Polish';
  final instructionLanguage = answerLanguage == 'en' ? 'English' : 'Polish';

  final response = await http.post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': normalizeExplanationModel(explanationModel),
      'temperature': 0.2,
      'max_tokens': _maxTokensForCharacterTarget(characterTarget),
      'messages': [
        {
          'role': 'system',
          'content': 'You are a context-aware explainer for live meeting transcripts. '
              'Explain what the clicked word or phrase means in this conversation, not as a dictionary entry. '
              'Infer the smallest useful multi-word term around the clicked word when needed. '
              'Do not explain grammar, inflection, etymology, or generic meanings unless they are essential. '
              'Answer in $instructionLanguage. Aim for about $characterTarget characters. '
              'It can be a little shorter or longer if the context requires it. '
              'No preamble, no summary section, no “if you want” follow-up.',
        },
        {
          'role': 'user',
          'content': 'Clicked text: "$word"\n\n'
              'User-provided session context, such as topic, URL, or notes:\n"$sessionContext"\n\n'
              'Local transcript context, primary source:\n"$localContext"\n\n'
              'Broader transcript context, use only if helpful:\n"$transcriptContext"\n\n'
              'Explain the relevant term or phrase in $languageName.',
        }
      ],
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'];
  } else {
    throw Exception(
      interfaceLanguage == 'en'
          ? 'Could not get an explanation: ${response.statusCode}'
          : 'Nie udało się uzyskać wyjaśnienia: ${response.statusCode}',
    );
  }
}

Future<OpenAiAnswer> askQuestionAboutTranscript(
  String question,
  String transcriptContext, {
  required String explanationsContext,
  required String sessionContext,
  String answerLanguage = 'pl',
  String interfaceLanguage = 'pl',
  int characterTarget = 300,
  bool useWebSearch = false,
}) async {
  final apiKey = await getOpenAiApiKey();
  if (apiKey == null) {
    throw Exception(
      interfaceLanguage == 'en'
          ? 'OpenAI API key is not configured.'
          : 'Brak skonfigurowanego OpenAI API key.',
    );
  }

  final languageName = answerLanguage == 'en' ? 'English' : 'Polish';
  final instructionLanguage = answerLanguage == 'en' ? 'English' : 'Polish';
  final effectiveCharacterTarget =
      _effectiveQuestionCharacterTarget(question, characterTarget);
  final numberedTranscriptContext =
      _numberedTranscriptContext(transcriptContext);

  if (useWebSearch) {
    return _askQuestionWithWebSearch(
      apiKey: apiKey,
      question: question,
      transcriptContext: numberedTranscriptContext,
      explanationsContext: explanationsContext,
      sessionContext: sessionContext,
      languageName: languageName,
      instructionLanguage: instructionLanguage,
      interfaceLanguage: interfaceLanguage,
      characterTarget: effectiveCharacterTarget,
    );
  }

  final response = await http.post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': _questionOpenAiModel,
      'temperature': 0,
      'max_tokens': _maxTokensForQuestionTarget(effectiveCharacterTarget),
      'messages': [
        {
          'role': 'system',
          'content': _strictTranscriptQaInstructions(
            instructionLanguage: instructionLanguage,
            characterTarget: effectiveCharacterTarget,
            useWebSearch: false,
          ),
        },
        {
          'role': 'user',
          'content': 'Question: "$question"\n\n'
              'User-provided session context, such as topic, URL, or notes:\n"$sessionContext"\n\n'
              'Numbered transcript fragments, primary evidence:\n$numberedTranscriptContext\n\n'
              'Secondary explanations and previous Q&A, not evidence by themselves:\n"$explanationsContext"\n\n'
              'Answer the question in $languageName.',
        }
      ],
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return OpenAiAnswer(
      text: data['choices'][0]['message']['content'] as String? ?? '',
      citations: _citationsFromChatCompletion(data),
    );
  } else {
    throw Exception(
      interfaceLanguage == 'en'
          ? 'Could not get an answer: ${response.statusCode}'
          : 'Nie udało się uzyskać odpowiedzi: ${response.statusCode}',
    );
  }
}

Future<OpenAiAnswer> _askQuestionWithWebSearch({
  required String apiKey,
  required String question,
  required String transcriptContext,
  required String explanationsContext,
  required String sessionContext,
  required String languageName,
  required String instructionLanguage,
  required String interfaceLanguage,
  required int characterTarget,
}) async {
  final response = await http.post(
    Uri.parse('https://api.openai.com/v1/responses'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': _questionOpenAiModel,
      'tools': [
        {
          'type': 'web_search',
          'search_context_size': 'low',
        }
      ],
      'tool_choice': 'required',
      'temperature': 0,
      'max_output_tokens': _maxTokensForQuestionTarget(characterTarget),
      'instructions': _strictTranscriptQaInstructions(
        instructionLanguage: instructionLanguage,
        characterTarget: characterTarget,
        useWebSearch: true,
      ),
      'input': 'Question: "$question"\n\n'
          'User-provided session context, such as topic, URL, or notes:\n"$sessionContext"\n\n'
          'Numbered transcript fragments, primary meeting evidence:\n$transcriptContext\n\n'
          'Secondary explanations and previous Q&A, not evidence by themselves:\n"$explanationsContext"\n\n'
          'Answer the question in $languageName.',
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return _answerFromResponsesApi(data);
  }

  throw Exception(
    interfaceLanguage == 'en'
        ? 'Could not get a web research answer: ${response.statusCode}'
        : 'Nie udało się uzyskać odpowiedzi z web researchu: ${response.statusCode}',
  );
}

OpenAiAnswer _answerFromResponsesApi(Map<String, dynamic> data) {
  final output = data['output'];
  final buffer = StringBuffer();
  final citations = <ExplanationCitation>[];

  if (output is List) {
    for (final item in output) {
      if (item is! Map<String, dynamic> || item['type'] != 'message') continue;
      final content = item['content'];
      if (content is! List) continue;

      for (final part in content) {
        if (part is! Map<String, dynamic>) continue;
        final text = part['text'] as String?;
        if (text != null && text.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write('\n\n');
          buffer.write(text);
        }
        citations.addAll(_citationsFromAnnotations(part['annotations']));
      }
    }
  }

  final outputText = data['output_text'] as String?;
  final text = buffer.isNotEmpty ? buffer.toString() : outputText ?? '';

  return OpenAiAnswer(
    text: text,
    citations: _dedupeCitations(citations),
  );
}

List<ExplanationCitation> _citationsFromChatCompletion(dynamic data) {
  if (data is! Map<String, dynamic>) return const [];
  final choices = data['choices'];
  if (choices is! List || choices.isEmpty) return const [];
  final firstChoice = choices.first;
  if (firstChoice is! Map<String, dynamic>) return const [];
  final message = firstChoice['message'];
  if (message is! Map<String, dynamic>) return const [];
  return _dedupeCitations(_citationsFromAnnotations(message['annotations']));
}

List<ExplanationCitation> _citationsFromAnnotations(dynamic annotations) {
  if (annotations is! List) return const [];

  return annotations
      .map((annotation) {
        if (annotation is! Map<String, dynamic>) return null;
        final citation = annotation['url_citation'];
        final source = citation is Map<String, dynamic> ? citation : annotation;
        final url = source['url'] as String?;
        if (url == null || url.trim().isEmpty) return null;

        return ExplanationCitation(
          title: (source['title'] as String? ?? '').trim(),
          url: url.trim(),
        );
      })
      .whereType<ExplanationCitation>()
      .toList();
}

List<ExplanationCitation> _dedupeCitations(
  List<ExplanationCitation> citations,
) {
  final seen = <String>{};
  final deduped = <ExplanationCitation>[];
  for (final citation in citations) {
    if (seen.add(citation.url)) {
      deduped.add(citation);
    }
  }
  return deduped;
}
