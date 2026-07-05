import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/event_service.dart';
import '../theme.dart';

/// Host sets a price for a finished show's replay and publishes it (Phase 2
/// VOD pricing). Reached from the replay_price_prompt notification and from the
/// host's ended-event page. Suggests the live ticket price; free is allowed.
/// Unpriced replays auto-publish at the live price after 48h.
class ReplayPricingScreen extends StatefulWidget {
  final Event event;
  const ReplayPricingScreen({super.key, required this.event});

  @override
  State<ReplayPricingScreen> createState() => _ReplayPricingScreenState();
}

class _ReplayPricingScreenState extends State<ReplayPricingScreen> {
  static const _maxCents = 50000; // mirrors the DB check constraint

  late final TextEditingController _priceCtrl;
  bool _free = false;
  bool _saving = false;

  int get _suggestedCents => widget.event.price ?? 0;

  @override
  void initState() {
    super.initState();
    _free = _suggestedCents == 0;
    _priceCtrl = TextEditingController(
      text: _suggestedCents > 0
          ? (_suggestedCents / 100).toStringAsFixed(2)
          : '',
    );
  }

  @override
  void dispose() {
    _priceCtrl.dispose();
    super.dispose();
  }

  int? _parseCents() {
    if (_free) return 0;
    final v = double.tryParse(_priceCtrl.text.trim());
    if (v == null) return null;
    return (v * 100).round();
  }

  Future<void> _publish() async {
    final cents = _parseCents();
    if (cents == null || cents < 0 || (!_free && cents == 0)) {
      _showError('Enter a valid price, or mark the replay free.');
      return;
    }
    if (cents > _maxCents) {
      _showError('Replay price can\'t exceed \$${_maxCents ~/ 100}.');
      return;
    }
    setState(() => _saving = true);
    try {
      await EventService.publishReplay(widget.event.id, cents);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cents == 0
                ? 'Replay published — free to watch'
                : 'Replay published at \$${(cents / 100).toStringAsFixed(2)}',
            style: NileTextStyles.bodyMd(),
          ),
          backgroundColor: NileColors.success,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) _showError('Couldn\'t publish replay: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: NileTextStyles.bodyMd()),
        backgroundColor: NileColors.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alreadyPublished = widget.event.replayPublishedAt != null;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: NileColors.txtPrimary),
        title: Text('Price your replay', style: NileTextStyles.headingSm()),
      ),
      body: NileMaxWidth(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s24,
              vertical: NileSpacing.s24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.event.title, style: NileTextStyles.headingMd()),
                const SizedBox(height: NileSpacing.s8),
                Text(
                  alreadyPublished
                      ? 'This replay is already published — its price is locked.'
                      : 'Anyone who bought a live ticket watches free. Set what '
                            'everyone else pays, or make it free. If you don\'t '
                            'publish within 48 hours, it goes live at your '
                            'ticket price automatically.',
                  style: NileTextStyles.bodyMd().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
                const SizedBox(height: NileSpacing.s24),
                SwitchListTile(
                  value: _free,
                  onChanged: alreadyPublished
                      ? null
                      : (v) => setState(() => _free = v),
                  title: Text('Free replay', style: NileTextStyles.bodyLg()),
                  activeThumbColor: NileColors.volt,
                  contentPadding: EdgeInsets.zero,
                ),
                if (!_free) ...[
                  const SizedBox(height: NileSpacing.s8),
                  TextField(
                    controller: _priceCtrl,
                    enabled: !alreadyPublished,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d{0,3}(\.\d{0,2})?$'),
                      ),
                    ],
                    style: NileTextStyles.bodyLg(),
                    decoration: InputDecoration(
                      labelText: 'Replay price',
                      prefixText: '\$ ',
                      helperText: _suggestedCents > 0
                          ? 'Suggested: your live ticket price '
                                '(\$${(_suggestedCents / 100).toStringAsFixed(2)})'
                          : null,
                    ),
                  ),
                ],
                const SizedBox(height: NileSpacing.s32),
                FilledButton(
                  onPressed: (_saving || alreadyPublished) ? null : _publish,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: NileSpacing.s16,
                    ),
                    backgroundColor: NileColors.volt,
                    foregroundColor: NileColors.onVolt,
                    disabledBackgroundColor: NileColors.bgRaised,
                  ),
                  child: _saving
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: NileColors.onVolt,
                          ),
                        )
                      : Text(
                          alreadyPublished
                              ? 'Already published'
                              : 'Publish replay',
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
