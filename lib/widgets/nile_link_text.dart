import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// Text with tappable links. Used by live chat, where only the host's and
/// crew's links are made tappable ([linkify]) — a viewer's link stays plain
/// text, so nobody can drop a phishing link into someone else's show.
///
/// Finds `http(s)://…` links and bare domains (`nile.tv/x`). Only http and
/// https ever open; a bare domain opens as https.
class NileLinkText extends StatefulWidget {
  const NileLinkText(
    this.text, {
    super.key,
    required this.style,
    this.linkify = true,
    this.prefix,
    this.maxLines,
  });

  final String text;
  final TextStyle style;
  final bool linkify;

  /// Drawn before the text in the same paragraph — chat puts the name here.
  final InlineSpan? prefix;
  final int? maxLines;

  static final _pattern = RegExp(
    r'(https?://[^\s<>]+|\b(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/[^\s<>]*)?)',
    caseSensitive: false,
  );
  static const _trailing = '.,!?:;)]}\'"';

  /// The links in [text] as (start, end, uri). Public for tests.
  static List<(int, int, Uri)> findLinks(String text) {
    final out = <(int, int, Uri)>[];
    for (final m in _pattern.allMatches(text)) {
      var end = m.end;
      while (end > m.start && _trailing.contains(text[end - 1])) {
        end--;
      }
      final raw = text.substring(m.start, end);
      // A bare "word.word" that is really an email address or a version
      // number isn't a link.
      if (m.start > 0 && text[m.start - 1] == '@') continue;
      final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
      if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
        continue;
      }
      if (uri.host.isEmpty || RegExp(r'^[\d.]+$').hasMatch(uri.host)) continue;
      out.add((m.start, end, uri));
    }
    return out;
  }

  @override
  State<NileLinkText> createState() => _NileLinkTextState();
}

class _NileLinkTextState extends State<NileLinkText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  List<InlineSpan> _spans() {
    _disposeRecognizers();
    final text = widget.text;
    if (!widget.linkify) return [TextSpan(text: text)];
    final spans = <InlineSpan>[];
    var at = 0;
    for (final (start, end, uri) in NileLinkText.findLinks(text)) {
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      final r = TapGestureRecognizer()
        ..onTap = () => launchUrl(uri, mode: LaunchMode.externalApplication);
      _recognizers.add(r);
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          recognizer: r,
          mouseCursor: SystemMouseCursors.click,
          style: TextStyle(
            color: NileColors.azure,
            decoration: TextDecoration.underline,
            decorationColor: NileColors.azure,
          ),
        ),
      );
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return spans;
  }

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      style: widget.style,
      children: [?widget.prefix, ..._spans()],
    ),
    maxLines: widget.maxLines,
    overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
  );
}
