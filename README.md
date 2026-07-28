# AuraCore

AuraCore is a lightweight all-in-one aura, proc, cooldown, and buff-tracking addon for Turtle WoW and other Vanilla WoW 1.12 clients.

## Features

### Cooldown Pulses
- Large central pulse when tracked cooldowns become ready
- Spell, equipment, and bag-item support
- Character-specific filters
- Adjustable size, duration, opacity, animation, and position

### Buff Expiration Pulses
- Alerts when tracked buffs are about to expire
- Automatic long-duration buff detection
- Additional buff list and blacklist
- Optional red expiration pulse
- Test button included

### Proc Alerts
- ProcDoc-inspired class overlays
- Buff- and action-based proc detection
- Per-proc scale, opacity, and position settings
- Optional pulse and smooth visual expiry
- Multi-proc test mode

### Active Buff Tracker
- Clickable tracker slots
- Tracks buffs, talent procs, and trinket procs while active
- Empty and inactive slots stay hidden
- Blizzard-style cooldown sweep
- Adjustable icon size, spacing, columns, and position
- Per-character configuration
- Test mode and unlockable drag handle

### Performance
- Event-driven aura updates with adaptive fallback scans
- No scans while the tracker is disabled or empty
- Cached buff names and icons
- Layout and cooldown updates only when required

## Installation

1. Download the latest release ZIP.
2. Extract it.
3. Copy the `AuraCore` folder into:

   `World of Warcraft\Interface\AddOns\`

4. Restart the game or use `/reload`.

The final path must be:

`World of Warcraft\Interface\AddOns\AuraCore\AuraCore.toc`

## Commands

- `/ac` — Open settings
- `/ac test` — Test the main pulse
- `/ac reset` — Reset settings
- `/ac ignore NAME` — Add an entry to the cooldown filter
- `/ac clear` — Clear the cooldown filter
- `/ac invert` — Toggle cooldown filter mode
- `/ac list` — Show the cooldown filter

Legacy `/pc`, `/pulsecore`, and `/dcp` commands remain supported.

## Updating from PulseCore

AuraCore keeps the existing `DCP_Saved` and `DCP_SavedPerCharacter` SavedVariables, so current PulseCore settings are retained.

Remove the old `PulseCore` addon folder after installing AuraCore to avoid loading both versions simultaneously.

## Credits

- Proc overlay artwork and proc data are based on ProcDoc. See `LICENSE-ProcDoc`.
- Additional overlay artwork is based on SpellActivationOverlay. See `LICENSE-SpellActivationOverlay`.

## License

Third-party assets remain subject to their included licenses. Original AuraCore code is provided for use with the addon repository.
