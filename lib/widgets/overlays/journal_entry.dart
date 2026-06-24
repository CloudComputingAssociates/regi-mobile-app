import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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
///
/// SAVE: there is no manual Save UI. Every form mutation schedules a
/// debounced (1.5s) POST upsert; photo pick fires an immediate save
/// (so the photo upload can run against the resulting entry id); a
/// voice utterance of "save" / "save it" / "save entry" is intercepted
/// in onFinal as a command and triggers an immediate save instead of
/// appending to Thoughts. Clearing thoughts persists as `""` on the
/// next autosave.
class JournalEntry extends StatefulWidget {
  const JournalEntry({super.key});

  @override
  State<JournalEntry> createState() => _JournalEntryState();
}

class _JournalEntryState extends State<JournalEntry>
    with WidgetsBindingObserver {
  // Visual tokens — mirror UserSettings.
  static const Color _inputFill = Color(0xFF555555);

  final JournalService _service = JournalService();
  final TextEditingController _thoughts = TextEditingController();
  final TextEditingController _weight = TextEditingController();
  // FocusNodes so we can flush any pending debounced autosave the
  // moment the user leaves a numeric field. The thoughts field doesn't
  // need one since dictation/typing already schedules autosave on
  // every character.
  final FocusNode _weightFocus = FocusNode();
  late final Map<String, FocusNode> _measurementFocus = {
    for (final s in _measurementSpec) s[1]: FocusNode(),
  };

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
  // Photo signed URL returned by the GET for today's entry. We immediately
  // fetch its bytes into [_existingPhotoBytes] and render via Image.memory
  // — NOT Image.network — so Flutter web doesn't spawn an <img> platform
  // view that can wedge the widget tree and block surrounding taps
  // (notably the AppBar X close).
  String? _existingPhotoUrl;
  Uint8List? _existingPhotoBytes;
  // Server id of today's entry, captured from prefill OR from the first
  // successful save. Needed to DELETE the photo on × tap when the photo
  // came from the server, and to upload a freshly-picked photo against
  // the right row.
  int? _journalEntryId;
  bool _isSaving = false;
  // Set true when a save was requested while another was in flight.
  // Drained at the end of _save so back-to-back mutations don't drop
  // their last write (e.g. fast photo-pick during an autosave).
  bool _savePending = false;
  bool _isLoading = true;
  // True while _prefillFrom is writing into controllers, so the
  // controller listeners that fire don't kick off an autosave for
  // server-populated values.
  bool _isPrefilling = false;
  // Debounced-save timer. Cancelled and rescheduled on every mutation
  // so a burst of edits collapses into one POST 1.5s after the last
  // edit. Cancelled and fired-immediately by photo-pick and voice
  // "save" command paths.
  Timer? _autosaveTimer;
  static const _autosaveDebounce = Duration(milliseconds: 1500);

  // Voice commands intercepted in onFinal instead of being appended to
  // the Thoughts field. Local exact-match (case/whitespace-insensitive,
  // trailing punctuation stripped) so "save" triggers save but "I will
  // save my work later" appends as text. No command-gate roundtrip.
  static const Set<String> _saveCommandPhrases = {
    'save',
    'save it',
    'save now',
    'save this',
    'save entry',
    'save journal',
  };

  // Snapshot of _thoughts.text taken at mic-press (sink.onStart). The
  // batch-transcribed final text is appended to this prefix in onFinal so
  // dictation composes with existing typing and successive holds compose
  // with each other.
  String _thoughtsPrefix = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _thoughts.addListener(_onFormMutated);
    _weight.addListener(_onFormMutated);
    _weightFocus.addListener(() => _flushOnBlur(_weightFocus));
    for (final entry in _measurements.entries) {
      entry.value.addListener(_onFormMutated);
      _measurementFocus[entry.key]!
          .addListener(() => _flushOnBlur(_measurementFocus[entry.key]!));
    }
    final cs = context.read<ChatState>();
    cs.setVoiceSink(VoiceSink(
      label: 'Journal',
      onStart: () => _thoughtsPrefix = _thoughts.text,
      // Unused under batch transport — retained for the VoiceSink
      // contract (a future streaming consumer could call it).
      onPartial: (c) => _setThoughtsText(
        _thoughtsPrefix.isEmpty ? c : '$_thoughtsPrefix $c',
      ),
      onFinal: _onVoiceFinal,
    ));
    unawaited(_loadTodayEntry());
  }

  /// Fires an immediate save when a numeric field loses focus. Catches
  /// the "user typed weight, tapped close before the 1.5s debounce
  /// fired" edge case. No-op if focus is gaining (we only care about
  /// blur), if we're prefilling, or if there's already a save in flight
  /// (the in-flight save will pick up the latest controller values).
  void _flushOnBlur(FocusNode node) {
    if (node.hasFocus || _isPrefilling) return;
    if (_autosaveTimer?.isActive == true) {
      _saveNow();
    }
  }

  /// Re-fetch today's entry when the app returns to the foreground —
  /// catches the cross-device case where another device saved while
  /// the phone was backgrounded. Silent on failure.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_loadTodayEntry());
    }
  }

  /// Called by ChatScreen with the final transcript from a PTT hold.
  /// If the utterance is a save command, fire an immediate save (don't
  /// append it to Thoughts — the user wouldn't want their command word
  /// shoved into their journal). Otherwise append + schedule autosave.
  ///
  /// In all cases, defensively drop focus from any TextField afterward.
  /// PTT writing to a controller can leave a TextField in a state where
  /// subsequent taps elsewhere seem ignored ("PTT stole focus") — a
  /// proactive unfocus restores normal tap behavior across the UI.
  void _onVoiceFinal(String text) {
    if (_isSaveCommand(text)) {
      _thoughtsPrefix = _thoughts.text;
      _saveNow();
      _toast('Saved.');
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    final combined = _thoughtsPrefix.isEmpty
        ? text
        : '$_thoughtsPrefix${_separatorAfter(_thoughtsPrefix)}$text';
    _setThoughtsText(combined);
    _thoughtsPrefix = combined;
    FocusManager.instance.primaryFocus?.unfocus();
    // The controller-text change above also fires _onFormMutated which
    // schedules autosave — no explicit call needed here.
  }

  bool _isSaveCommand(String text) {
    // Strip trailing punctuation and collapse internal whitespace, then
    // lowercase. Catches "Save.", "  Save it ", "SAVE NOW" alike.
    final normalized = text
        .trim()
        .replaceAll(RegExp(r'[.!?,;:]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();
    return _saveCommandPhrases.contains(normalized);
  }

  /// Called from every form-field listener AND every non-listener
  /// mutation (date pick, unit toggle, photo pick/clear, thoughts trash).
  /// Suppresses during prefill so a server-populated form doesn't
  /// instantly bounce back as an autosave. Reschedules the debounced
  /// autosave timer.
  void _onFormMutated() {
    if (!mounted || _isPrefilling) return;
    _scheduleAutosave();
    setState(() {});
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDebounce, _saveNow);
  }

  /// Fires immediately, cancelling any pending debounced save. Used by
  /// photo-pick (we need the entry id ASAP to upload against) and the
  /// voice "save" command (user explicitly asked). If a save is already
  /// in flight, set [_savePending] so _save will re-run after it
  /// finishes — never silently drop the request.
  void _saveNow() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    if (_isSaving) {
      _savePending = true;
      return;
    }
    unawaited(_save());
  }

  /// Loads the entry for [_entryDate] from the server and prefills the
  /// form. Used on mount (initial today-load) AND when the user steps
  /// day-by-day via the date arrows.
  ///
  /// Two-call dance: LIST returns the id but NOT photoSignedUrl (server
  /// intentionally omits it from lists — see CLAUDE.md). If an entry
  /// exists, follow up with detail (`GET /api/journal/{id}`), which
  /// mints a fresh signed URL. Detail response is what prefills.
  ///
  /// If no entry exists for the date, fields are RESET so the form
  /// reflects the empty server state instead of stale prior-day values.
  /// Silent on failure so a flaky network doesn't block journaling.
  Future<void> _loadTodayEntry() async {
    try {
      final jwt = await context.read<AuthService>().getAccessToken();
      if (jwt == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      final listed = await _service.getTodayEntry(jwt, date: _entryDate);
      model.JournalEntry? detail;
      if (listed?.journalEntryId != null) {
        detail = await _service.getEntryById(listed!.journalEntryId!, jwt);
      }
      // Prefer the detail response (has photoSignedUrl); fall back to the
      // list shape if the detail GET 404'd or returned null.
      final source = detail ?? listed;
      if (!mounted) return;
      setState(() {
        if (source != null) {
          _prefillFrom(source);
        } else {
          _resetFormFields();
        }
        _isLoading = false;
      });
      // Kick off the photo-bytes fetch AFTER the form is up so the user
      // sees the rest of the prefill immediately; the preview pops in
      // as soon as the bytes arrive.
      if (_existingPhotoUrl != null) {
        unawaited(_fetchExistingPhotoBytes());
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Wipes form fields back to defaults (for stepping to a date with no
  /// entry). entryDate is NOT touched — caller already set it.
  void _resetFormFields() {
    _isPrefilling = true;
    try {
      _weight.clear();
      _thoughts.clear();
      _thoughtsPrefix = '';
      for (final c in _measurements.values) {
        c.clear();
      }
      _weightUnit = 'lb';
      _photo = null;
      _photoBytes = null;
      _existingPhotoUrl = null;
      _existingPhotoBytes = null;
    } finally {
      _isPrefilling = false;
    }
  }

  /// Fetches the photo bytes for the current [_existingPhotoUrl] so the
  /// preview can render via Image.memory (no Image.network platform view).
  /// Silent on failure — the broken-photo state is a null bytes payload
  /// which the UI treats as "no photo" and falls back to the Add pill.
  Future<void> _fetchExistingPhotoBytes() async {
    final url = _existingPhotoUrl;
    if (url == null) return;
    try {
      final res = await http.get(Uri.parse(url));
      if (!mounted || _existingPhotoUrl != url) return;
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        setState(() => _existingPhotoBytes = res.bodyBytes);
      } else {
        // Broken / expired URL — fall back to no-photo state so the
        // Add Photo pill reappears.
        setState(() {
          _existingPhotoUrl = null;
          _existingPhotoBytes = null;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _existingPhotoUrl = null;
        _existingPhotoBytes = null;
      });
    }
  }

  /// Step the entry date by [days] (negative = back, positive = forward).
  /// Future-clamped: stepping past today is disallowed. Flushes any
  /// pending autosave before swapping dates so unsaved edits on the
  /// current day aren't lost.
  Future<void> _stepDate(int days) async {
    final candidate = _entryDate.add(Duration(days: days));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (candidate.isAfter(today)) return;
    if (_autosaveTimer?.isActive == true) {
      _saveNow();
    }
    if (!mounted) return;
    setState(() {
      _entryDate = candidate;
      _isLoading = true;
    });
    await _loadTodayEntry();
  }

  void _prefillFrom(model.JournalEntry e) {
    // Set the prefill flag BEFORE touching any controller so the
    // listener-triggered _onFormMutated calls bail out early and don't
    // schedule an autosave for server-populated values. Cleared at the
    // end.
    _isPrefilling = true;
    try {
      // CLEAR every field first. Otherwise stepping from a day that
      // had thoughts/weight/measurements to a day where those fields
      // are null on the server leaves the prior day's values stuck
      // in the controllers (because the populating branches below are
      // conditional on the incoming value being non-null).
      _weight.clear();
      _thoughts.clear();
      _thoughtsPrefix = '';
      for (final c in _measurements.values) {
        c.clear();
      }
      _photo = null;
      _photoBytes = null;
      _existingPhotoBytes = null;

      _journalEntryId = e.journalEntryId;
      _existingPhotoUrl = e.photoSignedUrl;
      // entryDate from server is YYYY-MM-DD (or YYYY-MM-DDT...); parse
      // the date portion only. Falls back to today on any parse problem.
      final parsed = DateTime.tryParse(e.entryDate);
      if (parsed != null) {
        _entryDate = DateTime(parsed.year, parsed.month, parsed.day);
      }
      if (e.weight != null) {
        final w = e.weight!;
        _weight.text = w == w.roundToDouble()
            ? w.toInt().toString()
            : w.toStringAsFixed(1);
      }
      _weightUnit = e.weightUnit;
      if (e.thoughts != null) _thoughts.text = e.thoughts!;
      final m = e.measurements;
      if (m != null) {
        m.forEach((key, value) {
          final c = _measurements[key];
          if (c == null) return;
          if (value is num) {
            c.text = value == value.roundToDouble()
                ? value.toInt().toString()
                : value.toStringAsFixed(1);
          } else if (value is String) {
            c.text = value;
          }
        });
      }
    } finally {
      _isPrefilling = false;
    }
  }

  /// Picks the join character between existing text and an incoming
  /// transcript. A newline after sentence punctuation reads as a new
  /// thought; a space otherwise keeps mid-sentence dictation flowing.
  String _separatorAfter(String base) {
    final trimmed = base.trimRight();
    if (trimmed.isEmpty) return '';
    final last = trimmed[trimmed.length - 1];
    return '.!?'.contains(last) ? '\n' : ' ';
  }

  @override
  void dispose() {
    // If the photo zoom dialog (or any other locally-opened modal) is
    // still on top when the overlay closes, dismiss it. Otherwise a
    // leftover dialog's dark barrier persists over chat-input after
    // close, blocking taps.
    try {
      final nav = Navigator.of(context, rootNavigator: true);
      nav.popUntil((route) => route is! PopupRoute);
    } catch (_) {
      // context may already be detached during teardown.
    }
    WidgetsBinding.instance.removeObserver(this);
    // Cancel any pending autosave — there's no way to flush a debounced
    // POST during dispose (HTTP is async, dispose is sync, and we're
    // about to close the http.Client). Field-blur listeners already
    // flush on focus loss; the remaining loss window is just "user
    // close-tapped mid-typing without leaving the field."
    _autosaveTimer?.cancel();
    // Clear voice sink so any in-flight PTT release routes back to the
    // chat default and the PTT button hides (unless the user explicitly
    // chose Voice in the slider).
    try {
      context.read<ChatState>().setVoiceSink(null);
    } catch (_) {
      // context may already be unmounted in pathological teardown paths.
    }
    _thoughts.dispose();
    _weight.dispose();
    _weightFocus.dispose();
    for (final c in _measurements.values) {
      c.dispose();
    }
    for (final f in _measurementFocus.values) {
      f.dispose();
    }
    _service.dispose();
    super.dispose();
  }

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
      // Photo upload runs against the entry id, so we need the entry
      // to exist server-side before we can PUT the photo. Fire an
      // immediate save (bypass debounce) — the upload runs inside the
      // save flow once upsertEntry returns.
      _saveNow();
    } catch (e) {
      if (!mounted) return;
      _toast('Photo picker error: $e');
    }
  }

  Future<void> _clearPhoto() async {
    // Snapshot whether we need a server-side delete BEFORE we wipe local
    // state. Three cases:
    //   1. Local-only (just picked, never saved) → no server call.
    //   2. Server-backed (came from prefill or completed upload) AND we
    //      know the entry id → fire DELETE /journal/{id}/photo.
    //   3. Server-backed but no entry id yet → defensively wipe local
    //      only (shouldn't happen — photo URL only comes with an entry).
    final hadServerPhoto = _existingPhotoUrl != null;
    final entryId = _journalEntryId;
    setState(() {
      _photo = null;
      _photoBytes = null;
      _existingPhotoUrl = null;
      _existingPhotoBytes = null;
    });
    if (!hadServerPhoto || entryId == null) return;
    try {
      final jwt = await context.read<AuthService>().getAccessToken();
      if (jwt == null) {
        if (mounted) _toast('Not authenticated.');
        return;
      }
      await _service.deletePhoto(entryId, jwt);
    } on JournalException catch (e) {
      if (mounted) {
        _toast('Photo delete failed: HTTP ${e.statusCode} ${e.body}');
      }
    } catch (e) {
      if (mounted) _toast('Photo delete failed: $e');
    }
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
    final normalized = DateTime(picked.year, picked.month, picked.day);
    if (normalized == DateTime(_entryDate.year, _entryDate.month, _entryDate.day)) {
      return;
    }
    // Flush any pending autosave for the OLD date before swapping. Then
    // reload from the server for the new date — the picker is a
    // navigation, not just a "today's entryDate is this" tweak.
    if (_autosaveTimer?.isActive == true) {
      _saveNow();
    }
    setState(() {
      _entryDate = normalized;
      _isLoading = true;
    });
    await _loadTodayEntry();
  }

  // ───────── Save ─────────

  /// Single save path for all triggers (debounced autosave, photo pick,
  /// voice "save" command). No dirty gate — if the timer fires or
  /// something explicitly called this, we're saving. _isSaving guards
  /// against re-entry; a save scheduled while one is in flight will
  /// be picked up on the next mutation.
  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final measurementsMap = <String, dynamic>{};
    _measurements.forEach((k, c) {
      final v = double.tryParse(c.text.trim());
      if (v != null && v > 0) measurementsMap[k] = v;
    });

    final weightNum = double.tryParse(_weight.text.trim());
    final thoughtsText = _thoughts.text.trim();
    // Send "" for thoughts when the user cleared the field — backend
    // treats empty-string and null the same way and overwrites the
    // stored value. This is how the trash icon's clear-then-autosave
    // propagates to the server.
    final entry = model.JournalEntry(
      entryDate: _wireDate(_entryDate),
      weight: weightNum,
      weightUnit: _weightUnit,
      measurements: measurementsMap,
      thoughts: thoughtsText,
    );

    final jwt = await context.read<AuthService>().getAccessToken();
    if (jwt == null) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _toast('Not authenticated.');
      return;
    }

    try {
      final saved = await _service.upsertEntry(entry, jwt);
      _journalEntryId = saved.journalEntryId;
      if (_photo != null &&
          _photoBytes != null &&
          saved.journalEntryId != null) {
        // Send a clean, predictable filename rather than `_photo!.name`,
        // which on some pickers (notably web file-input) can be a path-
        // shaped string like "3/5.jpg" that the server then mis-stores
        // as the URL field. entryDate-based name is unambiguous, has no
        // slashes, and stays unique per (user, date).
        final updated = await _service.uploadPhoto(
          saved.journalEntryId!,
          _photoBytes!,
          'photo_${_wireDate(_entryDate)}.jpg',
          jwt,
        );
        // Photo is now persisted; promote it from the local "freshly
        // picked" slot to the server-backed slot so a subsequent ×
        // tap fires the DELETE path instead of just hiding bytes.
        if (mounted) {
          setState(() {
            _photo = null;
            _photoBytes = null;
            _existingPhotoUrl = updated.photoSignedUrl;
          });
        }
      }
      if (!mounted) return;
      setState(() => _isSaving = false);
      // Autosave is silent — no chat message, no overlay close. Close
      // is only via the red × in the AppBar.
    } on JournalException catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _toast('Save failed: HTTP ${e.statusCode} ${e.body}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _toast('Save failed: $e');
    }
    // Drain pending — another save was requested while we were running.
    if (_savePending && mounted) {
      _savePending = false;
      unawaited(_save());
    }
  }

  /// Floats a short message above the overlay/chat-input. Used in place
  /// of the inline `_saveError` slot we used to show below the Save
  /// button, since Save now lives in the AppBar.
  void _toast(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ));
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
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFF2B33D)),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dateRow(),
          const SizedBox(height: 18),
          _thoughtsSection(),
          const SizedBox(height: 18),
          _weightSection(),
          const SizedBox(height: 18),
          _photoSection(),
          const SizedBox(height: 8),
          _measurementsExpander(),
          // TODO(glp1): when user setting 'Track GLP-1' ships, render a
          // dose field here.
          const SizedBox(height: 24),
          _deleteEntryButton(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _deleteEntryButton() {
    // Always available unless a save is mid-flight. Even with no
    // server-side entry, the button wipes the local form (useful if
    // the user typed but autosave hadn't fired yet) and toasts the
    // confirmation — semantics match the label "Clear Entry."
    final canClear = !_isSaving;
    return Center(
      child: TextButton(
        onPressed: canClear ? _clearEntry : null,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFFF5F57),
          disabledForegroundColor: Colors.white24,
        ),
        child: const Text(
          'Clear Entry',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// Wipes the local form AND (if an entry exists server-side) deletes
  /// the row. Stays in the overlay so the user can start a fresh entry
  /// for the same day. Toasts a confirmation. No modal confirm — per
  /// user request, the action is one-tap.
  Future<void> _clearEntry() async {
    if (_isSaving) return;
    final dateLabel =
        '${_months[_entryDate.month - 1]} ${_entryDate.day}';
    final id = _journalEntryId;

    // Cancel any pending autosave so we don't immediately recreate
    // an entry we're about to delete.
    _autosaveTimer?.cancel();
    _autosaveTimer = null;

    // Always reset the local form. Only flip _isSaving when we have a
    // server call to make, so the button stays enabled in the no-server
    // case (which is instantaneous).
    setState(() {
      _resetFormFields();
      _isSaving = id != null;
    });

    if (id == null) {
      _toast('Journal for $dateLabel cleared.');
      return;
    }

    try {
      final jwt = await context.read<AuthService>().getAccessToken();
      if (jwt == null) {
        if (!mounted) return;
        setState(() => _isSaving = false);
        _toast('Not authenticated.');
        return;
      }
      await _service.deleteEntry(id, jwt);
      if (!mounted) return;
      setState(() {
        _journalEntryId = null;
        _isSaving = false;
      });
      _toast('Journal for $dateLabel cleared.');
    } on JournalException catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _toast('Clear failed: HTTP ${e.statusCode} ${e.body}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _toast('Clear failed: $e');
    }
  }

  Widget _dateRow() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final canStepForward = _entryDate.isBefore(today);
    // Both arrows sit at the LEFT of the chip so the chip can grow /
    // shrink with the label text ("Today (Jun 24)" vs "Jun 24") without
    // shifting the arrows under the user's finger between taps.
    return Row(
      children: [
        _dateArrow(Icons.chevron_left, true, () => _stepDate(-1)),
        const SizedBox(width: 6),
        _dateArrow(
          Icons.chevron_right,
          canStepForward,
          canStepForward ? () => _stepDate(1) : null,
        ),
        const SizedBox(width: 8),
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

  Widget _dateArrow(IconData icon, bool enabled, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: _inputFill,
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 20,
          color: enabled ? Colors.white : Colors.white24,
        ),
      ),
    );
  }

  Widget _photoSection() {
    // Display priority: freshly-picked photo bytes win; otherwise the
    // server-loaded bytes (fetched from photoSignedUrl via http). When
    // _existingPhotoUrl is set but bytes haven't arrived yet we show a
    // placeholder. "Has photo" for the UI gate includes both populated
    // bytes AND in-flight URL → shows the box, not the Add pill.
    final displayBytes = _photoBytes ?? _existingPhotoBytes;
    final hasPhoto = displayBytes != null || _existingPhotoUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle('Photo'),
            const SizedBox(width: 10),
            _sectionTrash(
              tooltip: 'Delete photo',
              enabled: hasPhoto,
              onTap: _clearPhoto,
            ),
          ],
        ),
        if (!hasPhoto)
          _pillButton(
            icon: Icons.add_a_photo,
            label: 'Add Photo',
            onTap: _openAddPhotoBloom,
          )
        else
          // Tap the thumbnail (or press-and-hold on touch) → zoom dialog
          // with a red × to close. The thumbnail itself has no × — the
          // trash next to the section header is the delete affordance.
          GestureDetector(
            onTap: displayBytes != null
                ? () => _openPhotoZoom(displayBytes)
                : null,
            onLongPress: displayBytes != null
                ? () => _openPhotoZoom(displayBytes)
                : null,
            child: SizedBox(
              width: 140,
              height: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: displayBytes != null
                    ? Image.memory(displayBytes, fit: BoxFit.cover)
                    : Container(
                        color: _inputFill,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white38,
                          ),
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  /// Fullscreen-ish dialog displaying the photo at full size with a
  /// floating red × in the top-right to dismiss. Used for both
  /// freshly-picked and server-loaded photo bytes.
  void _openPhotoZoom(Uint8List bytes) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 5.0,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF5F57),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.close,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens a small bloom-styled chooser (yellow-bordered panel) above
  /// the Journal overlay so the user can pick between camera and
  /// gallery. Inline rather than a global bloom because it's tightly
  /// scoped to "where does the next photo come from" — no need to
  /// register it via ChatState.openBloom.
  Future<void> _openAddPhotoBloom() async {
    final source = await showDialog<ImageSource>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF252525),
            border: Border.all(color: const Color(0xFFF2B33D), width: 2),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Text(
                  'Add Photo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _photoSourceOption(
                ctx,
                icon: Icons.photo_camera,
                label: 'Take a Picture',
                source: ImageSource.camera,
              ),
              _photoSourceOption(
                ctx,
                icon: Icons.photo_library,
                label: 'Upload from Library',
                source: ImageSource.gallery,
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
    if (source != null) {
      await _pickPhoto(source);
    }
  }

  Widget _photoSourceOption(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required ImageSource source,
  }) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, source),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: Colors.white70, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thoughtsSection() {
    final hasText = _thoughts.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle('Reflective Thoughts'),
            const SizedBox(width: 10),
            _sectionTrash(
              tooltip: 'Clear thoughts',
              enabled: hasText,
              onTap: _clearThoughts,
            ),
          ],
        ),
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

  Future<void> _clearThoughts() async {
    // Soft confirmation only when there's meaningful content to lose.
    // Threshold is arbitrary — 50 chars is "a sentence or two", below
    // which a stray tap is recoverable by just retyping.
    if (_thoughts.text.length > 50) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF252525),
          title: const Text(
            'Clear thoughts?',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            "You'll lose what's there.",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white70),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: const Color(0xFF8B1A2B),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    _setThoughtsText('');
    _thoughtsPrefix = '';
    _scheduleAutosave();
  }

  void _clearWeight() {
    _weight.clear();
    _scheduleAutosave();
  }

  void _clearMeasurements() {
    for (final c in _measurements.values) {
      c.clear();
    }
    _scheduleAutosave();
  }

  /// Trash IconButton used next to every section label. Greys when
  /// there's nothing to clear, brightens when there is. 32x32 hit area,
  /// 20px glyph.
  Widget _sectionTrash({
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      iconSize: 20,
      icon: Icon(
        Icons.delete_outline,
        color: enabled ? Colors.white70 : Colors.white24,
      ),
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
    );
  }

  Widget _weightSection() {
    final hasWeight = _weight.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle('Weight'),
            const SizedBox(width: 10),
            _sectionTrash(
              tooltip: 'Clear weight',
              enabled: hasWeight,
              onTap: _clearWeight,
            ),
          ],
        ),
        Row(
          children: [
            // Fixed width — only ever holds 5 chars at most (e.g. 315.5).
            // No need to span across the whole row.
            SizedBox(
              width: 110,
              child: TextField(
                controller: _weight,
                focusNode: _weightFocus,
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
      onTap: () {
        setState(() => _weightUnit = _weightUnit == 'lb' ? 'kg' : 'lb');
        _scheduleAutosave();
      },
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
    final anyValue = _measurements.values
        .any((c) => c.text.trim().isNotEmpty);
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
            _measurementRow(s[0], _measurements[s[1]]!, _measurementFocus[s[1]]!),
          // Trash after the expanded measurement fields — only useful
          // when the expander is open (it's rendered as a child so
          // ExpansionTile only shows it when expanded). Greys when
          // there's nothing to clear.
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: _sectionTrash(
              tooltip: 'Clear all measurements',
              enabled: anyValue,
              onTap: _clearMeasurements,
            ),
          ),
        ],
      ),
    );
  }

  Widget _measurementRow(
    String label,
    TextEditingController c,
    FocusNode f,
  ) {
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
              focusNode: f,
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

