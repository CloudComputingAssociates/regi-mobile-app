// Mirror of regi-api's GLP-1 contract (schemas/glp1.schema.json).
// Hand-transcribed — no generators.
//
// Parsing is intentionally tolerant: a malformed/partial body never
// throws — missing or wrong-typed fields degrade to null/default. A
// GLP-1 fetch failure must NEVER break the host UI (chat banner,
// journal section); the calling layer treats null/empty as
// "feature unavailable" and silently degrades.
//
// Glp1Injection.toUpsertJson() emits only the WRITABLE fields the
// client should send — injectionDate (required), injectionTime,
// doseUnits — and OMITS brandSnapshot, doseMg, doseTier so the
// server snapshots them from settings.glp1 at write time. Read-only
// fields (glp1InjectionId, createdAt, updatedAt) are never sent.

enum Glp1Tier { start, current, maintenance }

class Glp1ActiveDose {
  const Glp1ActiveDose({
    required this.tier,
    required this.intervalDays,
    this.units,
    this.mg,
    this.brand,
  });

  final Glp1Tier tier;
  final int intervalDays;
  final double? units;
  final double? mg;
  final String? brand;

  factory Glp1ActiveDose.fromJson(Map<String, dynamic> j) {
    return Glp1ActiveDose(
      tier: _tier(j['tier']) ?? Glp1Tier.current,
      intervalDays: _int(j['intervalDays']) ?? 0,
      units: _double(j['units']),
      mg: _double(j['mg']),
      brand: _str(j['brand']),
    );
  }
}

class Glp1Injection {
  const Glp1Injection({
    this.glp1InjectionId,
    required this.injectionDate,
    this.injectionTime,
    this.doseUnits,
    this.doseMg,
    this.doseTier,
    this.brandSnapshot,
    this.createdAt,
    this.updatedAt,
  });

  final int? glp1InjectionId;
  final String injectionDate; // YYYY-MM-DD
  final String? injectionTime; // 24h HH:MM
  final double? doseUnits;
  final double? doseMg;
  final Glp1Tier? doseTier;
  final String? brandSnapshot;
  final String? createdAt;
  final String? updatedAt;

  factory Glp1Injection.fromJson(Map<String, dynamic> j) {
    return Glp1Injection(
      glp1InjectionId: _int(j['glp1InjectionId']),
      injectionDate: _str(j['injectionDate']) ?? '',
      injectionTime: _str(j['injectionTime']),
      doseUnits: _double(j['doseUnits']),
      doseMg: _double(j['doseMg']),
      doseTier: _tier(j['doseTier']),
      brandSnapshot: _str(j['brandSnapshot']),
      createdAt: _str(j['createdAt']),
      updatedAt: _str(j['updatedAt']),
    );
  }

  /// Body for POST /api/glp1/injections — UPSERT by
  /// (userId, injectionDate). Only injectionDate (required),
  /// injectionTime, and doseUnits are sent; brandSnapshot, doseMg,
  /// and doseTier are deliberately omitted so the server snapshots
  /// them from the user's active settings.glp1 tier at write time.
  /// Read-only fields are never sent.
  Map<String, dynamic> toUpsertJson() {
    return {
      'injectionDate': injectionDate,
      'injectionTime': injectionTime,
      'doseUnits': doseUnits,
    };
  }
}

class Glp1Status {
  const Glp1Status({
    required this.enabled,
    required this.isInjectionDay,
    this.nextDueDate,
    this.lastInjection,
    this.daysSince,
    this.hoursSince,
    this.activeDose,
  });

  final bool enabled;
  final bool isInjectionDay;
  final String? nextDueDate; // YYYY-MM-DD
  final Glp1Injection? lastInjection;
  final int? daysSince;
  final int? hoursSince;
  final Glp1ActiveDose? activeDose;

  factory Glp1Status.fromJson(Map<String, dynamic> j) {
    return Glp1Status(
      enabled: _bool(j['enabled']) ?? false,
      isInjectionDay: _bool(j['isInjectionDay']) ?? false,
      nextDueDate: _str(j['nextDueDate']),
      lastInjection: _objAsT(j['lastInjection'], Glp1Injection.fromJson),
      daysSince: _int(j['daysSince']),
      hoursSince: _int(j['hoursSince']),
      activeDose: _objAsT(j['activeDose'], Glp1ActiveDose.fromJson),
    );
  }
}

// ───────── tolerant scalar helpers (mirror lib/models/journal_entry.dart) ─────────

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

bool? _bool(dynamic v) {
  if (v is bool) return v;
  return null;
}

Glp1Tier? _tier(dynamic v) {
  if (v is! String) return null;
  switch (v) {
    case 'start':
      return Glp1Tier.start;
    case 'current':
      return Glp1Tier.current;
    case 'maintenance':
      return Glp1Tier.maintenance;
  }
  return null;
}

/// Tolerant nested-object decode. Returns null if [v] isn't a map.
T? _objAsT<T>(dynamic v, T Function(Map<String, dynamic>) fromJson) {
  if (v is Map<String, dynamic>) return fromJson(v);
  if (v is Map) return fromJson(v.cast<String, dynamic>());
  return null;
}
