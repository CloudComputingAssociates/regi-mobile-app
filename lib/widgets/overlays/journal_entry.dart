import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../models/journal_entry.dart' as model;
import '../../services/auth_service.dart';
import '../../services/journal_service.dart';
import '../../services/voice_sink.dart';
import '../../state/chat_state.dart';

/// Left-nav overlay: create a journal entry (date, optional photo,
/// thoughts, weight, optional measurements). Replaces the chat output
/// area while open. Submits via [JournalService]; photo uploads as a
/// separate multipart PUT after the entry id exists.
///
/// Voice is routed via the global [VoiceSink] — there is NO inline mic
/// here. On mount the overlay registers a sink; ChatScreen's PTT
/// visibility derives from `voiceSink != null`, so the talk button comes
/// alive automatically when this overlay opens (regardless of the
/// slider's text/voice setting). On dispose the sink is cleared and PTT
/// reverts to the slider preference.
///
/// Voice transport is BATCH — ChatScreen records during the hold and
/// POSTs the WAV blob on release, so the sink's [VoiceSink.onPartial]
/// never fires here. [VoiceSink.onFinal] is the sole text-mutation
/// point. The partial callback is retained for the contract (a future
/// streaming consumer can wire it) but ChatScreen will not call it.
class JournalEntry extends StatefulWidget {
  const JournalEntry({
    super.key,
    this.onSaved,
  });

  /// Fired after a successful save with a short confirmation line (e.g.
  /// "Journaled for Jun 22 — 396 lb") that the parent reflects back as
  /// an assistant message + TTS.
  final void Function(String confirmation)? onSaved;

  @override
  State<JournalEntry> createState() => _JournalEntryState();
}

class _JournalEntryState extends State<JournalEntry> {
  // Visual tokens — mirror UserSettings.
  static const Color _accent = Color(0xFFF2B33D);
  static const Color _inputFill = Color(0xFF555555);

  final JournalService _service = JournalService();
  final TextEditingController _thoughts = TextEditingController();
  final TextEditingController _weight = TextEditingController();

  // Field keys mirror the regi-api `measurements` map. Order here drives
  // render order in the expander.
  static const List<List<String>> _measurementSpec = [
    ['Waist', 'waistInches'],
    ['Hips', 'hipsInches'],
    ['Chest', 'chestInches'],
    ['Bicep', 'bicepInches'],
    ['Thigh', 'thighInches'],
    ['Neck', 'neckInches'],
  ];
  late final Map<String, TextEditingController> _measurements = {
    for (final s in _measurementSpec) s[1]: TextEditingController(),
  };

  DateTime _entryDate = DateTime.now();
  String _weightUnit = 'lb';
  XFile? _photo;
  Uint8List? _photoBytes;
  bool _isSaving = false;
  String? _saveError;

  // Snapshot of _thoughts.text taken at mic-press (sink.onStart). The
  // batch-transcribed final text is appended to this prefix in onFinal so
  // dictation composes with existing typing and successive holds compose
  // with each other.
  String _thoughtsPrefix = '';

  @override
  void initState() {
    super.initState();
    _thoughts.addListener(_rebuildForSaveEnable);
    _weight.addListener(_rebuildForSaveEnable);
    final cs = context.read<ChatState>();
    cs.setVoiceSink(VoiceSink(
      label: 'Journal',
      onStart: () => _thoughtsPrefix = _thoughts.text,
      // Unused under batch transport — retained for the VoiceSink
      // contract (a future streaming consumer could call it).
      onPartial: (c) => _setThoughtsText(
        _thoughtsPrefix.isEmpty ? c : '$_thoughtsPrefix $c',
      ),
      onFinal: (text) {
        final combined =
            _thoughtsPrefix.isEmpty ? text : '$_thoughtsPrefix $text';
        _setThoughtsText(combined);
        _thoughtsPrefix = combined;
      },
    ));
  }

  @override
  void dispose() {
    // Clear the voice sink so any in-flight PTT release routes back to
    // the chat default and the PTT button hides (unless the user has
    // explicitly chosen Voice in the slider).
    try {
      context.read<ChatState>().setVoiceSink(null);
    } catch (_) {
      // context may already be unmounted in pathological teardown paths.
    }
    _thoughts.dispose();
    _weight.dispose();
    for (final c in _measurements.values) {
      c.dispose();
    }
    _service.dispose();
    super.dispose();
  }

  void _rebuildForSaveEnable() {
    if (!mounted) return;
    setState(() {});
  }

  bool get _canSave =>
      _thoughts.text.trim().isNotEmpty ||
      _weight.text.trim().isNotEmpty ||
      _photo != null;

  void _setThoughtsText(String value) {
    if (_thoughts.text == value) return;
    _thoughts.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  // ───────── Photo ─────────

  Future<void> _pickPhoto(ImageSource src) async {
    try {
      final xfile = await ImagePicker().pickImage(source: src);
      if (xfile == null) return;
      final bytes = await xfile.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = xfile;
        _photoBytes = bytes;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveError = 'Photo picker error: $e');
    }
  }

  void _clearPhoto() {
    setState(() {
      _photo = null;
      _photoBytes = null;
    });
  }

