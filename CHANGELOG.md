# Changelog

## v2.0.2 - Minimap Startup Fix

- Fixed a Lua error during login caused by a missing minimap-position function.
- Restored correct minimap-button positioning and dragging.
- Kept the working Buff Tracker startup fix unchanged.

## v2.0.1

- Fixed the Buff Tracker not initializing reliably after login or `/reload`.
- Reverted the aggressive tracker scan throttling from the performance pass.
- Buffs and trinket procs are detected immediately without opening the settings or clicking Test.
- Kept the tracker icon inset fix from v2.0.0.

## AuraCore 2.0.0

### Added
- ProcDoc-inspired proc alerts for all supported classes
- Independent per-proc scale, opacity, and position settings
- Per-character proc and tracker configuration
- Optional smooth proc-expiration fade
- Red buff-expiration pulse
- Clickable active buff tracker slots
- Talent-proc and trinket-proc tracking through active player buffs
- Blizzard-style cooldown sweep for tracked buffs
- Tracker test mode and movable tracker bar

### Improved
- Extensive allocation and CPU optimizations
- Event-driven buff detection with adaptive fallback scanning
- Cached aura names and icons
- Improved Shadow Trance handling and failed-cast protection
- Cleaner settings layout and class-specific proc configuration

### Renamed
- PulseCore is now AuraCore to better reflect its expanded feature set
- Existing settings remain compatible through the original SavedVariables names
