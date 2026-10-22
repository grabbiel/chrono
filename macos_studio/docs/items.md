# Items (Item, Gear & Lore Database, Module 4)

The item tables cover the weapons, armour, helmets, accessories and
consumables: their records, names, descriptions, the stat boosts they grant
and the menu's equipment-stat rule. Each field is decoded with evidence,
imported into a project, edited in **Items**, and written back by
`chronoforge rom build`.

The Python reference, which also runs every claim's check, is
`re_workspace/tools/ct_items.py`. The Swift twins are in `CTItems.swift`:
- `ItemDef.Record` and `ItemTablesDef` (the project model), and the codec `CTItemROM`;
- `CTEquipStats`: the menu's equipment-stat rule.

No ROM data is stored in the repository. The import reads your ROM into your
project's `items/` files and `item_tables.json`; the tests use synthetic
tables, records and images.

## Item ids

`Menu_ItemCategoryBounds` (`$C2:88A7`) splits the 242 ids into five
categories. Each category's first id is empty (zero records, a blank name).

| Ids | Category | Record A | Record B | Equip slot (record) |
|---|---|---|---|---|
| $00–$59 | weapon | 6 B | 5 B | +$29 |
| $5A–$7A | armor | 6 B | 3 B | +$28 |
| $7B–$93 | helmet | 6 B | 3 B | +$27 |
| $94–$BB | accessory | 4 B | 4 B | +$2A |
| $BC–$F1 | consumable | 3 B | 4 B | — |

## The tables

All are in bank `$CC` except the layout tables in bank `$FF`.

| Table | Address | Size | Use |
|---|---|---|---|
| ItemTablesA, RecSizesA | `$FF:CF0E`, `$FF:CF18` | 5 words, 5 B | Record A table per category (bank `$CC`), and its record size. Read-only. |
| ItemTablesB, RecSizesB | `$FF:CF1D`, `$FF:CF27` | 5 words, 4 + 1 B | Record B tables and sizes (the consumables' size is at `$FF:CF2B`). Read-only. |
| Record A | `$CC:06A4`, `08C0`, `0986`, `0A1C`, `0ABC` | by category | Flags, price, equip mask, boost, element bonus. |
| Record B | `$CC:0262`, `047E`, `04E1`, `052C`, `05CC` | by category | The category's own fields. |
| ItemNames | `$CC:0B5E` | 11 B per id | An icon byte (read-only), then 10 glyphs; `$FF` is a blank, `$EF` pads. |
| ItemTargetMode | `$CC:1BB5` | 1 B per consumable | The menu's target mode. |
| ItemBoosts | `$CC:29D7` | 23 words | Stat bits (bit 7 down = the stat order) and the amount (high byte). |
| Char5Attack | `$CC:2D69` | 100 words | Attack formula C's addend, by level. Read-only. |
| DescStrTable | `$CC:2EB1` | 242 words, then strings to `$CC:36F3` | Each id's menu description, in the dialogue codec. |
| StatOrder, StatCaps | `$FF:CF2C`, `$FF:CF33` | 7 B each | The order boost bits name stats in, and each stat's cap. Read-only. |

The weapons' record B span holds 108 records; ids reach the first 90. Its
first 30 bytes (ids $00–$05) lie inside the `$280` bytes that
`Menu_InitNewGameData` copies from `$CC:0000` (the eighth record slot, after
the tech state; see [techs](techs.md)). Editing them also changes what that
copy puts at `$7E:2862`–`$7E:287F`. No reader of those RAM bytes is known.

## Fields and evidence

The claims are in `ct_items.py` (`code_claims`, `data_claims`, `ASM_CLAIMS`
and the run claims). `ct_items.py check --run` checks each one:
- in the ROM's code bytes;
- in ChronoRET's matched source;
- in the ROM's data;
- for the menu tables and stats, by running the ROM's own routines in
  ChronoRET's 65816 interpreter (with the hardware multiply and divide
  registers emulated).

