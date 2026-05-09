import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';

import '../models/explanation_citation.dart';

class OpenAiAnswer {
  final String text;
  final List<ExplanationCitation> citations;

  const OpenAiAnswer({
    required this.text,
    this.citations = const [],
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
    );
  }
}

Future<Directory> _applicationSupportDirectory() async {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
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
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  return [
    File('$home/Library/Application Support/XplainR/settings.json'),
    File('$home/.xplainr/settings.json'),
  ];
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
  );
}

int _maxTokensForCharacterTarget(int targetCharacters) {
  final safeTarget = targetCharacters.clamp(120, 2500).toInt();
  return (safeTarget / 3.0).ceil() + 80;
}

Future<String> getWordExplanation(
  String word,
  String transcriptContext, {
  required String localContext,
  required String sessionContext,
  String answerLanguage = 'pl',
  String interfaceLanguage = 'pl',
  int characterTarget = 300,
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
      'model': 'gpt-4.1-mini',
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

  if (useWebSearch) {
    return _askQuestionWithWebSearch(
      apiKey: apiKey,
      question: question,
      transcriptContext: transcriptContext,
      explanationsContext: explanationsContext,
      sessionContext: sessionContext,
      languageName: languageName,
      instructionLanguage: instructionLanguage,
      interfaceLanguage: interfaceLanguage,
      characterTarget: characterTarget,
    );
  }

  final response = await http.post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': 'gpt-4.1-mini',
      'temperature': 0.2,
      'max_tokens': _maxTokensForCharacterTarget(characterTarget),
      'messages': [
        {
          'role': 'system',
          'content': 'You are a context-aware explainer for live meeting transcripts. '
              'Answer questions using the transcript and existing explanations as the source of truth. '
              'If the answer is not supported by the provided context, say that clearly and mention what is missing. '
              'Do not explain grammar, inflection, etymology, or generic meanings unless they are essential. '
              'Answer in $instructionLanguage. Aim for about $characterTarget characters. '
              'It can be a little shorter or longer if the context requires it. '
              'No preamble, no summary section, no “if you want” follow-up.',
        },
        {
          'role': 'user',
          'content': 'Question: "$question"\n\n'
              'User-provided session context, such as topic, URL, or notes:\n"$sessionContext"\n\n'
              'Transcript context:\n"$transcriptContext"\n\n'
              'Existing explanations and previous Q&A:\n"$explanationsContext"\n\n'
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
      'model': 'gpt-4.1-mini',
      'tools': [
        {
          'type': 'web_search',
          'search_context_size': 'low',
        }
      ],
      'tool_choice': 'required',
      'max_output_tokens': _maxTokensForCharacterTarget(characterTarget),
      'instructions': 'You are a context-aware research assistant for live meeting transcripts. '
          'Use web search for current prices, availability, recent facts, URLs, products, companies, laws, releases, or anything time-sensitive. '
          'Use the transcript and existing explanations as context, but do not expose private transcript details unless they are needed to answer. '
          'Answer in $instructionLanguage. Aim for about $characterTarget characters. '
          'Include concise source references for facts found online. '
          'No preamble, no summary section, no “if you want” follow-up.',
      'input': 'Question: "$question"\n\n'
          'User-provided session context, such as topic, URL, or notes:\n"$sessionContext"\n\n'
          'Transcript context:\n"$transcriptContext"\n\n'
          'Existing explanations and previous Q&A:\n"$explanationsContext"\n\n'
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
