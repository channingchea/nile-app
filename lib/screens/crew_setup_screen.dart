import 'package:flutter/material.dart';

import '../services/crew_service.dart';
import '../theme.dart';

/// Host-facing Crew Setup. Before going live, the host maps each crew member to
/// a camera slot and designates exactly one Stream Audio device. The crew page
/// only captured count + membership; this is where roles are bound. Distinct
/// from the per-device Sound Check screens (camera/audio) that come after.
///
/// Reads the event's camera slots and assigned operators, lets the host edit
/// assignments inline, persists via [CrewService.assignOperator], then hands off
/// to [onContinue] (the camera/audio streaming flow).
class CrewSetupScreen extends StatefulWidget {
  /// The events-table UUID (not the LiveKit id) — keys event_operators / cameras.
  final String eventId;

  /// Invoked when the host taps Continue after a successful save. The caller
  /// pushes the camera/audio screen; this screen does not own that navigation.
  final VoidCallback onContinue;

  const CrewSetupScreen({
    super.key,
    required this.eventId,
    required this.onContinue,
  });

  @override
  State<CrewSetupScreen> createState() => _CrewSetupScreenState();
}

class _CrewSetupScreenState extends State<CrewSetupScreen> {
  List<EventCamera> _cameras = [];
  List<OperatorPick> _picks = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cameras = await CrewService.fetchCameras(widget.eventId);
      final operators = await CrewService.fetchOperators(widget.eventId);
      if (!mounted) return;
      setState(() {
        _cameras = cameras;
        // Seed editable picks from the persisted assignments.
        _picks = [
          for (final op in operators)
            OperatorPick(
              op.profile,
              slotIndex: op.slotIndex,
              isAudioOperator: op.isAudioOperator,
            ),
        ];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t load your crew. ${e.toString()}';
        _loading = false;
      });
    }
  }

  /// Camera slot index → label, for the dropdown. Includes a null entry for
  /// "Any camera" (unassigned).
  void _setSlot(OperatorPick pick, int? slotIndex) {
    setState(() => pick.slotIndex = slotIndex);
  }

  /// Exactly one Stream Audio device: selecting one clears the rest. Tapping
  /// the current selection again clears it (no audio operator designated).
  void _setAudio(OperatorPick pick) {
    setState(() {
      final wasSelected = pick.isAudioOperator;
      for (final p in _picks) {
        p.isAudioOperator = false;
      }
      pick.isAudioOperator = !wasSelected;
    });
  }

  String? _slotIdForIndex(int? slotIndex) {
    if (slotIndex == null) return null;
    for (final c in _cameras) {
      if (c.slotIndex == slotIndex) return c.id;
    }
    return null;
  }

  Future<void> _saveAndContinue() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Persist every crew member's slot + audio role. assignOperator is
      // idempotent per (event, operator), so re-saving is safe.
      for (final pick in _picks) {
        await CrewService.assignOperator(
          eventId: widget.eventId,
          operatorId: pick.profile.id,
          cameraId: _slotIdForIndex(pick.slotIndex),
          isAudioOperator: pick.isAudioOperator,
        );
      }
      if (!mounted) return;
      widget.onContinue();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Couldn\'t save assignments. ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: NileColors.bgSurface,
        title: Text('Crew Setup', style: NileTextStyles.headingSm()),
      ),
      body: NileMaxWidth(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: NileColors.volt),
              )
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(NileSpacing.s24),
            children: [
              Text('Assign your crew', style: NileTextStyles.headingLg()),
              const SizedBox(height: 8),
              Text(
                'Map each crew member to a camera, and pick who carries the '
                'stream audio. You can change this any time during Sound Check.',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
              const SizedBox(height: 24),
              if (_picks.isEmpty)
                const _EmptyCrew()
              else
                for (final pick in _picks) ...[
                  _CrewAssignmentCard(
                    pick: pick,
                    cameras: _cameras,
                    onSlotChanged: (slot) => _setSlot(pick, slot),
                    onAudioToggled: () => _setAudio(pick),
                  ),
                  const SizedBox(height: 12),
                ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        _buildFooter(),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s12, NileSpacing.s24, NileSpacing.s24),
      decoration: const BoxDecoration(
        color: NileColors.bgPage,
        border: Border(top: BorderSide(color: NileColors.border)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _saving ? null : _saveAndContinue,
          style: FilledButton.styleFrom(
            backgroundColor: NileColors.volt,
            foregroundColor: NileColors.bgPage,
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            textStyle: NileTextStyles.labelLg(),
            shape: const StadiumBorder(),
          ),
          child: _saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.bgPage,
                  ),
                )
              : const Text('Continue to Sound Check'),
        ),
      ),
    );
  }
}

