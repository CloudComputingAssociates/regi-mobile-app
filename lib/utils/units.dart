/// Single source of truth for pound <-> kilogram conversion.
///
/// The backend stores weight in kg verbatim and does no server-side
/// units conversion. All conversion happens on the client:
///   • UserSettings bloom uses [kgToLbs] to DISPLAY weights when the
///     user's `personalInfo.units` is "us".
///   • The set-command path uses [lbsToKg] to convert a spoken value
///     into kg BEFORE writing back via PUT /user/settings/field.
///
/// Keep both directions wired to the same constant so display and
/// write paths can never disagree.
const double lbsPerKg = 2.20462;

/// Convert pounds → kilograms. e.g. `lbsToKg(185) ≈ 83.91`.
double lbsToKg(num lbs) => lbs.toDouble() / lbsPerKg;

/// Convert kilograms → pounds. e.g. `kgToLbs(84) ≈ 185.19`.
double kgToLbs(num kg) => kg.toDouble() * lbsPerKg;
