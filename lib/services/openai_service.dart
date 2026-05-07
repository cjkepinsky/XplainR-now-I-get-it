import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';

class OpenAiSettings {
  final String? apiKey;
  final bool rememberApiKey;
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
    this.speechLanguage = 'en_US',
    this.answerLanguage = 'pl',
    this.audioSource = 'microphone',
    this.transcriptionPanelFraction = 0.6,
    this.sidebarWidth = 300,
    this.sidebarSessionFraction = 0.48,
    this.sidebarAutoCorrectionFraction = 0.56,
    this.explanationCharacterTarget = 300,
  });
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

Future<OpenAiSettings> getOpenAiSettings() async {
  final envKey = Platform.environment['OPENAI_API_KEY'];
  if (envKey != null && envKey.trim().isNotEmpty) {
    return OpenAiSettings(apiKey: envKey.trim(), rememberApiKey: false);
  }

  for (final file in _settingsFilesForRead()) {
    if (!await file.exists()) continue;

    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final rememberApiKey = data['rememberApiKey'] as bool? ?? true;
    final key = data['openAiApiKey'] as String?;
    return OpenAiSettings(
      apiKey: rememberApiKey ? key?.trim() : null,
      rememberApiKey: rememberApiKey,
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

Future<String?> getOpenAiApiKey() async {
  return (await getOpenAiSettings()).apiKey;
}

Future<void> saveOpenAiSettings({
  required String apiKey,
  required bool rememberApiKey,
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
      'explanationCharacterTarget':
          explanationCharacterTarget ?? currentSettings.explanationCharacterTarget,
    }),
  );
}

Future<void> saveAppPreferences({
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
  int characterTarget = 300,
}) async {
  final apiKey = await getOpenAiApiKey();
  if (apiKey == null) {
    throw Exception('Brak skonfigurowanego OpenAI API key.');
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
          'content':
              'You are a context-aware explainer for live meeting transcripts. '
              'Explain what the clicked word or phrase means in this conversation, not as a dictionary entry. '
              'Infer the smallest useful multi-word term around the clicked word when needed. '
              'Do not explain grammar, inflection, etymology, or generic meanings unless they are essential. '
              'Answer in $instructionLanguage. Aim for about $characterTarget characters. '
              'It can be a little shorter or longer if the context requires it. '
              'No preamble, no summary section, no “if you want” follow-up.',
        },
        {
          'role': 'user',
          'content':
              'Clicked text: "$word"\n\n'
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
    throw Exception('Nie udało się uzyskać wyjaśnienia: ${response.statusCode}');
  }
}

Future<String> askQuestionAboutTranscript(
  String question,
  String transcriptContext, {
  required String explanationsContext,
  required String sessionContext,
  String answerLanguage = 'pl',
  int characterTarget = 300,
}) async {
  final apiKey = await getOpenAiApiKey();
  if (apiKey == null) {
    throw Exception('Brak skonfigurowanego OpenAI API key.');
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
          'content':
              'You are a context-aware explainer for live meeting transcripts. '
              'Answer questions using the transcript and existing explanations as the source of truth. '
              'If the answer is not supported by the provided context, say that clearly and mention what is missing. '
              'Do not explain grammar, inflection, etymology, or generic meanings unless they are essential. '
              'Answer in $instructionLanguage. Aim for about $characterTarget characters. '
              'It can be a little shorter or longer if the context requires it. '
              'No preamble, no summary section, no “if you want” follow-up.',
        },
        {
          'role': 'user',
          'content':
              'Question: "$question"\n\n'
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
    return data['choices'][0]['message']['content'];
  } else {
    throw Exception('Nie udało się uzyskać odpowiedzi: ${response.statusCode}');
  }
}