It reports 78 of 78 claims. A field is **verified** when a routine reads it
and the claims pin what it does; **probable** when the reader is known but
its effect is inferred; **unknown** when it is copied but no reader is named.

### Record A

| Byte | Field | Status | Evidence |
|---|---|---|---|
| 0 | `flags` | verified (bits 1-4, 7) | `Menu_BuildItemTables` keeps `AND $1E` in `Menu_ItemInfo0` ($7700). Bit 1: usable from the menu. Bit 3: sorted first. Bit 4: removed by `BankFF_LoadSlotPart`. Bit 2: set on accessories and some gear. Bit 7 (consumables): `BattleFD_AddItemEntry` lists it in battle. Bits 0, 5 and 6 are clear in every item and have no reader; the builder refuses them. |
| 1–2 | `price` | verified | `Menu_ItemInfo1` ($7800). `Menu_ShopCalcPrices`: buy = price × the shop's factor / 256. `Menu_ShopSellDrawRow`: sell = price / 2, rounded up. |
| 3 | `equip` | verified | `Menu_ItemEquipChars` ($7A00). Bit 7 − c is character c (0 = Crono … 6 = Magus); bit 0 is clear. |
| 4 | `boost` | verified | `Menu_ItemInfo4` ($7B00), an ItemBoosts index below 23 (weapons, armour and helmets). |
| 5 | `elementBonus` | verified | `BattleSys_UnkCF69` adds the low nibble to the stat block's resistance byte (+$3F–$42) of each bit 7–4 set: lightning, shadow, water, fire. |

Accessories have bytes 0–3 and consumables bytes 0–2.

### Record B

`BattleSys_UnkCF15` copies each equipped item's record B into the battle
stat block (weapon to +$43, armour to +$48, helmet to +$70, accessory to +$4B),
and `BattleFD_ItemRecOffset` finds them.

| Category | Byte | Field (`stats` key) | Status | Evidence |
|---|---|---|---|---|
| weapon | 0 | `attack` | verified | `Menu_ItemSortKeys` → `Menu_WeaponPower`; in battle, the caster stat of the damage formula. |
| | 1 | `byte1` | unknown | Copied to +$71; no reader named. |
| | 2 | `critical` | probable | +$72 is the chance `BattleSys_HitModChanceMul` rolls 0–99 against; every weapon's value is 0–100. |
| | 3 | `modifier` | verified (range) | +$73 → `BattleSys_CasterUnk73`: a `BattleRom_UnkCC2A05` record (below 57). The records' meaning is not decoded. |
| | 4 | `modifierArg` | verified (read) | +$74, that record's argument. |
| armor, helmet | 0 | `defence` | verified | `Menu_ItemSortKeys` → `Menu_ArmorSum`; summed in battle too. |
| | 1 | `modifier` | verified (range) | A `BattleRom_UnkCC2A05` record (below 57), applied by `BattleFD_UnkB555`. |
| | 2 | `modifierOn` | verified (range) | 0 or 1 in every item. |
| accessory | 0 | `battleFlags` | unknown | Copied to the stat block (+$78); bit 6 acts like a counter flag. The bits are not named. |
| | 1 | `special` | verified (bits 7, 6) | Bit 7: `BattleFD_UnkB363` ORs `specialBits` into the status byte at +Status + `specialArg`. Bit 6: `specialArg` is a boost index (`Menu_BuildItemTables` puts it in Info4). |
| | 2 | `specialArg` | verified | See `special`. |
| | 3 | `specialBits` | verified (read) | The status bits set. The status effects are **not named**: no evidence names them. |
| consumable | 0 | `useKind` | verified | `Menu_UseItem` takes the first set bit: 7 heal, 4 random, 3 full; none means a stat item. |
| | 1 | `restores` | verified | Bit 7 HP, bit 6 MP. |
| | 2 | `amount` | verified | `AND $0F`; `$0F` is full. |
| | 3 | `byte3` | unknown | No reader named. |

