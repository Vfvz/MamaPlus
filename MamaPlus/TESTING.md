# Testing MamaPlus

## Headless (no game)

```
sh tests/run.sh
```

Runs every `tests/test_*.lua` in its own Lua 5.1 interpreter against `tests/mock.lua`
(a fake WoW API plus a fake Mama-forever), then luacheck, then the secret-check-order
grep, then `tools/package.sh --check`. CI (`.github/workflows/mamaplus.yml`) does the
same and builds the zip.

## In game

MamaPlus only runs next to Mama-forever, on a team that is already paired
(`/mama s N` in each window, token exchanged). Use two or more clients. Nothing below
needs more than a throwaway character; the death probes should be run on a character
you do not mind killing, on a non-Hardcore realm.

Every probe prints into chat and into a copyable window: `/mama plus probe` (all
sections) or `/mama plus probe <core|comms|idle|where|follow|death|supplies|find|keys>`.
Click the text, Ctrl+A, Ctrl+C.

Mama's `/mama bug` log (100 lines) fills with MamaPlus messages in about a minute while
grouped; for a Mama bug run `/mama clearlog`, reproduce, then `/mama bug` at once, or use
`/mama plus probe`.

Expected results are written as they were designed; anything else is a finding. A
feature whose probe fails switches itself off with one printed line, so record the
line and carry on.

### Core

1. Load MamaPlus next to Mama and `/reload`: one line "+ MamaPlus 0.1.0 loaded (/mama
   plus)", no Lua error. `/mama plus` lists the commands; `/mama plus status` shows
   comms on, your slot, token yes, the lead, and the limiter counters at 0.
2. Options: Game Menu > Options > AddOns > Mama-forever > Plus (or a top-level
   "MamaPlus" entry when the subpage API is missing). `/mama plus options` opens it.
   Toggle something, `/reload`: it stays. The two Death auto toggles are greyed on
   Hardcore with a note.
3. `/mama plus test` out of combat: sound, raid-warning text, your row flashes red for
   3 s and shows a white TEST icon; the name is cut with "..." rather than overlapping;
   the lead star stays visible; hovering the row shows Mama's lines then "TEST: alert
   check".
4. The same on a training dummy in combat: no "Interface action failed because of an
   AddOn", no ADDON_ACTION_FORBIDDEN. `/mama plus probe core` in combat: note the
   `InChatMessagingLockdown` value (plainly true means in-combat messages arrive after
   combat) and `Enum.SendAddonMessageResult`.
5. Two grouped clients: `/mama plus team` shows the other window within 30 s with its
   version. Then on the alt: `/afk` -> AFK icon on the lead within ~3 s; die -> X;
   equip an item below 25% -> NN%; open a trade -> T on both; ready check -> R. Note
   whether CONFIRM_SUMMON and START_LOOT_ROLL fire at all.
6. `/reload` the alt: its row shows `!` after 75-105 s and clears when its heartbeat
   returns. Leave the group: the record and the `!` are gone. Invite and leave 8 times
   quickly: `/mama plus status` shows at most one extra heartbeat sent.
7. Alt with a different version in its TOC: orange `v0.1.1` on its row.
8. `/mama plus probe core` records: build, interface, WOW_PROJECT_ID, issecretvalue,
   UnitHealth secret, the C_Secrets predicates, IsHardcore, Moving, event validity.
9. `/mama plus probe comms` in a party: 40 messages on prefix MAMAPLUSP; record the
   first non-zero result code and when it came (the limiter is tuned for 6 burst /
   30 per minute; adjust if the client allows less).

### Idle

10. `/mama lead` on a window that is not the group leader. The alt fights standing
    still for 5 s -> sound, "Slot N Name is idle in combat", red flash and IDLE only on
    that lead window; `/mama lead auto` moves the alert to the group leader. Melee
    auto-attack alone still counts as idle; Auto Shot does not.
11. If `IsPlayerMoving()` and `GetUnitSpeed("player")` come back secret (probe idle),
    one line "movement is secret on this client" and no idle or stuck icons: report it.

### Where

12. W1 `UnitLevel/UnitXP/UnitXPMax("player")`: number, not secret (probe where).
13. W2 `GetXPExhaustion()`, `IsResting()` in an inn and outside.
14. W3 `GetZoneText()`, `GetSubZoneText()`: plain; longest zone name vs the 20-byte cap.
15. W4 Cross a zone line with `/mama plus debug` on: one change line, one heartbeat
    within ~3 s, the lead's row tooltip shows the new zone; ZONE icon while apart.
16. W5 `CheckInteractDistance("party1", 4)` at 10 yd true, at 40 yd false; FAR icon on
    the lead's window when apart, frozen while either side fights.
17. W6 Alt takes a flight: FLY on its row within ~3 s, clears after landing.
18. W7 `/mama plus gate 14` on the lead: every window below 14 shows its level in red;
    `/mama plus gate off` clears it. A level-up sends a heartbeat (level in the tooltip).
19. W8 A row with level + FAR + ZONE + AFK at once: the name is still readable, the
    icons that do not fit are in the tooltip.

### Follow

20. F1 On a follower, `/mama plus probe follow`: IsPlayerMoving boolean, GetUnitSpeed
    number, neither secret (else the stuck sampler is off, by design).
