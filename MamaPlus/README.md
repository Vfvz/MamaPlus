# MamaPlus

A companion addon for MooreaTV's [Mama-forever](https://github.com/mooreatv/MAMA-multiboxing) on
World of Warcraft: Forever (Interface 16001). It needs Mama and hooks into it through
`MamaForever`; Mama's own files are not changed, so Mama updates keep working.

Like Mama, every window acts only on itself. MamaPlus sends each window's own plain facts to
the team over Mama's signed messages (one Mama message kind, `x`, with its own sub-kinds, behind a
rate limiter so Mama's own invites and quest messages are never crowded out) and draws what it
receives. No message ever makes another window perform a protected action; the two opt-in
automations (auto-release and auto-retrieve after a death) act on that window's own death from
its own events.

## Install

Copy the `MamaPlus` folder next to `Mama` in

```
World of Warcraft\_classic_beta_\Interface\AddOns\
```

on every account of the team, then **restart the client** (key bindings are read at startup).
The team must already be paired in Mama (`/mama s N` in each window, token exchanged).

## What it adds

**Icons on Mama's status rows** (left of the bag count; hover a row for details). Only
exceptions show, in this order: red `!` when a grouped window has not been heard from for 75 s,
`X` dead, grey `G` ghost, red `IDLE`, `F!` not following (cause in the tooltip) or orange `F?`
stuck, red `FAR` out of follow range, orange `ZONE` in another zone, the level in red when below
the level gate or orange when well below the lead, green `RES` when a resurrection is offered,
blue `TSLR` for a pending trade / summon / loot roll / ready check, yellow `AFK`, red `18%` low
durability, orange `FDBPASH` letters for low food / drink / bandages / potions / ammo / shards /
Healthstones, light blue `FLY` on a flight, and the version when it differs from yours. What does
not fit on the row is in the tooltip, with the level, XP, rested state and zone.

**Alerts on Mama's lead** (sound, raid-warning text, red row flash):
- **Idle in combat**: a member stands still in combat without casting for 5 s (set per window).
  Melee auto-attack alone does not count as activity (such a member is reported idle); ranged
  auto-shot does.
- **Stuck behind you**: a member is following but has not moved for 4 s while it is more than
  about 10 yards (trade range) from you. Mama's own out-of-range warning is left as it is.
- **Deaths**: "Team wipe: 4 dead" or "Pri Cuthbridge died", one alert per burst.

**Follow doctor**: when follow breaks on a window, that window shows a "Press <key> to follow
<lead>" banner (the key is the one bound to Mama's follow) and the lead's row tooltip says why:
died, took a flight, changed zone, cast a spell, entered combat, stuck, or stopped by hand.

**Wipe recovery desk**: a dead window gets a prompt with [Release] and [Retrieve] buttons and
the corpse delay; the lead sees a desk under the status window with who is dead or a ghost, who
has a resurrection offered, who can resurrect (class and level), and a WIPE title when everyone is
down. Auto-release after N seconds and auto-retrieve when the lead is alive are opt-in and off by
default; they never run on Hardcore, never when a Soulstone or Reincarnation is available, and
turn themselves off with a message if the game blocks the call. Resurrections are never accepted
for you.

**Supplies**: each window counts its food, drink, bandages, potions, ammo, Soul Shards,
Healthstones and reagents (bags 0-5); rows show orange letters below your thresholds. When you
trade with a team member who is low, Mama's trade fill also puts up to three stacks of what they
lack in the window first (you still click Trade).

**Find**: `/mama plus find <item link, id or name>` asks every window and prints "slot2 Pri
Cuthbridge x12 (+20 bank)". Item tooltips show the last answers ("Team: slot2 x12, 2 min ago")
without sending anything.

**Level gate**: `/mama plus gate 14` colours the level of every window below 14 red (for a
dungeon with a level requirement); `/mama plus gate off` clears it.

**Key bindings** (Game Menu > Key Bindings > Mama-forever Plus): Target lead, Target slot 1-5,
Stop following. Each press acts only on the window you are in.

## Commands

`/mama plus` lists them (also `/mamaplus`):

| Command | Effect |
|---|---|
| `status` | comms state, slot, lead, message counters, blocked actions |
| `team` | one line per team member: version, flags, durability, dialogs, fields |
| `test` | sound, warning, flash and a TEST icon on your own row |
| `icons [on\|off]` | icons on the Mama rows |
| `idle [on\|off]` | idle-in-combat alert (the icon always shows) |
| `where` | level, XP, zone and flags per slot |
| `gate [N\|off]` | level gate for the team |
| `follow [cue]` | follow state per member; `cue` shows the banner for 5 s |
| `death [cancel\|release\|retrieve]` | the desk lines; cancel an auto-release (lead); release or retrieve on this window |
| `supplies [items]` | counts per slot; `items` lists what this window counted |
| `find <item>` | who has the item, how many |
| `keys` | the macro text behind each key binding |
| `options` | open the settings page |
| `probe [section]` | capability probe into chat and a copyable window (see TESTING.md) |
| `debug` | debug lines on or off |

Settings: Game Menu > Options > AddOns > Mama-forever > Plus (`/mama plus options`).

## Files

```
MamaPlus.toc
Core.lua      namespace, secret-value helpers, events, saved variables, options and command
              registries, the message path through Mama (letter x, keyed rate limiter)
Alert.lua     sound + raid warning + row flash; lead-only gate
Rows.lua      the icon strip on Mama's status rows, tooltip lines, flash
Status.lua    heartbeat (version, flags, durability, dialogs, fields) and the basic icons
Idle.lua      idle-in-combat detection and alert
Where.lua     level, XP, rested, zone, taxi, range; level gate
Follow.lua    follow state and cause, stuck sampler, the follow banner
Death.lua     own death state, prompt, opt-in auto-release/retrieve, healer res reports
DeathDesk.lua the lead's death desk and death alerts
Supplies.lua  consumable counts, low icons, trade top-up
Find.lua      team item search and tooltip line
Keys.lua      the CLICK key bindings (Bindings.xml is loaded by the client on its own)
Options.lua   the Plus settings page
Probe.lua     /mama plus probe
```

Tests: `sh tests/run.sh` (Lua 5.1 + luacheck, no game needed). In-game checks: TESTING.md.

## License

LGPLv3, like Mama.
