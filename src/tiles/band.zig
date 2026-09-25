//! Navigational-purpose bands: the map from an S-57 cell's compilation scale to
//! the Web-Mercator zoom range it serves. Pure integer math, shared by the baker
//! (which bakes each cell over its band's zooms) and the compositor (which reads
//! the band to decide overscale fill-up), so neither owns the mapping.

const std = @import("std");

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

// Canonical ECDIS/S-101 viewing-scale ladder used by the web client.
// Coarse -> fine.  A chart becomes eligible on the FIRST selected viewing scale
// whose denominator is within OpenCPN's normal vector-chart underzoom limit
// (roughly 4 × native CSCL at zoom modifier 0).
//
// IMPORTANT: ownership is ultimately stored on INTEGER source-tile zooms.  Using
// floor/ceil of the raw fractional 4× crossing is wrong around a tile boundary:
// e.g. at ~39N, CSCL 1:50k crosses 1:200k at z~10.17 (it must already serve the
// selected 1:180k step -> source z10), while CSCL 1:20k crosses 1:80k at z~11.49
// (it must NOT serve the selected 1:90k step; first eligible is 1:45k -> source
// z12).  Quantize to the SAME semantic viewing-scale ladder first, then derive
// the integer source zoom.  This makes chart ownership monotonic across the
// exact scale stops the mariner can select.
pub const ECDIS_DISPLAY_SCALES = [_]f64{
    10_000_000,
    3_500_000,
    1_500_000,
    700_000,
    350_000,
    180_000,
    90_000,
    45_000,
    22_000,
    12_000,
    8_000,
    4_000,
    3_000,
    2_000,
    1_000,
};

fn firstEligibleDisplayScale(max_denom: f64) f64 {
    for (ECDIS_DISPLAY_SCALES) |d| {
        if (d <= max_denom) return d;
    }
    return ECDIS_DISPLAY_SCALES[ECDIS_DISPLAY_SCALES.len - 1];
}

pub fn openCpnAdmissionFloor(cscl: i32, lat_deg: f64) u8 {
    const native: f64 = @floatFromInt(if (cscl > 0) cscl else 50_000);
    const selected = firstEligibleDisplayScale(native * 4.0);

    // Same reference physical pixel as the style/SCAMIN model.  The selected
    // scale is a semantic stop; MapLibre requests floor(cameraZoom) source tiles.
    const k = 78_271.516964020485 * @cos(lat_deg * std.math.pi / 180.0) / 0.0002645;
    if (!(k > 0) or !(selected > 0)) return 0;
    const z = std.math.log2(k / selected);
    if (z <= 0) return 0;
    if (z >= 24) return 24;
    return @intFromFloat(@floor(z));
}

test "OpenCPN admission follows ECDIS viewing-scale stops" {
    // Chesapeake (~39N):
    //   1:80k ×4 = 1:320k -> 350k is too coarse; first eligible step 180k -> z10.
    //   1:50k ×4 = 1:200k -> first eligible step 180k -> z10.
    //   1:20k ×4 =  1:80k -> 90k is too coarse; first eligible step 45k  -> z12.
    try std.testing.expectEqual(@as(u8, 10), openCpnAdmissionFloor(80_000, 39.0));
    try std.testing.expectEqual(@as(u8, 10), openCpnAdmissionFloor(50_000, 39.0));
    try std.testing.expectEqual(@as(u8, 12), openCpnAdmissionFloor(20_000, 39.0));
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
    try std.testing.expectEqual(Band.harbor, bandOf(20_000));
    try std.testing.expectEqual(Band.approach, bandOf(50_000));
    try std.testing.expectEqual(Band.overview, bandOf(3_000_000));
    try std.testing.expectEqual(Band.approach, bandOf(0)); // unknown -> 50k default
}

test "bandZooms is finest-to-coarsest with one-zoom overlap" {
    try std.testing.expectEqual(ZoomRange{ .min = 11, .max = 13 }, bandZooms(.approach));
    try std.testing.expectEqual(ZoomRange{ .min = 9, .max = 11 }, bandZooms(.coastal));
}
