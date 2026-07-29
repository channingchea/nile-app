import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/diagnostics.dart';
import '../services/error_log.dart';
import '../services/feedback_service.dart';
import '../theme.dart';

/// File a bug or a feature request. Reached from Settings, or from a shake in
/// beta builds — in which case [initialImage] is a capture of whatever screen
/// the user was looking at when they shook.
class ReportIssueScreen extends StatefulWidget {
  const ReportIssueScreen({
    super.key,
    this.initialKind = FeedbackKind.bug,
    this.initialImage,
    this.source = 'settings',
  });

  final FeedbackKind initialKind;
  final Uint8List? initialImage;
  final String source;

  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  late FeedbackKind _kind = widget.initialKind;
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _images = <Uint8List>[];

  Map<String, dynamic>? _diagnostics;
  bool _showDetails = false;
  bool _sending = false;
  bool _sent = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialImage != null) _images.add(widget.initialImage!);
    _title.addListener(_refresh);
    _body.addListener(_refresh);
    // Collected up front so the disclosure shows the real payload, not a
    // description of one.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final d = await Diagnostics.collect(
        screenSize: mounted ? MediaQuery.sizeOf(context) : null,
      );
      if (mounted) setState(() => _diagnostics = d);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  bool get _valid =>
      _title.text.trim().length >= 3 &&
      _body.text.trim().length >= FeedbackService.minBody;

  Future<void> _addImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 80,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (mounted) setState(() => _images.add(bytes));
    } catch (e) {
      ErrorLog.record('Feedback image pick failed: $e');
      if (mounted) setState(() => _error = "Couldn't attach that image.");
    }
  }

  Future<void> _submit() async {
    if (!_valid || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await FeedbackService.submit(
        kind: _kind,
        title: _title.text,
        body: _body.text,
        images: _images,
        source: widget.source,
        screenSize: MediaQuery.sizeOf(context),
      );
      if (mounted) setState(() => _sent = true);
    } on FeedbackRateLimited catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = e.message.toString());
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Couldn't send that — check your connection.");
      }
      ErrorLog.record('Feedback submit failed: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text(_sent ? 'Thanks' : 'Report a bug or idea'),
      ),
      body: NileMaxWidth(child: _sent ? _thanks() : _form()),
    );
  }

  Widget _thanks() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 56, color: NileColors.volt),
            const SizedBox(height: NileSpacing.s16),
            Text('Report sent', style: NileTextStyles.headingSm()),
            const SizedBox(height: NileSpacing.s8),
            Text(
              "We read every one. You'll get a notification here when it's "
              'resolved.',
              textAlign: TextAlign.center,
              style: NileTextStyles.bodySm()
                  .copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: NileSpacing.s24),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16,
          NileSpacing.s16, NileSpacing.s32),
      children: [
        _kindToggle(),
        const SizedBox(height: NileSpacing.s16),
        TextField(
          controller: _title,
          maxLength: FeedbackService.maxTitle,
          textCapitalization: TextCapitalization.sentences,
          style: NileTextStyles.bodyMd(),
          decoration: const InputDecoration(
            labelText: 'Title',
            hintText: 'One line — what happened?',
            counterText: '',
          ),
        ),
        const SizedBox(height: NileSpacing.s12),
        TextField(
          controller: _body,
          minLines: 5,
          maxLines: 12,
          maxLength: FeedbackService.maxBody,
          textCapitalization: TextCapitalization.sentences,
          style: NileTextStyles.bodyMd(),
          decoration: InputDecoration(
            labelText: 'Details',
            hintText: _kind.prompt,
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: NileSpacing.s16),
        _screenshots(),
        const SizedBox(height: NileSpacing.s16),
        _diagnosticsDisclosure(),
        if (_error != null) ...[
          const SizedBox(height: NileSpacing.s16),
          Text(
            _error!,
            style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
          ),
        ],
        const SizedBox(height: NileSpacing.s24),
        FilledButton(
          onPressed: _valid && !_sending ? _submit : null,
          child: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Send report'),
        ),
      ],
    );
  }

  Widget _kindToggle() {
    return Row(
      children: [
        for (final k in FeedbackKind.values) ...[
          Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _kind = k);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: NileSpacing.s12),
                decoration: BoxDecoration(
                  color: _kind == k ? NileColors.volt : NileColors.bgSurface,
                  borderRadius: BorderRadius.circular(NileRadius.lg),
                  border: Border.all(
                    color: _kind == k ? NileColors.volt : NileColors.border,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      k == FeedbackKind.bug
                          ? Icons.bug_report_outlined
                          : Icons.lightbulb_outline,
                      size: 18,
                      color: _kind == k
                          ? NileColors.onVolt
                          : NileColors.txtSecondary,
                    ),
                    const SizedBox(width: NileSpacing.s8),
                    Text(
                      k.label,
                      style: NileTextStyles.labelMd().copyWith(
                        color: _kind == k
                            ? NileColors.onVolt
                            : NileColors.txtSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (k != FeedbackKind.values.last)
            const SizedBox(width: NileSpacing.s8),
        ],
      ],
    );
  }

  Widget _screenshots() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SCREENSHOTS (OPTIONAL)',
          style: NileTextStyles.labelSm().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
        const SizedBox(height: NileSpacing.s8),
        SizedBox(
          height: 88,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount:
                _images.length + (_images.length < FeedbackService.maxImages ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(width: NileSpacing.s8),
            itemBuilder: (_, i) =>
                i < _images.length ? _thumb(i) : _addTile(),
          ),
        ),
      ],
    );
  }

  Widget _thumb(int i) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(NileRadius.md),
          child: Image.memory(
            _images[i],
            width: 66,
            height: 88,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: () => setState(() => _images.removeAt(i)),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NileColors.bgRaised,
                border: Border.all(color: NileColors.bgPage, width: 2),
              ),
              child: Icon(Icons.close, size: 13, color: NileColors.txtPrimary),
            ),
          ),
        ),
      ],
    );
  }

  Widget _addTile() {
    return GestureDetector(
      onTap: _addImage,
      child: Container(
        width: 66,
        height: 88,
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
          border: Border.all(color: NileColors.border),
        ),
        child: Icon(Icons.add_photo_alternate_outlined,
            color: NileColors.txtTertiary),
      ),
    );
  }

  /// Everything that gets sent alongside the description, spelled out. The
  /// point is that nothing here is a surprise after the fact.
  Widget _diagnosticsDisclosure() {
    final rows =
        _diagnostics == null ? const [] : Diagnostics.describe(_diagnostics!);
    final errors = ErrorLog.length;
    return Container(
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(NileRadius.lg),
            onTap: () => setState(() => _showDetails = !_showDetails),
            child: Padding(
              padding: const EdgeInsets.all(NileSpacing.s16),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 18, color: NileColors.txtTertiary),
                  const SizedBox(width: NileSpacing.s12),
                  Expanded(
                    child: Text(
                      errors == 0
                          ? 'Device and app info is attached'
                          : 'Device info + $errors recent ${errors == 1 ? 'error' : 'errors'} attached',
                      style: NileTextStyles.bodySm()
                          .copyWith(color: NileColors.txtSecondary),
                    ),
                  ),
                  Icon(
                    _showDetails ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: NileColors.txtTertiary,
                  ),
                ],
              ),
            ),
          ),
          if (_showDetails)
            Padding(
              padding: const EdgeInsets.fromLTRB(NileSpacing.s16, 0,
                  NileSpacing.s16, NileSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in rows)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: NileSpacing.s4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 120,
                            child: Text(
                              r.label,
                              style: NileTextStyles.caption(),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              r.value,
                              style: NileTextStyles.caption()
                                  .copyWith(color: NileColors.txtSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (errors > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: NileSpacing.s8),
                      child: Text(
                        'Recent error messages are included to help track the '
                        'bug down. Logins, keys, and email addresses are '
                        'stripped out before they leave your device.',
                        style: NileTextStyles.caption(),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
