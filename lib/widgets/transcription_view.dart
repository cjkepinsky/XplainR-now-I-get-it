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
  final List<TranscriptDisplaySegment> translationSegments;
  final bool isTruncated;
  final bool translationIsTruncated;
  final bool autoScroll;
  final bool translationEnabled;
  final String translationLanguage;
  final AppStrings strings;
  final ValueChanged<bool> onTranslationEnabledChanged;
  final ValueChanged<String> onTranslationLanguageChanged;
  final void Function(TranscriptToken token) onTokenTap;
  final VoidCallback onCopy;
  final VoidCallback onClear;

  const TranscriptionView({
    super.key,
    required this.segments,
    required this.translationSegments,
    required this.isTruncated,
    required this.translationIsTruncated,
    required this.autoScroll,
    required this.translationEnabled,
    required this.translationLanguage,
    required this.strings,
    required this.onTranslationEnabledChanged,
    required this.onTranslationLanguageChanged,
    required this.onTokenTap,
    required this.onCopy,
    required this.onClear,
  });

  @override
  State<TranscriptionView> createState() => _TranscriptionViewState();
}

class _TranscriptionViewState extends State<TranscriptionView> {
  final ScrollController _originalScrollController = ScrollController();
  final ScrollController _translationScrollController = ScrollController();

  bool get _hasText =>
      widget.segments.any((segment) => segment.text.trim().isNotEmpty);
  bool get _hasTranslation => widget.translationSegments
      .any((segment) => segment.text.trim().isNotEmpty);

  @override
  void didUpdateWidget(covariant TranscriptionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoScroll &&
        _segmentsChanged(oldWidget.segments, widget.segments)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToBottom(_originalScrollController),
      );
    }
    if (widget.autoScroll &&
        widget.translationEnabled &&
        _segmentsChanged(
          oldWidget.translationSegments,
          widget.translationSegments,
        )) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToBottom(_translationScrollController),
      );
    }
  }

  @override
  void dispose() {
    _originalScrollController.dispose();
    _translationScrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom(ScrollController controller) {
    if (!controller.hasClients) return;
    controller.animateTo(
      controller.position.maxScrollExtent,
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
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      widget.strings.pick('Transkrypcja', 'Transcript'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(
                      height: 32,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: widget.translationEnabled,
                            onChanged: (value) =>
                                widget.onTranslationEnabledChanged(
                              value ?? false,
                            ),
                          ),
                          Text(
                            widget.strings
                                .pick('Przetłumacz na', 'Translate to'),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(width: 6),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: widget.translationLanguage,
                              isDense: true,
                              items: [
                                DropdownMenuItem(
                                  value: 'pl',
                                  child: Text(
                                    widget.strings.pick('Polski', 'Polish'),
                                  ),
                                ),
                                const DropdownMenuItem(
                                  value: 'en',
                                  child: Text('English'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  widget.onTranslationLanguageChanged(value);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.isTruncated)
                      Tooltip(
                        message: widget.strings.pick(
                          'Widok pokazuje końcówkę sesji. Pełny tekst jest zapisany lokalnie.',
                          'This view shows the tail of the session. The full text is saved locally.',
                        ),
                        child: Text(
                          widget.strings.pick(
                            'ostatni fragment',
                            'recent excerpt',
                          ),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: widget.strings
                    .pick('Kopiuj transkrypcję', 'Copy transcript'),
                icon: const Icon(Icons.content_copy),
                onPressed:
                    (_hasText || (widget.translationEnabled && _hasTranslation))
                        ? widget.onCopy
                        : null,
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
          child: widget.translationEnabled
              ? Column(
                  children: [
                    Expanded(
                      child: _buildSegmentList(
                        context,
                        controller: _originalScrollController,
                        segments: widget.segments,
                        isTruncated: widget.isTruncated,
                        isOriginal: true,
                        label: widget.strings.pick('Oryginał', 'Original'),
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: Theme.of(context).dividerColor,
                    ),
                    Expanded(
                      child: _buildSegmentList(
                        context,
                        controller: _translationScrollController,
                        segments: widget.translationSegments,
                        isTruncated: widget.translationIsTruncated,
                        isOriginal: false,
                        label: widget.strings.pick(
                          'Tłumaczenie',
                          'Translation',
                        ),
                      ),
                    ),
                  ],
                )
              : _buildSegmentList(
                  context,
                  controller: _originalScrollController,
                  segments: widget.segments,
                  isTruncated: widget.isTruncated,
                  isOriginal: true,
                ),
        ),
      ],
    );
  }

  Widget _buildSegmentList(
    BuildContext context, {
    required ScrollController controller,
    required List<TranscriptDisplaySegment> segments,
    required bool isTruncated,
    required bool isOriginal,
    String? label,
  }) {
    final hasContent =
        segments.any((segment) => segment.text.trim().isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        Expanded(
          child: hasContent || isTruncated
              ? Scrollbar(
                  controller: controller,
                  child: ListView.builder(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: segments.length + (isTruncated ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (isTruncated && index == 0) {
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

                      final segmentIndex = index - (isTruncated ? 1 : 0);
                      final segment = segments[segmentIndex];
                      return isOriginal
                          ? _buildOriginalSegment(segment)
                          : _buildTranslatedSegment(context, segment);
                    },
                  ),
                )
              : Center(
                  child: Text(
                    isOriginal
                        ? widget.strings.pick(
                            'Brak transkrypcji.',
                            'No transcript yet.',
                          )
                        : widget.strings.pick(
                            'Tłumaczenie pojawi się po kolejnych fragmentach transkrypcji.',
                            'Translation will appear after new transcript fragments.',
                          ),
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildOriginalSegment(TranscriptDisplaySegment segment) {
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
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Text(
                    token.text,
                    style: const TextStyle(fontSize: 16, height: 1.35),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildTranslatedSegment(
    BuildContext context,
    TranscriptDisplaySegment segment,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SelectableText(
        segment.text,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.35),
      ),
    );
  }
}