/// One crew member: avatar + handle, a camera-slot dropdown, and a Stream Audio
/// toggle. The audio toggle is mutually exclusive across the list (enforced by
/// the parent), shown here as a selectable chip.
class _CrewAssignmentCard extends StatelessWidget {
  final OperatorPick pick;
  final List<EventCamera> cameras;
  final ValueChanged<int?> onSlotChanged;
  final VoidCallback onAudioToggled;

  const _CrewAssignmentCard({
    required this.pick,
    required this.cameras,
    required this.onSlotChanged,
    required this.onAudioToggled,
  });

  @override
  Widget build(BuildContext context) {
    final url = pick.profile.avatarUrl;
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border.all(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: NileColors.bgRaised,
                backgroundImage: (url != null && url.isNotEmpty)
                    ? nileAvatarImage(url, 18)
                    : null,
                child: (url == null || url.isEmpty)
                    ? const Icon(
                        Icons.person,
                        size: 18,
                        color: NileColors.txtTertiary,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pick.profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.labelMd(),
                    ),
                    Text(
                      '@${pick.profile.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.caption().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SlotDropdown(
            cameras: cameras,
            value: pick.slotIndex,
            onChanged: onSlotChanged,
          ),
          const SizedBox(height: 12),
          _AudioToggle(selected: pick.isAudioOperator, onTap: onAudioToggled),
        ],
      ),
    );
  }
}

class _SlotDropdown extends StatelessWidget {
  final List<EventCamera> cameras;
  final int? value;
  final ValueChanged<int?> onChanged;

  const _SlotDropdown({
    required this.cameras,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Camera', isDense: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int?>(
          value: value,
          isExpanded: true,
          dropdownColor: NileColors.bgRaised,
          style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtPrimary),
          icon: const Icon(
            Icons.arrow_drop_down,
            color: NileColors.txtSecondary,
          ),
          items: [
            const DropdownMenuItem<int?>(
              value: null,
              child: Text('Any camera'),
            ),
            for (final c in cameras)
              DropdownMenuItem<int?>(value: c.slotIndex, child: Text(c.label)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _AudioToggle extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _AudioToggle({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s8),
        decoration: BoxDecoration(
          color: selected ? NileColors.volt : Colors.transparent,
          border: Border.all(
            color: selected ? NileColors.volt : NileColors.border,
          ),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.graphic_eq : Icons.graphic_eq_outlined,
              size: 18,
              color: selected ? NileColors.bgPage : NileColors.txtSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              'Stream Audio device',
              style: NileTextStyles.labelMd().copyWith(
                color: selected ? NileColors.bgPage : NileColors.txtSecondary,
              ),
            ),
            const Spacer(),
            if (selected)
              const Icon(Icons.check, size: 18, color: NileColors.bgPage),
          ],
        ),
      ),
    );
  }
}

class _EmptyCrew extends StatelessWidget {
  const _EmptyCrew();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s24),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border.all(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.group_outlined,
            size: 32,
            color: NileColors.txtTertiary,
          ),
          const SizedBox(height: 12),
          Text(
            'No crew on this event',
            style: NileTextStyles.labelMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'You can still run the show solo — continue to Sound Check.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
