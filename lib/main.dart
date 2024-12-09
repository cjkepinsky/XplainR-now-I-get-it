import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'screens/transcription_screen.dart';  

void main() {
  runApp(const TalkExplainerApp());
  // Włączamy dostępność dla czytników ekranu
  SemanticsBinding.instance.ensureSemantics();
}

class TalkExplainerApp extends StatelessWidget {
  const TalkExplainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TalkExplainer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const TranscriptionScreen(),
    );
  }
}
