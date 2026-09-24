const std = @import("std");

//! Navigational-purpose bands: the map from an S-57 cell's compilation scale to
//! the Web-Mercator zoom range it serves. Pure integer math, shared by the baker
//! (which bakes each cell over its band's zooms) and the compositor (which reads
//! the band to decide overscale fill-up), so neither owns the mapping.

/// Native [minzoom, maxzoom] Web-Mercator span for a navigational-purpose band.
pub const ZoomRange = struct { min: u8, max: u8 };

/// Navigational-purpose bands, finest -> coarsest (the order bands must be baked
/// in for best-band dedup).
pub const Band = enum(u8) { berthing = 0, harbor, approach, coastal, general, overview };

/// All bands finest -> coarsest (the bake call order).
pub const bands_fine_to_coarse = [_]Band{ .berthing, .harbor, .approach, .coastal, .general, .overview };

/// Map a compilation-scale denominator (CSCL, 1:N) to its band.
pub fn bandOf(cscl: i32) Band {
    const n: i64 = if (cscl <= 0) 50_000 else cscl;
    if (n <= 8_000) return .berthing;
    if (n <= 32_000) return .harbor;
    if (n <= 130_000) return .approach;
    if (n <= 500_000) return .coastal;
    if (n <= 2_300_000) return .general;
    return .overview;
}

// OpenCPN S-57 chart-selection scale: a vector chart remains normally usable
// until the viewport denominator is about 4× the chart's native compilation scale
// (s57chart::GetNormalScaleMax / Quilt::GetNomScaleMin with zoom modifier 0).
// Convert that physical 1:N limit to the INTEGER source-tile zoom which first has
// to carry the chart. We floor the fractional crossing because one z tile serves
// the whole [z,z+1) display interval; ceil would make the chart appear up to one
// full zoom late. This is computed once per cell when the compositor partition is
// opened, never in the tile hot path.
pub fn openCpnAdmissionFloor(cscl: i32, lat_deg: f64) u8 {
    const native: f64 = @floatFromInt(if (cscl > 0) cscl else 50_000);
    const max_denom = native * 4.0;
    // Same physical reference used by the style/SCAMIN model: Web-Mercator
    // metres/CSS-px at z0 divided by the 0.2645 mm reference CSS-pixel pitch.
    const k = 78_271.516964020485 * @cos(lat_deg * std.math.pi / 180.0) / 0.0002645;
    if (!(k > 0) or !(max_denom > 0)) return 0;
    const z = std.math.log2(k / max_denom);
    if (z <= 0) return 0;
    if (z >= 24) return 24;
    return @intFromFloat(@floor(z));
}

test "OpenCPN admission floor is two-scale-level chart admission, not NOAA band floor" {
    // Chesapeake (~39N): an 1:80k approach chart is eligible by about 1:320k,
    // whose crossing is z~9.5, so z9 must contain it. A 1:20k harbour chart
    // crosses around z11.5 and therefore first needs a z11 source tile.
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 9), openCpnAdmissionFloor(80_000, 39.0));
    try std.testing.expectEqual(@as(u8, 11), openCpnAdmissionFloor(20_000, 39.0));
}

/// Overscale fill-up depth DEFAULT: how many zooms past its native max a band's
/// own cells keep baking (only where nothing finer already emitted). Every
/// extension zoom ~4x that band's tile count over its uncovered footprint
/// (measured: +2 turned a 5.6k-tile approach pass into 41k), so the default is
/// ONE crisp overscale zoom; TILE57_FILLUP_DZ=0..2 overrides per bake
/// (Baker.fillup_dz). 0 never blanks — the client camera stops at the probed
/// data depth and MapLibre stretches one level past it.
pub const FILLUP_DZ: u8 = 1;

/// Absolute fill-up ceiling: extension zooms never exceed this. The fill-up
/// serves the MID-ZOOM seam where a coarse chart is the finest coverage (the
/// blank bay at z12-15); letting fine bands extend too (harbor->z17-18,
/// berthing->z19-20) quadruples the tile count per extra zoom across every
/// harbor footprint for content nobody needs — a district pack ballooned from
/// ~800k to 13M+ planned tiles. A band's NATIVE window is never clamped by this;
/// past its data the camera stops at the probed depth instead.
pub const FILLUP_CEIL: u8 = 15;

/// A band's native zoom span. Adjacent bands overlap by one zoom; best-band dedup
/// resolves the overlap to the finer band.
pub fn bandZooms(band: Band) ZoomRange {
    return switch (band) {
        .berthing => .{ .min = 16, .max = 18 },
        .harbor => .{ .min = 13, .max = 16 },
        .approach => .{ .min = 11, .max = 13 },
        .coastal => .{ .min = 9, .max = 11 },
        .general => .{ .min = 7, .max = 9 },
        .overview => .{ .min = 0, .max = 7 },
    };
}

test "bandOf maps compilation scale to band" {
    const std = @import("std");
    try std.testing.expectEqual(Band.harbor, bandOf(20_000));
    try std.testing.expectEqual(Band.approach, bandOf(50_000));
    try std.testing.expectEqual(Band.overview, bandOf(3_000_000));
    try std.testing.expectEqual(Band.approach, bandOf(0)); // unknown -> 50k default
}

test "bandZooms is finest-to-coarsest with one-zoom overlap" {
    const std = @import("std");
    try std.testing.expectEqual(ZoomRange{ .min = 11, .max = 13 }, bandZooms(.approach));
    try std.testing.expectEqual(ZoomRange{ .min = 9, .max = 11 }, bandZooms(.coastal));
}
