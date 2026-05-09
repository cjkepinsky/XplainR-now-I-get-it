class ExplanationCitation {
  final String title;
  final String url;

  const ExplanationCitation({
    required this.title,
    required this.url,
  });

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
    };
  }

  static ExplanationCitation? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;

    final url = value['url'] as String?;
    if (url == null || url.trim().isEmpty) return null;

    return ExplanationCitation(
      title: (value['title'] as String? ?? '').trim(),
      url: url.trim(),
    );
  }
}
