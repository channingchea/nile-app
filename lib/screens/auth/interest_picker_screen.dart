import 'package:flutter/material.dart';

import '../../services/topic_service.dart';
import '../../theme.dart';

/// Beats-style tap-to-grow interest bubbles. Tap cycles weight 1 → 2 → 3 → off;
/// bubble size and volt tint scale with weight. Each tap upserts/deletes the
/// `user_topics` row immediately (idempotent), so closing mid-pick loses nothing.
///
/// Embeddable: used as the interests step of the onboarding PageView and
/// wrapped by [InterestPickerScreen] for standalone use (Settings/Edit Profile).
class InterestPicker extends StatefulWidget {
  const InterestPicker({super.key, this.onChanged});

  /// Called after every weight change with the count of selected topics.
  final ValueChanged<int>? onChanged;

  @override
  State<InterestPicker> createState() => _InterestPickerState();
}

class _InterestPickerState extends State<InterestPicker> {
  List<Topic>? _topics;
  final Map<String, int> _weights = {}; // topicId → 1–3 (absent = off)
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final topics = await TopicService.listTopics();
      final mine = await TopicService.myInterests();
      if (!mounted) return;
      setState(() {
        _topics = topics;
        _weights.addAll(mine);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t load topics: $e');
    }
  }

  void _tap(Topic topic) {
    final prev = _weights[topic.id] ?? 0;
    final next = (prev + 1) % 4; // 0→1→2→3→0
    setState(() {
      next == 0 ? _weights.remove(topic.id) : _weights[topic.id] = next;
    });
    widget.onChanged?.call(_weights.length);
    // Persist in the background; revert locally if the write fails.
    TopicService.setInterest(topic.id, next).catchError((_) {
      if (!mounted) return;
      setState(() {
        prev == 0 ? _weights.remove(topic.id) : _weights[topic.id] = prev;
      });
    });
  }

  // weight → bubble diameter / fill / label style
  static const _diameters = [64.0, 80.0, 104.0, 132.0];

  Color _fill(int w) => switch (w) {
    1 => NileColors.volt.withValues(alpha: 0.18),
    2 => NileColors.volt.withValues(alpha: 0.65),
    3 => NileColors.volt,
    _ => NileColors.bgSurface,
  };

  Color _textColor(int w) => switch (w) {
    1 => NileColors.volt,
    2 || 3 => NileColors.bgPage,
    _ => NileColors.txtSecondary,
  };

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
        ),
      );
    }
    final topics = _topics;
    if (topics == null) {
      return const Center(
        child: CircularProgressIndicator(color: NileColors.volt),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s24,
        NileSpacing.s8,
        NileSpacing.s24,
        NileSpacing.s40,
      ),
      child: Column(
        children: [
          Text(
            'Tap a bubble to grow it. The bigger it is, the more of it '
            'you\'ll see.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm(),
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [for (final t in topics) _bubble(t)],
          ),
        ],
      ),
    );
  }

  Widget _bubble(Topic topic) {
    final w = _weights[topic.id] ?? 0;
    final size = _diameters[w];
    return GestureDetector(
      onTap: () => _tap(topic),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        width: size,
        height: size,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(NileSpacing.s6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _fill(w),
          border: Border.all(
            color: w == 0 ? NileColors.border : NileColors.volt,
            width: w == 0 ? 1 : 1.5,
          ),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 220),
          style: NileTextStyles.labelSm().copyWith(
            color: _textColor(w),
            fontSize: 10.0 + 1.5 * w,
            letterSpacing: 0,
          ),
          child: Text(
            topic.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// Standalone wrapper so the picker is re-openable outside onboarding
/// (e.g. from Settings or Edit Profile).
class InterestPickerScreen extends StatelessWidget {
  const InterestPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('Your Interests', style: NileTextStyles.headingMd()),
      ),
      body: const NileMaxWidth(child: InterestPicker()),
    );
  }
}
