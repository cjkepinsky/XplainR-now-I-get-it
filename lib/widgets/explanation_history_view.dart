import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_strings.dart';
import '../models/explanation_citation.dart';

class ExplanationItem {
  final int id;
  final String term;
  final String? explanation;
  final String? error;
  final bool isLoading;
  final List<ExplanationCitation> citations;

  const ExplanationItem({
    required this.id,
    required this.term,
    this.explanation,
    this.error,
    this.isLoading = false,
    this.citations = const [],
  });

  ExplanationItem copyWith({
    String? explanation,
    String? error,
    bool? isLoading,
    List<ExplanationCitation>? citations,
  }) {
    return ExplanationItem(
      id: id,
      term: term,
      explanation: explanation ?? this.explanation,
      error: error ?? this.error,
      isLoading: isLoading ?? this.isLoading,
      citations: citations ?? this.citations,
    );
  }
}

class ExplanationHistoryView extends StatelessWidget {
  final List<ExplanationItem> explanations;
  final Set<int> collapsedIds;
  final AppStrings strings;
  final ValueChanged<int> onToggleCollapsed;
  final VoidCallback onClear;

  const ExplanationHistoryView({
    super.key,
    required this.explanations,
    required this.collapsedIds,
    required this.strings,
    required this.onToggleCollapsed,
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
                  strings.pick('Wyjaśnienia', 'Explanations'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  tooltip:
                      strings.pick('Wyczyść wyjaśnienia', 'Clear explanations'),
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
                      strings.pick(
                        'Kliknij słowo w transkrypcji.',
                        'Click a word in the transcript.',
                      ),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemBuilder: (context, index) {
                      final item = explanations[index];
                      return _ExplanationCard(
                        item: item,
                        strings: strings,
                        isCollapsed: collapsedIds.contains(item.id),
                        onToggleCollapsed: () => onToggleCollapsed(item.id),
                      );
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
  final AppStrings strings;
  final bool isCollapsed;
  final VoidCallback onToggleCollapsed;

  const _ExplanationCard({
    required this.item,
    required this.strings,
    required this.isCollapsed,
    required this.onToggleCollapsed,
  });

  @override
  Widget build(BuildContext context) {
    final body = item.error ?? item.explanation ?? '';
    final clipboardText = _clipboardText(body);

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
                else ...[
                  IconButton(
                    tooltip:
                        strings.pick('Kopiuj wyjaśnienie', 'Copy explanation'),
                    icon: const Icon(Icons.content_copy),
                    onPressed: body.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                              ClipboardData(text: clipboardText),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  strings.pick(
                                    'Wyjaśnienie skopiowane',
                                    'Explanation copied',
                                  ),
                                ),
                              ),
                            );
                          },
                  ),
                  if (body.isNotEmpty)
                    IconButton(
                      tooltip: isCollapsed
                          ? strings.pick('Rozwiń', 'Expand')
                          : strings.pick('Zwiń', 'Collapse'),
                      icon: Icon(
                        isCollapsed ? Icons.expand_more : Icons.expand_less,
                      ),
                      onPressed: onToggleCollapsed,
                    ),
                ],
              ],
            ),
            if (body.isNotEmpty && !isCollapsed) ...[
              const SizedBox(height: 8),
              SelectableText(
                body,
                style: item.error == null
                    ? Theme.of(context).textTheme.bodyMedium
                    : Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
              if (item.citations.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  strings.pick('Źródła', 'Sources'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: item.citations
                      .map(
                        (citation) => ActionChip(
                          avatar: const Icon(Icons.open_in_new, size: 16),
                          label: Text(_citationLabel(citation)),
                          onPressed: () => Process.run('open', [citation.url]),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _clipboardText(String body) {
    final citationText = item.citations.map((citation) {
      final title =
          citation.title.trim().isEmpty ? citation.url : citation.title;
      return '$title\n${citation.url}';
    }).join('\n\n');

    return [
      item.term,
      if (body.isNotEmpty) body,
      if (citationText.isNotEmpty)
        '${strings.pick('Źródła', 'Sources')}:\n$citationText',
    ].join('\n\n');
  }

  String _citationLabel(ExplanationCitation citation) {
    if (citation.title.trim().isNotEmpty) return citation.title.trim();
    final uri = Uri.tryParse(citation.url);
    return uri?.host.isNotEmpty == true ? uri!.host : citation.url;
  }
}
