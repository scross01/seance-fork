//! The only in-code copy of the release version. The About dialog and
//! `seance --version` both read it, so the two can never disagree.
//! scripts/bump-version.sh keeps this synced with build.zig.zon.

pub const string = "0.8.0";
