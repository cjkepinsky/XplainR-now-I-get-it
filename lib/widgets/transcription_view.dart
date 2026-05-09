import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

class TranscriptToken {
  final String text;
  final int start;
  final int end;

  const TranscriptToken({
    required this.text,
    required this.start,
    required this.end,
  });
}

class TranscriptDisplaySegment {
  final String text;
  final int startOffset;

  const TranscriptDisplaySegment({
    required this.text,
    required this.startOffset,
  });
}

class TranscriptionView extends StatefulWidget {
  final List<TranscriptDisplaySegment> segments;
  final bool isTruncated;
  final bool autoScroll;
  final AppStrings strings;
  final void Function(TranscriptToken token) onTokenTap;
  final VoidCallback onCopy;
  final VoidCallback onClear;

  const TranscriptionView({
    super.key,
    required this.segments,
    required this.isTruncated,
    required this.autoScroll,
    required this.strings,
    required this.onTokenTap,
    required this.onCopy,
    required this.onClear,
  });

  @override
  State<TranscriptionView> createState() => _TranscriptionViewState();
}

class _TranscriptionViewState extends State<TranscriptionView> {
  final ScrollController _scrollController = ScrollController();

  bool get _hasText =>
      widget.segments.any((segment) => segment.text.trim().isNotEmpty);

  @override
  void didUpdateWidget(covariant TranscriptionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoScroll &&
        _segmentsChanged(oldWidget.segments, widget.segments)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  bool _segmentsChanged(
    List<TranscriptDisplaySegment> previous,
    List<TranscriptDisplaySegment> next,
  ) {
    if (previous.length != next.length) return true;
    if (previous.isEmpty) return false;

    final previousLast = previous.last;
    final nextLast = next.last;
    if (previousLast.startOffset != nextLast.startOffset ||
        previousLast.text != nextLast.text) {
      return true;
    }

    final previousFirst = previous.first;
    final nextFirst = next.first;
    return previousFirst.startOffset != nextFirst.startOffset ||
        previousFirst.text != nextFirst.text;
  }

  List<TranscriptToken> _tokens(TranscriptDisplaySegment segment) {
    final matches = RegExp(r'\S+').allMatches(segment.text);
    return matches
        .map((match) => TranscriptToken(
              text: match.group(0) ?? '',
              start: segment.startOffset + match.start,
              end: segment.startOffset + match.end,
            ))
        .where((token) => token.text.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Text(
                widget.strings.pick('Transkrypcja', 'Transcript'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (widget.isTruncated) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: widget.strings.pick(
                    'Widok pokazuje końcówkę sesji. Pełny tekst jest zapisany lokalnie.',
                    'This view shows the tail of the session. The full text is saved locally.',
                  ),
                  child: Text(
                    widget.strings.pick('ostatni fragment', 'recent excerpt'),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ],
              const Spacer(),
              IconButton(
                tooltip: widget.strings
                    .pick('Kopiuj transkrypcję', 'Copy transcript'),
                icon: const Icon(Icons.content_copy),
                onPressed: _hasText ? widget.onCopy : null,
              ),
              IconButton(
                tooltip: widget.strings.pick(
                  'Wyczyść transkrypcję z widoku',
                  'Clear transcript from view',
                ),
                icon: const Icon(Icons.delete_outline),
                onPressed: _hasText ? widget.onClear : null,
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: _scrollController,
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: widget.segments.length + (widget.isTruncated ? 1 : 0),
              itemBuilder: (context, index) {
                if (widget.isTruncated && index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      widget.strings.pick(
                        'Starsza część transkrypcji jest ukryta w widoku, ale zapisana na dysku.',
                        'Older transcript text is hidden in this view but saved on disk.',
                      ),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  );
                }

                final segmentIndex = index - (widget.isTruncated ? 1 : 0);
                final segment = widget.segments[segmentIndex];
                final tokens = _tokens(segment);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 6,
                    children: tokens
                        .map(
                          (token) => InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => widget.onTokenTap(token),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 1),
                              child: Text(
                                token.text,
                                style:
                                    const TextStyle(fontSize: 16, height: 1.35),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
