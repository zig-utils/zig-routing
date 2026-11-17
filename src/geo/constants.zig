//! Ported from valhalla/midgard/constants.h (Valhalla 3.9.3).
//!
//! Values are copied verbatim, including which ones upstream declares as
//! `float`: several computations (for example the longitude scale) run in
//! single precision upstream, and matching results means matching that.

pub const sec_per_minute: f32 = 60.0;
pub const min_per_sec: f32 = 1.0 / 60.0;
pub const sec_per_hour: f32 = 3600.0;
pub const hour_per_sec: f32 = 1.0 / 3600.0;
pub const sec_per_millisecond: f64 = 0.001;
pub const millisecond_per_sec: f64 = 1000;
pub const seconds_per_minute: u32 = 60;
pub const seconds_per_hour: u32 = 3600;
pub const seconds_per_day: u32 = 86400;
pub const seconds_per_week: u32 = 604800;

pub const feet_per_mile: f32 = 5280.0;
pub const mile_per_foot: f32 = 1.0 / feet_per_mile;
pub const feet_per_meter: f32 = 3.2808399;
pub const meters_per_km: f32 = 1000.0;
pub const km_per_meter: f32 = 0.001;
pub const mile_per_km: f32 = 0.621371;
pub const mile_per_meter: f32 = mile_per_km / 1000;
pub const km_per_mile: f32 = 1.609344;

pub const rad_earth_meters: f32 = 6378160.187;
pub const rad_earth_meters_d: f64 = 6378160.187;
/// Declared `double` upstream but initialised from a float literal (110567.0f).
pub const meters_per_degree_lat: f64 = @as(f32, 110567.0);
pub const km_per_decimeter: f64 = 0.0001;
pub const meter_per_decimeter: f64 = 0.1;
pub const decimeter_per_meter: f64 = 10;
pub const mph_to_meters_per_sec: f32 = 0.44704;
pub const decimeter_per_sec_to_kph: f64 = 0.36;
pub const kph_to_meters_per_sec: f64 = 1000.0 / 3600.0;
pub const meters_per_sec_to_kph: f64 = 3600.0 / 1000.0;

pub const pi: f32 = 3.14159265;
pub const pi_d: f64 = 3.14159265358979323846264338327950288;
pub const pi_over_2: f32 = pi * 0.5;
pub const pi_over_4: f32 = pi * 0.25;
pub const deg_per_rad: f32 = 180.0 / pi;
pub const deg_per_rad_d: f64 = 180.0 / pi_d;
pub const rad_per_deg: f32 = pi / 180.0;
pub const rad_per_deg_d: f64 = pi_d / 180.0;
pub const epsilon: f32 = 0.000001;
pub const pi_over_2_d: f64 = pi_d * 0.5;
pub const pi_double: f64 = 3.14159265358979323846;
pub const tons_short_to_metric: f32 = 0.907;

/// Default tolerance for approximate coordinate equality (point2.h LL_EPSILON).
pub const ll_epsilon: f32 = 0.00002;

/// util_core.h `equal`: |a - b| <= epsilon.
pub fn approxEqual(comptime T: type, a: T, b: T, eps: T) bool {
    const diff = a - b;
    return if (diff < 0) diff >= -eps else diff <= eps;
}
