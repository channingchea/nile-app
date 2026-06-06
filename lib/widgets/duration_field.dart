import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Number field + Hours/Minutes segmented unit toggle, with a live preview of
/// the resulting duration / end time. Decimals are allowed only in Hours mode
/// (2.5 hr); Minutes mode is integers-only since "2.5 minutes" is meaningless.
/// Shared by the create flow and the edit screen.
class DurationField extends StatelessWidget {
  final TextEditingController controller;
  final bool inHours;
  final ValueChanged<bool> onUnitChanged;
  final String? preview;

  const DurationField({
    super.key,
    required this.controller,
    required this.inHours,
    required this.onUnitChanged,
    required this.preview,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: controller,
                keyboardType: TextInputType.numberWithOptions(decimal: inHours),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      inHours ? RegExp(r'^\d*\.?\d{0,2}') : RegExp(r'^\d*')),
                ],
                decoration:
                    InputDecoration(hintText: inHours ? 'e.g. 1.5' : 'e.g. 90'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final n = double.tryParse(v.trim());
                  if (n == null || n <= 0) return 'Invalid';
                  return null;
                },
              ),
            ),
            const SizedBox(width: 12),
            _UnitToggle(inHours: inHours, onChanged: onUnitChanged),
          ],
        ),
        if (preview != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.schedule, size: 14, color: NileColors.txtTertiary),
              const SizedBox(width: 6),
              Text(preview!,
                  style: NileTextStyles.caption()
                      .copyWith(color: NileColors.txtSecondary)),
            ],
          ),
        ],
      ],
    );
  }
}

class _UnitToggle extends StatelessWidget {
  final bool inHours;
  final ValueChanged<bool> onChanged;

  const _UnitToggle({required this.inHours, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border.all(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      child: Row(
        children: [
          _segment('Hours', inHours, () => onChanged(true)),
          _segment('Min', !inHours, () => onChanged(false)),
        ],
      ),
    );
  }

  Widget _segment(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? NileColors.volt : Colors.transparent,
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: Text(
          label,
          style: NileTextStyles.labelMd().copyWith(
            color: selected ? NileColors.bgPage : NileColors.txtSecondary,
          ),
        ),
      ),
    );
  }
}
