import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ExplanationItem {
  final int id;
  final String term;
  final String? explanation;
  final String? error;
  final bool isLoading;

  const ExplanationItem({
    required this.id,
    required this.term,
    this.explanation,
    this.error,
    this.isLoading = false,
  });

  ExplanationItem copyWith({
    String? explanation,
    String? error,
    bool? isLoading,
  }) {
    return ExplanationItem(
      id: id,
      term: term,
      explanation: explanation ?? this.explanation,
      error: error ?? this.error,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class ExplanationHistoryView extends StatelessWidget {
  final List<ExplanationItem> explanations;
  final VoidCallback onClear;

  const ExplanationHistoryView({
    super.key,
    required this.explanations,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text(
                  'Wyjaśnienia',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Wyczyść wyjaśnienia',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: explanations.isEmpty ? null : onClear,
                ),
              ],
            ),
          ),
          Expanded(
            child: explanations.isEmpty
                ? Center(
                    child: Text(
                      'Kliknij słowo w transkrypcji.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemBuilder: (context, index) {
                      final item = explanations[index];
                      return _ExplanationCard(item: item);
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemCount: explanations.length,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ExplanationCard extends StatelessWidget {
  final ExplanationItem item;

  const _ExplanationCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final body = item.error ?? item.explanation ?? '';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.term,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (item.isLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Kopiuj wyjaśnienie',
                    icon: const Icon(Icons.content_copy),
                    onPressed: body.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                              ClipboardData(text: '${item.term}\n\n$body'),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Wyjaśnienie skopiowane'),
                              ),
                            );
                          },
                  ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                body,
                style: item.error == null
                    ? Theme.of(context).textTheme.bodyMedium
                    : Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