  // ───────── Date ─────────

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _entryDate,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    setState(() => _entryDate = picked);
  }

  // ───────── Save ─────────

  Future<void> _save() async {
    if (_isSaving || !_canSave) return;
    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    final measurementsMap = <String, dynamic>{};
    _measurements.forEach((k, c) {
      final v = double.tryParse(c.text.trim());
      if (v != null && v > 0) measurementsMap[k] = v;
    });

    final weightNum = double.tryParse(_weight.text.trim());
    final thoughtsText = _thoughts.text.trim();
    final entry = model.JournalEntry(
      entryDate: _wireDate(_entryDate),
      weight: weightNum,
      weightUnit: _weightUnit,
      measurements: measurementsMap,
      thoughts: thoughtsText.isEmpty ? null : thoughtsText,
    );

    final jwt = await context.read<AuthService>().getAccessToken();
    if (jwt == null) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveError = 'Not authenticated.';
      });
      return;
    }

    try {
      final saved = await _service.createEntry(entry, jwt);
      if (_photo != null &&
          _photoBytes != null &&
          saved.journalEntryId != null) {
        await _service.uploadPhoto(
          saved.journalEntryId!,
          _photoBytes!,
          _photo!.name,
          jwt,
        );
      }
      if (!mounted) return;
      widget.onSaved?.call(_confirmationFor(saved));
      context.read<ChatState>().closeOverlay();
    } on JournalException catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveError = 'Save failed: HTTP ${e.statusCode} ${e.body}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveError = 'Save failed: $e';
      });
    }
  }

  String _confirmationFor(model.JournalEntry saved) {
    final dateStr = _humanDate(_entryDate);
    final w = saved.weight ?? double.tryParse(_weight.text.trim());
    if (w == null) return 'Journaled for $dateStr';
    final unit = saved.weightUnit;
    final wFmt =
        w == w.roundToDouble() ? w.toInt().toString() : w.toStringAsFixed(1);
    return 'Journaled for $dateStr — $wFmt $unit';
  }

  // ───────── Formatting ─────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _wireDate(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  String _humanDate(DateTime d) {
    final now = DateTime.now();
    final isToday =
        d.year == now.year && d.month == now.month && d.day == now.day;
    final mmd = '${_months[d.month - 1]} ${d.day}';
    return isToday ? 'Today ($mmd)' : mmd;
  }

  // ───────── Build ─────────

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dateRow(),
          const SizedBox(height: 18),
          _photoSection(),
          const SizedBox(height: 18),
          _thoughtsSection(),
          const SizedBox(height: 18),
          _weightSection(),
          const SizedBox(height: 8),
          _measurementsExpander(),
          // TODO(glp1): when user setting 'Track GLP-1' ships, render a
          // dose field here.
          const SizedBox(height: 22),
          _saveButton(),
          if (_saveError != null) ...[
            const SizedBox(height: 10),
            Text(
              _saveError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _dateRow() {
    return Row(
      children: [
        _sectionTitle('Date'),
        const SizedBox(width: 12),
        InkWell(
          onTap: _pickDate,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _inputFill,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.calendar_today,
                  size: 14,
                  color: Colors.white70,
                ),
                const SizedBox(width: 6),
                Text(
                  _humanDate(_entryDate),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _photoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Photo'),
        Row(
          children: [
            _pillButton(
              icon: Icons.photo_camera,
              label: 'Snap a photo',
              onTap: () => _pickPhoto(ImageSource.camera),
            ),
            const SizedBox(width: 8),
            _pillButton(
              icon: Icons.image,
              label: 'Choose',
              onTap: () => _pickPhoto(ImageSource.gallery),
            ),
          ],
        ),
        if (_photoBytes != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 140,
            height: 140,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(_photoBytes!, fit: BoxFit.cover),
                  ),
                ),
                Positioned(
                  right: -8,
                  top: -8,
                  child: GestureDetector(
                    onTap: _clearPhoto,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: const BoxDecoration(
                        color: Colors.black87,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black54,
                            blurRadius: 2,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _thoughtsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Thoughts'),
        TextField(
          controller: _thoughts,
          minLines: 3,
          maxLines: 6,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: _inputFill,
            hintText: 'How did today feel? Hold the talk button to dictate.',
            hintStyle: const TextStyle(color: Colors.white54, fontSize: 13),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _weightSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Weight'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _weight,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: _inputFill,
                  hintText: '0',
                  hintStyle: const TextStyle(color: Colors.white54),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _unitToggle(),
          ],
        ),
      ],
    );
  }

  Widget _unitToggle() {
    return InkWell(
      onTap: () => setState(
        () => _weightUnit = _weightUnit == 'lb' ? 'kg' : 'lb',
      ),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 56,
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _inputFill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _weightUnit,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _measurementsExpander() {
    // Strip ExpansionTile's default dividers so it blends with the bloom.
    final stripped = Theme.of(context).copyWith(
      dividerColor: Colors.transparent,
    );
    return Theme(
      data: stripped,
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
        iconColor: Colors.white70,
        collapsedIconColor: Colors.white70,
        title: const Text(
          'Add measurements',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        children: [
          for (final s in _measurementSpec)
            _measurementRow(s[0], _measurements[s[1]]!),
        ],
      ),
    );
  }

  Widget _measurementRow(String label, TextEditingController c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          Expanded(
            child: TextField(
              controller: c,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: _inputFill,
                hintText: 'in',
                hintStyle: const TextStyle(color: Colors.white54),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _saveButton() {
    final enabled = _canSave && !_isSaving;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: enabled ? _save : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.black,
          disabledBackgroundColor: const Color(0xFF333333),
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: _isSaving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Text(
                'Save',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
      ),
    );
  }

  // ───────── Layout helpers ─────────

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _pillButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _inputFill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

