/// Mirror of regi-api's JournalEntry (schemas/journal_entry.schema.json).
/// Returned by GET /api/journal/{date} (and similar reads) and consumed
/// by POST /api/journal for creates.
///
/// Parsing is intentionally tolerant: a malformed/partial body never
/// throws — missing or wrong-typed fields degrade to null/default. A
/// network or read failure must not crash the bloom.
///
/// toCreateJson emits only the WRITABLE fields and drops null/empty
/// values so the server sees an explicit absence rather than a noisy
/// payload. Read-only server-managed fields (photoSignedUrl, createdAt,
/// updatedAt) and the server-assigned journalEntryId are never sent.
class JournalEntry {
  const JournalEntry({
    this.journalEntryId,
    required this.entryDate,
    this.weight,
    this.weightUnit = 'lb',
    this.measurements,
    this.thoughts,
    this.promptResponses,
    this.summary,
    this.mood,
    this.photoSignedUrl,
    this.createdAt,
    this.updatedAt,
  });

  final int? journalEntryId;
  final String entryDate;
  final double? weight;
  final String weightUnit;
  final Map<String, dynamic>? measurements;
  final String? thoughts;
  final List<dynamic>? promptResponses;
  final String? summary;
  final String? mood;
  final String? photoSignedUrl;
  final String? createdAt;
  final String? updatedAt;

  factory JournalEntry.fromJson(Map<String, dynamic> j) {
    return JournalEntry(
      journalEntryId: _int(j['journalEntryId']),
      entryDate: _str(j['entryDate']) ?? '',
      weight: _double(j['weight']),
      weightUnit: _str(j['weightUnit']) ?? 'lb',
      measurements: _map(j['measurements']),
      thoughts: _str(j['thoughts']),
      promptResponses: _list(j['promptResponses']),
      summary: _str(j['summary']),
      mood: _str(j['mood']),
      photoSignedUrl: _str(j['photoSignedUrl']),
      createdAt: _str(j['createdAt']),
      updatedAt: _str(j['updatedAt']),
    );
  }

  /// Body for POST /api/journal. Only writable fields. Nulls and empties
  /// are dropped so the server can distinguish "not set" from "explicitly
  /// cleared". measurements is omitted entirely when the map is empty —
  /// never sent as `{}`. weightUnit travels with weight: if there's no
  /// weight, the unit is meaningless and is omitted too.
  Map<String, dynamic> toCreateJson() {
    final out = <String, dynamic>{'entryDate': entryDate};
    if (weight != null) {
      out['weight'] = weight;
      out['weightUnit'] = weightUnit;
    }
    final m = measurements;
    if (m != null && m.isNotEmpty) out['measurements'] = m;
    final t = thoughts;
    if (t != null && t.isNotEmpty) out['thoughts'] = t;
    final pr = promptResponses;
    if (pr != null && pr.isNotEmpty) out['promptResponses'] = pr;
    final s = summary;
    if (s != null && s.isNotEmpty) out['summary'] = s;
    final mo = mood;
    if (mo != null && mo.isNotEmpty) out['mood'] = mo;
    return out;
  }
}

String? _str(dynamic v) {
  if (v is String && v.isNotEmpty) return v;
  return null;
}

int? _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _double(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

Map<String, dynamic>? _map(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.cast<String, dynamic>();
  return null;
}

List<dynamic>? _list(dynamic v) {
  if (v is List) return v;
  return null;
}
