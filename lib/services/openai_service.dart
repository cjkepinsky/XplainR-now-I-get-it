import 'package:http/http.dart' as http;
import 'dart:convert';

Future<String> getWordExplanation(String word, String context) async {
  final response = await http.post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer YOUR_API_KEY',
    },
    body: jsonEncode({
      'model': 'gpt-3.5-turbo',
      'messages': [
        {
          'role': 'user',
          'content': 'Wyjaśnij znaczenie słowa "$word" w kontekście: "$context"'
        }
      ],
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'];
  } else {
    throw Exception('Nie udało się uzyskać wyjaśnienia');
  }
}