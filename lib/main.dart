import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'screens/transcription_screen.dart';  

void main() {
  runApp(const XplainRApp());
  // Włączamy dostępność dla czytników ekranu
  SemanticsBinding.instance.ensureSemantics();
}

class XplainRApp extends StatelessWidget {
  const XplainRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XplainR',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const TranscriptionScreen(),
    );
  }
}