`targetMode` (consumables) is `ItemTargetMode`'s byte; `Menu_UseItem`
reduces it with `(+1) AND 3`.

### Names and descriptions

A name is the icon byte (read-only) and 10 glyphs. In a project, a space is the
`$FF` blank and `{gXX}` writes a glyph the codec does not name. The builder
pads with `$EF`; a name has at most 10 glyphs.

Descriptions are dialogue-codec strings ([text codec](text_codec.md)), read by
`Menu_DrawDescText` from `DescStrTable[id]`. The ROM's strings tile
`$CC:3095`–`$CC:36F3`, apart from one byte (`$CC:35E4`) that no pointer
reaches. The rest of the bank, to `$CC:37FF`, is `$FF` and not a confirmed free
region, so it is not used.

### ItemBoosts and the menu's equipment rule

`Menu_CharRecalc` (run for every character by `Menu_RefreshAllChars`)
computes the 11 bytes at record +$36 and lowers HP (+$03) to the new maximum.
`CTEquipStats.compute` and `ct_items.calc_stats` implement it as follows:

1. **Max HP.** The base max HP (+$05), plus half of it with accessory $A1 or a
   quarter with $A0, capped at 999.
2. **Boosts.** Add the boosts of the accessory, helmet, armour and weapon, in that
   order. Each boost is ItemBoosts\[Info4\[id\]\] `AND $FFFE`: bit 7 − i adds the
   amount to stat StatOrder\[i\], wrapping at 255.
3. **Armour and power.** Armour = the helmet's + the armour's sort keys (their
   `defence`); power = the weapon's `attack`.
4. **Caps.** For i = 6 … 0, stat StatOrder\[i\] = (base + boost) `AND $FF`, capped
   at StatCaps\[i\].
5. **Attack** depends on record byte 0 (the character id) `AND 7`:
   - 1, 2: 2 × (hit + power) / 3;
   - 5: (16 × power stat + Char5Attack\[level `AND $7F`\]) / 9, taken 16-bit;
   - otherwise: (5 × power + 12 × power stat) / 9.

   Values above 255 become `$FF`.
6. **Defence** = stamina + armour, at most `$FF`.
7. **Accessory $A8** doubles evade (stat 5) after the caps, wrapping at 255.

The ROM's own `Menu_BuildItemTables` and `Menu_RefreshAllChars` run in the
interpreter on these inputs, and their results equal the rule:
- every character's starting record;
- 168 records with other equipment (every category, and the three special accessories);
- six synthetic table sets patched into the image, with 14 records each.

The synthetic sets are also the Swift vectors
(`Tests/ChronoForgeCoreTests/Resources/items/stat_vectors.json`,
`ct-item-stat-vectors/1`), and `CTItemsTests` checks the Swift twin against
them. A rule without the caps is caught by the ROM.

## Project files

`items/<id>.json`: the import writes one per ROM item, with an id built from the
item id and the name, such as `01_…`. Files without `rom` are the project's own
items and are never built; they load and save as before.

```json
{ "id": "5c_…", "name": "…", "kind": "armor", "price": 0,
  "stats": { "defence": 0, "modifier": 0, "modifierOn": 0 },
  "rom": { "itemId": 92, "icon": 0, "flags": 0, "equip": 0, "boost": 0, "elementBonus": 0 },
  "description": "…" }
```

`stats` holds record B under the keys above. `rom.equip` is absent for
consumables; `rom.boost` and `rom.elementBonus` appear only on weapons, armour
and helmets; `rom.targetMode` only on consumables.

`item_tables.json` (`ct-item-tables/1`) holds `boosts` (23 entries:
`{ "stats": [names in stat order], "amount": n }`, editable) and the read-only
`statOrder`, `statCaps` and `char5Attack`. See [ctproj schema](ctproj_schema.md).

## CLI

