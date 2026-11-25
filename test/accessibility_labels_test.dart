// Keeps every icon-only control labelled.
//
// P4 #40 found 66 IconButtons against 54 tooltips, three Semantics usages in
// the whole app, and VoiceOver reading the like/repost/share row as three
// anonymous buttons. Labelling them once is easy; the reason it had drifted is
// that nothing checked, and the next icon-only button somebody adds will
// silently be unlabelled again.
//
// In Flutter an IconButton's `tooltip` IS its accessibility label, so this one
// property covers hover on desktop and VoiceOver/TalkBack on mobile at once.
//
// Source-scanning rather than widget-pumping on purpose: pumping every screen
// that owns an IconButton would need a Supabase session, a live stream and a
// camera. This catches the whole app in milliseconds and cannot be satisfied
// by a control that is never rendered in a test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Extracts the balanced `IconButton( … )` argument blocks from [source].
List<({int line, String block})> _iconButtonBlocks(String source) {
  final out = <({int line, String block})>[];
  // `\b` so IconButton.styleFrom( — which is a style, not a control — doesn't
  // match and produce a false positive.
  for (final m in RegExp(r'\bIconButton\(').allMatches(source)) {
    var depth = 0;
    final start = m.end - 1;
    for (var j = start; j < source.length; j++) {
      final c = source[j];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) {
          out.add((
            line: '\n'.allMatches(source.substring(0, m.start)).length + 1,
            block: source.substring(start, j + 1),
          ));
          break;
        }
      }
    }
  }
  return out;
}

void main() {
  final dartFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('lib/ is non-empty — the scan below is only as good as its input', () {
    expect(dartFiles.length, greaterThan(50));
  });

  test('every IconButton carries a tooltip', () {
    final unlabelled = <String>[];
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      for (final hit in _iconButtonBlocks(source)) {
        if (!hit.block.contains('tooltip:')) {
          unlabelled.add('${file.path}:${hit.line}');
        }
      }
    }
    expect(
      unlabelled,
      isEmpty,
      reason:
          'IconButton.tooltip is also its screen-reader label. Add one — and '
          'if the control toggles, make the tooltip reflect the CURRENT state '
          '("Mute" vs "Unmute"), not the icon.\nMissing:\n  '
          '${unlabelled.join('\n  ')}',
    );
  });

  test('the like control announces itself, and its state', () {
    // The specific control the review called out. `toggled:` is what lets a
    // screen reader say "selected" rather than the label having to change
    // shape between states.
    final source = File('lib/widgets/like_button.dart').readAsStringSync();
    expect(source, contains('Semantics('));
    expect(source, contains('toggled:'));
    expect(source, contains('excludeSemantics: true'),
        reason: 'otherwise the icon and count are re-announced after the label');
  });

  test('text scaling is never disabled app-wide', () {
    // Forcing textScaler to 1.0 is the single most common way an app breaks
    // Dynamic Type. If a layout can't cope with large text, fix the layout.
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      expect(source.contains('TextScaler.noScaling'), isFalse,
          reason: '${file.path} disables text scaling');
      expect(source.contains('textScaleFactor: 1.0'), isFalse,
          reason: '${file.path} pins text scale');
    }
  });
}
