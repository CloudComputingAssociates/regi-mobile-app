import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/settings_service.dart';
import '../../utils/units.dart';

/// Bloom content: read-only view of the user's settings (Personal Info,
/// Nutrition Targets, RegiMenu + Planning). Editing lives at
/// app.regimenu.com — this fetches once on mount and renders display
/// text only.
class UserSettings extends StatefulWidget {
  const UserSettings({super.key});

  @override
  State<UserSettings> createState() => _UserSettingsState();
}

class _UserSettingsState extends State<UserSettings> {
  final SettingsService _service = SettingsService();
  late final Future<Map<String, dynamic>> _future;

  static const Color _proteinColor = Color(0xFF6BA539);
  static const Color _carbsColor = Color(0xFFD2691E);
  static const Color _fatsColor = Color(0xFF8E44AD);
  static const int _waterIconMax = 12;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _fetch() async {
    final auth = context.read<AuthService>();
    final jwt = await auth.getAccessToken();
    if (jwt == null) {
      throw Exception('Not authenticated.');
    }
    return _service.fetchAllSettings(jwt);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFF2B33D)),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Could not load settings',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.error}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return _buildLoaded(snapshot.data!);
      },
    );
  }

  Widget _buildLoaded(Map<String, dynamic> data) {
    final personal = _asMap(data['personalInfo']);
    final goals = _asMap(data['dailyGoals']);
    final regi = _asMap(data['regiMenu']);
    final units = _str(personal?['units']) ?? 'us';
    final isMetric = units == 'metric';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _personalSection(personal, isMetric),
          const SizedBox(height: 20),
          _nutritionSection(personal, goals, isMetric),
          const SizedBox(height: 20),
          _regiMenuSection(regi),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'Modify user settings on Web app.regimenu.com',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────── Section 1 — Personal Info ─────────

  Widget _personalSection(Map<String, dynamic>? p, bool isMetric) {
    final dob = _str(p?['dateOfBirth']);
    final sex = _str(p?['sex']);
    final heightCm = _numNonZero(p?['heightCm']);
    final currentKg = _numNonZero(p?['currentWeightKg']);
    final targetKg = _numNonZero(p?['targetWeightKg']);
    final activity = _str(p?['activityLevel']);
    final lastUpdated = _str(p?['lastUpdated']);

    final delta = _formatWeightDelta(currentKg, targetKg, isMetric);
    final goalStr = _formatWeight(targetKg, isMetric);
    final goalWithDelta = delta == null ? goalStr : '$goalStr  ($delta)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Personal Info'),
        _row('DOB', dob ?? '—'),
        _row('Sex', _capitalize(sex) ?? '—'),
        _row('Height', _formatHeight(heightCm, isMetric)),
        _row('Weight', _formatWeight(currentKg, isMetric)),
        _row('Goal', goalWithDelta),
        _row('Activity', _humanize(activity) ?? '—'),
        if (lastUpdated != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'last updated $lastUpdated',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
      ],
    );
  }

  // ───────── Section 2 — Nutrition Targets ─────────

  Widget _nutritionSection(
    Map<String, dynamic>? p,
    Map<String, dynamic>? g,
    bool isMetric,
  ) {
    final carbScale = _numNonZero(p?['carbScaleGrams']);
    final proteinRatio = _numNonZero(p?['proteinRatio']);
    final deficitPercent = _numAllowZero(p?['deficitPercent']);
    final calories = _numNonZero(g?['calories']);
    final protein = _numNonZero(g?['protein']);
    final carbs = _numNonZero(g?['carbs']);
    final fat = _numNonZero(g?['fat']);
    final fiber = _numNonZero(g?['fiber']);
    final sodium = _numNonZero(g?['sodium']);
    final isOverridden = g?['isOverridden'] as bool?;
    final waterMode = _str(g?['waterMode']);
    final waterGlasses = _intNonZero(g?['waterGlasses']);
    final bottleOz = _intNonZero(g?['bottleSizeOz']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Nutrition Targets'),
        _row('Carbs', carbScale == null ? '—' : '${_fmtNum(carbScale)} g'),
        _row(
          'Protein ratio',
          proteinRatio == null
              ? '—'
              : '${_fmtNum(proteinRatio)} g/lb of body weight',
        ),
        _row('Calories', _formatCalories(calories, deficitPercent)),
        const SizedBox(height: 10),
        _macroRow(protein, fat, carbs),
        const SizedBox(height: 8),
        _macroPie(protein, carbs, fat),
        const SizedBox(height: 10),
        _row('Fiber', fiber == null ? '—' : '${_fmtNum(fiber)} g'),
        _row('Sodium', sodium == null ? '—' : '${_fmtNum(sodium)} mg'),
        if (isOverridden == false)
          const Padding(
            padding: EdgeInsets.only(top: 4, left: 4),
            child: Text(
              '(calculated from your personal info)',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        const SizedBox(height: 14),
        _waterBlock(waterMode, waterGlasses, bottleOz),
      ],
    );
  }

  Widget _macroRow(num? protein, num? fat, num? carbs) {
    return Row(
      children: [
        Expanded(child: _macroChip('Proteins', protein, _proteinColor)),
        const SizedBox(width: 6),
        Expanded(child: _macroChip('Fats', fat, _fatsColor)),
        const SizedBox(width: 6),
        Expanded(child: _macroChip('Carbs', carbs, _carbsColor)),
      ],
    );
  }

  Widget _macroChip(String label, num? grams, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          grams == null ? '—' : '${_fmtNum(grams)} g',
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }

  Widget _macroPie(num? protein, num? carbs, num? fat) {
    final p = (protein ?? 0).toDouble();
    final c = (carbs ?? 0).toDouble();
    final f = (fat ?? 0).toDouble();
    if (p + c + f <= 0) return const SizedBox.shrink();
    return Center(
      child: SizedBox(
        height: 120,
        width: 120,
        child: PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: 0,
            startDegreeOffset: -90,
            sections: [
              _pieSection(p, _proteinColor, 'P'),
              _pieSection(c, _carbsColor, 'C'),
              _pieSection(f, _fatsColor, 'F'),
            ],
          ),
        ),
      ),
    );
  }

  PieChartSectionData _pieSection(double value, Color color, String label) {
    return PieChartSectionData(
      value: value,
      color: color,
      title: label,
      radius: 58,
      titleStyle: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _waterBlock(String? mode, int? count, int? bottleOz) {
    const titleStyle = TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    if (mode == null || count == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text('Daily Water Intake Target', style: titleStyle),
          SizedBox(height: 4),
          Text('—', style: TextStyle(color: Colors.white70)),
        ],
      );
    }
    final isBottle = mode == 'bottle';
    final asset = isBottle
        ? 'assets/images/waterbottleiconblue.png'
        : 'assets/images/WaterGlassFull.png';
    final summary = isBottle
        ? '$count bottles, holds ${bottleOz ?? '—'} oz'
        : '$count × 16oz glasses';
    final iconCount = math.min(count, _waterIconMax);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Daily Water Intake Target', style: titleStyle),
        const SizedBox(height: 4),
        Text(summary, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: List.generate(
            iconCount,
            (_) => Image.asset(asset, width: 28, height: 28),
          ),
        ),
      ],
    );
  }

  // ───────── Section 3 — RegiMenu + Planning ─────────

  Widget _regiMenuSection(Map<String, dynamic>? r) {
    final meals = _intNonZero(r?['mealsPerDay']);
    final fasting = _str(r?['fastingType']);
    final start = _str(r?['eatingStartTime']);
    final week = _str(r?['weekStartDay']);
    final repeats = _intNonZero(r?['repeatMeals']);
    final foods = _str(r?['foodListSource']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('RegiMenu + Planning'),
        _row('Meals', meals == null ? '—' : '$meals meals'),
        _row('Fasting', _formatFasting(fasting)),
        _row('Start at', start ?? '—'),
        _row('Week Starts', _capitalize(week) ?? '—'),
        _row('Meal Repeats', repeats == null ? '—' : '$repeats per week'),
        _row('Foods from', _formatFoodSource(foods)),
      ],
    );
  }

  // ───────── Readers & formatters ─────────

  Map<String, dynamic>? _asMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.cast<String, dynamic>();
    return null;
  }

  String? _str(dynamic v) {
    if (v == null) return null;
    if (v is String) return v.isEmpty ? null : v;
    return v.toString();
  }

  num? _numNonZero(dynamic v) {
    final n = _numAllowZero(v);
    if (n == null || n == 0) return null;
    return n;
  }

  num? _numAllowZero(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  int? _intNonZero(dynamic v) {
    if (v == null) return null;
    int? out;
    if (v is int) {
      out = v;
    } else if (v is num) {
      out = v.toInt();
    } else if (v is String) {
      out = int.tryParse(v);
    }
    if (out == null || out == 0) return null;
    return out;
  }

  String _fmtNum(num v) {
    if (v == v.toInt()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }

  String? _capitalize(String? s) {
    if (s == null || s.isEmpty) return null;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }

  String? _humanize(String? s) {
    if (s == null || s.isEmpty) return null;
    return s
        .split('_')
        .map((w) => w.isEmpty
            ? ''
            : w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  String _formatHeight(num? cm, bool isMetric) {
    if (cm == null) return '—';
    if (isMetric) return '${_fmtNum(cm)} cm';
    final inches = cm / 2.54;
    final ft = (inches / 12).floor();
    final inRem = (inches % 12).round();
    return '$ft ft $inRem in';
  }

  String _formatWeight(num? kg, bool isMetric) {
    if (kg == null) return '—';
    if (isMetric) return '${_fmtNum(kg)} kg';
    return '${kgToLbs(kg).round()} lbs';
  }

  String? _formatWeightDelta(num? currentKg, num? targetKg, bool isMetric) {
    if (currentKg == null || targetKg == null) return null;
    final deltaKg = targetKg - currentKg;
    if (isMetric) {
      final rounded = deltaKg.round();
      if (rounded == 0) return '±0 kg';
      return '${rounded > 0 ? '+' : '−'}${rounded.abs()} kg';
    }
    final lbs = kgToLbs(deltaKg).round();
    if (lbs == 0) return '±0 lbs';
    return '${lbs > 0 ? '+' : '−'}${lbs.abs()} lbs';
  }

  String _formatCalories(num? cals, num? deficitPct) {
    final calPart = cals == null ? '—' : _fmtNum(cals);
    String tail;
    if (deficitPct == null || deficitPct == 0) {
      tail = 'maintenance';
    } else if (deficitPct > 0) {
      tail = '${deficitPct.abs().round()}% deficit';
    } else {
      tail = '${deficitPct.abs().round()}% surplus';
    }
    return '$calPart, $tail';
  }

  String _formatFasting(String? f) {
    if (f == null) return '—';
    switch (f) {
      case '16_8':
        return '16:8';
      case 'none':
        return 'None';
      case 'omad':
        return 'OMAD';
      default:
        return _humanize(f) ?? '—';
    }
  }

  String _formatFoodSource(String? f) {
    if (f == null) return '—';
    switch (f) {
      case 'yeh_plus_myfoods':
        return 'YEH + MyFoods';
      case 'yeh':
        return 'YEH';
      case 'myfoods':
        return 'MyFoods';
      default:
        return _humanize(f) ?? '—';
    }
  }

  // ───────── Layout helpers ─────────

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60),
            ),
          ),
          Text(
            value,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}