```
chronoforge items import <rom.sfc> --project <project.ctproj>
chronoforge items show <project.ctproj | rom.sfc> [<category> | <item id>] [--json]
```

`import` replaces the project's earlier ROM items (its own items are kept),
writes `item_tables.json` and sets `rom.items`. `show` lists one line per item;
for one item it also prints the description.

## Building

With `rom.items`, the builder writes each ROM item's record A, record B, name
bytes 1–10 and target mode, and the ItemBoosts table, all in place over the
base ROM. Unchanged bytes produce no write, so an unmodified import rebuilds
the clean ROM byte for byte. The descriptions are rewritten only when a text
differs from the base's. Then the whole table is repacked within its own span
`$CC:2EB1`–`$CC:36F3`: unchanged strings keep their bytes, identical strings
are shared, and the rest is zero-filled. A table that no longer fits is refused.

The builder refuses:
- an item id twice, or a kind that is not the id's category;
- flags bits 0, 5 or 6, or a price above 65535;
- an equip mask with bit 0;
- a boost past ItemBoosts, or a modifier of 57 or more;
- `modifierOn` other than 0 or 1;
- a boost `specialArg` past ItemBoosts;
- missing or extra `stats` keys, or a value that is not a byte;
- a name longer than 10 glyphs, or with a character that has no glyph;
- an icon different from the base ROM's;
- a `statOrder`, `statCaps` or `char5Attack` different from the base ROM's;
- an ItemBoosts entry 0 that is not empty, or a boost stat name that is unknown or repeated.

Validate (gate 4) runs the same checks per file, and finds duplicate item ids.
With a text profile, it also compiles each description.

## Studio

**Items** opens to the database once the ROM's items are imported:
- a table per category (id, name, price, the main stat, boost or restores, equip or target);
- the selected item's form:
  - the flags, with the evidenced bits named;
  - equip by character, the boost, and the element bonus (four element bits and the resistance added);
  - the category's record B fields; the accessory's status bits and battle flags are shown by bit number;
  - target mode, name and description, with the description's live dictionary analysis
    (bytes, raw bytes, entries used; [text codec](text_codec.md)) when the project has a text profile;
- **Preview**: the selected item in an imported character's slot, through `CTEquipStats`;
- **Stat boosts**: ItemBoosts, a toggle per stat in the stat order and the amount.

**Write items to ROM** sets `rom.items`. The project's own items keep their
plain editor under **Project items**.

## Verification

- `re_workspace/tests/test_items.py` (19 tests): the rule's edge cases, the codec
  on a synthetic image, the write zones and the vectors file without the ROM; the
  claims and the ROM routines with it.
- `CTItemsTests` (10 tests):
  - without the ROM: the vectors, names, the codec on a synthetic image, the
    checks and read-only fields, and the project model and Validator;
  - with the ROM: import then build is identical, edits write only their bytes
    and read back, refusals, and the stat twin on the imported tables.
- `macos_studio/tools/verify_item_build.py` (in `verify_all.sh`):
  1. The CLI import equals the Python decode, and `items show --json` gives the same items from the project and the ROM.
  2. The unmodified import rebuilds the clean ROM.
  3. Eight edits are written where the report says, and `ct_rom_check.py` checks them independently.
  4. The ROM's own `Menu_BuildItemTables` and `Menu_RefreshAllChars` on the built ROM equal the rule.
  5. Eight damaged copies are rejected, and nine bad edits are refused.

## Limitations

- Status effects, the accessory battle flags, weapon byte 1 and the
  `BattleRom_UnkCC2A05` modifier records are not named. Nothing in the evidence
  names them, so the editor shows them as numbers or bits.
- Item ids are fixed (0–$F1): no items are added, and categories cannot change.
- The character build checks starting equipment against the **base ROM's** equip
  masks, not edited ones.
- Shops, treasure, drops and the battle use of consumables beyond the menu's
  fields are not covered.
- No emulator run: the evidence is the ROM's own routines run in an interpreter,
  not a booted game.
