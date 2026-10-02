//! Generated non-ROM ZIP fixtures (8 KiB synthetic member + text file).
pub const deflate_zip = @embedFile("deflate.zip");
pub const stored_zip = @embedFile("stored.zip");
/// SHA-1 of the synthetic csd_u7a.u7 member in both fixtures.
pub const member_sha1 = "5873b9bacdf00c303947874df48abd95b3321812";
