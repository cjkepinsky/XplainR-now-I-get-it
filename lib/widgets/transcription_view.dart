import 'package:flutter/material.dart';

class TranscriptionView extends StatelessWidget {
  final String transcription;
  final Function(String) onWordTap;

  const TranscriptionView({
    super.key,
    required this.transcription,
    required this.onWordTap,
  });

  @override
  Widget build(BuildContext context) {
    final words = transcription.split(' ');
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 4,
        children: words.map((word) => 
          GestureDetector(
            onTap: () => onWordTap(word),
            child: Text(
              word,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ).toList(),
      ),
    );
  }
}