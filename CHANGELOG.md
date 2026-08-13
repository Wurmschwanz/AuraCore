# AuraCore Changelog

## v2.2.0-test1 - Player Buff Aura Cache & Charge Test

- Added a buff-only player AuraCache using SuperWoW aura data when available.
- Added Spell ID and charge/stack detection for tracked player buffs.
- Added charge numbers to Buff Tracker icons for stackable buffs such as Lightning Shield.
- Expanded Test Buff Tracker with Lightning Shield (3/2/1 charges), a normal timed buff, and a stacked proc example.
- No target auras, debuffs, DoTs, nameplate auras, or raid aura scanning were added.

## v2.1.0 - Performance & Stability

### Performance
- Added a smart scheduler that avoids running discovery and tracking work every rendered frame.
- Added source-specific dirty flags for actions, bags, equipment, and buffs.
- Added a cached tracker layout to avoid repeating unchanged anchors and dimensions.
- Added a smart Buff Tracker update driver with combat-aware update intervals.
- The tracker driver now sleeps completely while the tracker is disabled or has no configured slots.
- Reduced unnecessary scans, UI updates, and temporary memory allocations.

### Improvements
- Preserved Blizzard-style cooldown sweeps and compatibility with external cooldown-number addons such as ShaguTweaks.
- Improved tracker responsiveness when buffs change.
- Kept the original cooldown-pulse appearance.
- Added an internal developer profiler and 60-second benchmark. Both are disabled by default.

### Fixes
- Fixed repeated discovery work caused by unrelated events.
- Fixed unnecessary tracker layout updates.
- Improved Buff Tracker startup, wake, sleep, and combat-state handling.
- Various internal stability and cleanup improvements.

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

## 2.0.3-test6 - Tracker Layout Cache
- Added one isolated optimization to BuffTracker.LayoutAndUpdate.
- Reuses unchanged icon anchors, icon sizes, border sizes, and tracker frame dimensions.
- Buff scanning, textures, visibility, cooldown timers, ShaguTweaks cooldown numbers, and proc logic are unchanged.
- Deep profiler remains enabled for direct test5/test6 comparison.

## 2.0.3-test7 - Dirty Discovery
- Split cooldown discovery into independent action, inventory, bag, and buff dirty flags.
- Events now rescan only the affected source instead of all four sources.
- Added a conservative 5-second full safety refresh for Vanilla-client compatibility.
- Retained the tracker layout cache and internal profiler from test6.