21. F2 `CheckInteractDistance(<lead unit>, 2)` at 5 yd true, 20 yd false.
22. F3 `GetBindingKey("CLICK MamaFollow:LeftButton")` returns the key you bound in Mama
    (the cue names it) or nil (generic wording).
23. F4 Unfocus the client and `/run FlashClientIcon()`: the taskbar flashes.
24. F5 `/mama plus follow cue`: the banner shows 5 s; pressing follow hides it.
25. F6 Drink, and Blink on a mage, while following: the lead's row tooltip says "cast
    Drink" / "cast Blink", no sound, no banner.
26. F7 The lead pulls; the alt presses a movement key: no alert, no banner; after combat
    F! with the "combat" tip within ~2 s.
27. F8 Instance portal or zeppelin: "zone" tip and the banner on the alt.
28. F9 The alt stops behind a wall, the lead walks 40 yd: Mama's own warning once
    (unchanged), MamaPlus F? and one "stuck behind you" alert, tip "stuck N s ago".

### Death (throwaway character, non-Hardcore)

29. D0 A warlock with a Soulstone dies: the prompt says "Soulstone available:
    auto-release off"; no countdown; probe death prints `GetSelfResurrectOptions`.
30. D1 `/mama plus probe death`: RepopMe/RetrieveCorpse/AcceptResurrect present;
    death events valid; UnitIsDeadOrGhost plain; IsHardcore false (not nil).
31. D2 The alt dies: prompt within 1 s on the alt, desk row "dead 0:0x" on the lead
    within 2 s, one alert, X on the row.
32. D3 Click [Release]: ghost, "G" on the row, no FORBIDDEN, deathProbe repopClick=ok
    (a blocked click hides the button and points at the game's popup).
33. D4 Ghost-walk to the corpse: CORPSE_IN_RANGE -> [Retrieve] (note the recovery
    delay); click -> alive, retrieveClick=ok.
34. D5 A priest casts Resurrection on the dead alt: RESURRECT_REQUEST on the alt shows
    "res offered", RES on its row, the desk shows it; the lead's log shows
    `x;R;r;Resurrection;<target>`; cancel the cast -> `x;R;x`.
35. D6 autoRelease on, 10 s: countdown on the prompt and the desk, one heartbeat; at
    expiry the alt releases (repopAuto=ok) or prints "turned off: blocked". Repeat
    with [Cancel auto-release] on the lead at 5 s: stays dead, "cancelled by the
    lead". Repeat with a Resurrection started: the countdown holds; release after
    20 s if no RESURRECT_REQUEST arrived.
36. D7 autoRetrieve on, after D4 was ok, lead alive: retrieved without a click; lead a
    ghost: "waiting for the lead".
37. D8 Hardcore realm if reachable: IsHardcore true, auto toggles greyed, no countdown.

### Supplies

38. S1 `/mama plus probe supplies`: NUM_BAG_SLOTS, NUM_REAGENTBAG_SLOTS,
    NUM_TOTAL_EQUIPPED_BAG_SLOTS, bag 5 slots and family with a soul bag in slot 5
    (0 slots = bag 5 invisible to addons).
39. S2 Class/subclass of 4540, 159, 1251, 2512, 6265, 5512 and the use spell of 4540
    and 159: decides whether food and drink are split correctly.
40. S3 `/mama plus supplies items` on each window lists what was counted per kind.
41. S4 Eat one food below the threshold out of combat: the lead's row shows an orange
    F within ~31 s; `/mama plus supplies` shows every slot's counts.
42. S5 Hunter in combat with debug on: no heartbeat from counts while fighting, one
    within 6 s after.
43. S6 Trade with a grouped alt that is low on food: up to 3 food stacks appear in the
    trade window before Mama's mats; "give mats" gives the same list; an ungrouped or
    stale partner gets Mama's list only. You still click Trade.

### Find

44. P1 `/mama plus probe find`: TooltipDataProcessor, AddTooltipPostCall,
    Enum.TooltipDataType.Item present (else the tooltip line is off, command only).
45. P2 `/mama plus find ` then shift-click a bag item: the link is inserted; the own
    count prints; within 3 s "slot2 Name x12 (+N bank)" lines in slot order, or
    "nobody else has it"; a window that did not answer is named.
46. P3 `/mama plus find Linen Cloth` and `/mama plus find 2589` give the same result.
47. P4 Hover the item: "Team: slot2 x12 (N min ago)" from the cached answers; `/mama
    plus status` shows no message was sent by hovering.

### Keys

48. K1 After a full client restart, Key Bindings > AddOns shows "Mama-forever Plus"
    with seven entries. Bind "Target slot 2" and press it out of and in combat: targets
    slot 2, no error. `/mama plus keys` shows `/target partyN` per slot.
49. K2 Follow the lead, press "Stop following": AUTOFOLLOW_END fires (Mama's own
    out-of-range warning may follow). If it keeps following, report it.
50. K3 "Target slot 5" with no slot 5: one "slot 5 is not in the group" line; "Target
    lead" when you are the lead targets yourself.
51. K4 A member leaves during combat: no error in combat; after combat `/mama plus
    keys` shows the new tokens.
