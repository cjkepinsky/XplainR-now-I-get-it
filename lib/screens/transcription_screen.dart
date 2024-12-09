import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../widgets/transcription_view.dart';
import '../widgets/explanation_popup.dart';
import '../services/openai_service.dart';

class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  String _transcription = '';
  String? _selectedWord;
  String? _wordExplanation;
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    setState(() {});
  }

  void _startListening() async {
    await _speechToText.listen(
      onResult: (result) {
        setState(() {
          _transcription = result.recognizedWords;
        });
      },
    );
    setState(() {});
  }

  void _stopListening() async {
    await _speechToText.stop();
    setState(() {});
  }

  void _handleWordTap(String word) async {
    if (_selectedWord == word) {
      setState(() {
        _selectedWord = null;
        _wordExplanation = null;
      });
      return;
    }

    final explanation = await getWordExplanation(word, _transcription);
    
    setState(() {
      _selectedWord = word;
      _wordExplanation = explanation;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TalkExplainer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _transcription));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Transkrypcja skopiowana do schowka')),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: TranscriptionView(
              transcription: _transcription,
              onWordTap: _handleWordTap,
            ),
          ),
          if (_selectedWord != null && _wordExplanation != null)
            ExplanationPopup(
              word: _selectedWord!,
              explanation: _wordExplanation!,
              onClose: () => setState(() {
                _selectedWord = null;
                _wordExplanation = null;
              }),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _speechEnabled
            ? (_speechToText.isNotListening ? _startListening : _stopListening)
            : null,
        child: Icon(_speechToText.isNotListening ? Icons.mic_off : Icons.mic),
      ),
    );
  }
}