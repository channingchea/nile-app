import 'package:flutter/material.dart';

import '../services/studio_mode.dart';
import '../theme.dart';

/// Multicam / Interview / Premiere. Centered in the Studio and Studio Setup
/// top bars, and in the create/edit event forms ([expand]).
///
/// The selected mode is a solid pill in the text colour, so it never reads as
/// the coral Sound Check / Live state. A null [onChanged] locks it, with
/// [lockedReason] as the tooltip.
class NileStudioModeSwitch extends StatelessWidget {
  const NileStudioModeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.lockedReason,
    this.expand = false,
  });

  final StudioMode value;
  final ValueChanged<StudioMode>? onChanged;
  final String? lockedReason;

  /// Segments share the full width (forms) instead of hugging their labels.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final locked = onChanged == null;
    Widget seg(StudioMode m) {
      final selected = m == value;
      final pill = AnimatedContainer(
        duration: NileMotion.fast,
        curve: NileMotion.curve,
        height: 32,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
        decoration: BoxDecoration(
          color: selected ? NileColors.txtPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(NileRadius.pill),
        ),
        child: Text(
          m.label,
          maxLines: 1,
          style: NileTextStyles.labelMd().copyWith(
            color: selected ? NileColors.bgPage : NileColors.txtSecondary,
          ),
        ),
      );
      final button = Semantics(
        button: true,
        selected: selected,
        enabled: !locked,
        child: InkWell(
          borderRadius: BorderRadius.circular(NileRadius.pill),
          onTap: locked || selected ? null : () => onChanged!(m),
          child: pill,
        ),
      );
      return expand ? Expanded(child: button) : button;
    }

    final bar = Opacity(
      opacity: locked ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.all(NileSpacing.s2),
        decoration: BoxDecoration(
          color: NileColors.bgRaised,
          border: Border.all(color: NileColors.border),
          borderRadius: BorderRadius.circular(NileRadius.pill),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [for (final m in StudioMode.values) seg(m)],
          ),
        ),
      ),
    );
    return locked && lockedReason != null
        ? Tooltip(message: lockedReason!, child: bar)
        : bar;
  }
}

/// The create/edit event form section: the switch plus what the chosen mode
/// does. [locked] once the show is live.
class StudioModeField extends StatelessWidget {
  const StudioModeField({
    super.key,
    required this.value,
    required this.onChanged,
    this.locked = false,
  });

  final StudioMode value;
  final ValueChanged<StudioMode> onChanged;
  final bool locked;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      NileStudioModeSwitch(
        value: value,
        onChanged: locked ? null : onChanged,
        lockedReason: 'The mode can’t change while you’re live',
        expand: true,
      ),
      const SizedBox(height: NileSpacing.s6),
      Text(
        locked
            ? '${value.description} Locked while you’re live.'
            : '${value.description} You can change this in the Studio '
                  'until you go live.',
        style: NileTextStyles.caption().copyWith(color: NileColors.txtTertiary),
      ),
    ],
  );
}
