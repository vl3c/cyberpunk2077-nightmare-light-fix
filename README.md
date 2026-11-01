# Nightmare Light Fix for Cyberpunk 2077 2.5

Brings back the red "nightmare" lighting in V's apartment the first time Johnny shows up (start of Act 2, *Playing for Time*). The vanilla game lost this lighting at some point, and CDPR never fixed it. [Deceptious Bug Fixes](https://www.nexusmods.com/cyberpunk2077/mods/18318) restored it, but that part stopped working on game 2.5.

This repository builds a standalone, light-only version of Deceptious's nightmare fix for 2.5, and documents what 2.5 changed. Other modders can use the notes to update their own world sectors.

**This repository does not include Deceptious's files.** `build.ps1` builds the mod from your own copy of Deceptious Bug Fixes 1.4.3. The built archive contains Deceptious's quest phase, scene and streaming block plus a converted copy of their sector, so it is for your own use: don't upload or share it without Deceptious's permission.

## What broke on 2.5

The fix uses four files: a red-light world sector, the streaming block that loads it, the q101 quest phase that starts it, and the Johnny scene that ends it. It also has a script that tags 56 apartment lamps so the quest phase can switch them off. Four things stopped working on 2.5:

1. **Node setup layout (sector version 62 to 68).** The sector's custom data starts with an int32 version right after the RTTI properties. Game 2.5 uses version 68 and a new 144-byte `worldCompiledNodeInstanceSetupInfo` layout:
   - The u64 bitfield moved to offset 112 (node index 19 bits, then flags, priority and ToD mask).
   - The two distance floats moved to offsets 120 and 124.
   - New fields: `instanceIndex` (u32 at 128, -1) and `dataGroup` (u8 at 132).

   The game reads a version 62 sector with the 2.5 offsets, so every node index and distance comes out wrong and nothing shows. Converting the records but leaving the version at 62 crashes the game.
2. **`nodeRefs` must be sorted by hash.** In 2.5 sectors this list is sorted ascending by NodeRef hash: FNV-1a 64 of the path, skipping every `#`. The fix's sector lists its 57 refs (the 56 lamps plus one of its own) in authoring order, so the game can't find most of them and the lamps never switch off.
3. **`variantIndices` must match `numNodeRanges`.** The streaming block describes the sector with one node range and no variants, but the sector had `variantIndices = [0, 1]`. That made range 0 a single placeholder probe and put every real node in range 1, which the block never declares. Game 2.5 never builds range 1, so none of the red lights appear. In the 2.5 world block, every descriptor without variants has `numNodeRanges = 1`, and sectors carry exactly `numNodeRanges` variant indices. This fix uses `[0]`.
4. **Script node counts.** The original script found the lamps by fixed index and ran only for four pre-2.5 node counts. In 2.5 the apartment sector has 837 setups (853 with Phantom Liberty), so the script did nothing. This version finds each lamp by world position and checks that it is a static light.

## Look changes

The original sector also has green and teal lights, and some extremely bright bounce lights at the bathroom door. On 2.5 these looked odd, so `tools/tune-nightmare.py` adjusts the set before conversion (counts are for Deceptious Bug Fixes 1.4.3):

- Drops the green and teal lights (any light with more green than red; 13 of them). All-red looks spookier.
- Sets `scaleVolFog = 0` on the lights that don't set it. The engine default is 100, which lights up the fog and rain as glowing blobs. The other lights in the sector, and all the vanilla apartment lamps, already use 0.
- Cuts the bathroom-door bounce lights of intensity 1000 or more (three of them) and the two spots above the bed to a quarter of their intensity.

## Requirements

- Cyberpunk 2077 2.5 (tested with Phantom Liberty).
- [RED4ext](https://www.nexusmods.com/cyberpunk2077/mods/2380), [ArchiveXL](https://www.nexusmods.com/cyberpunk2077/mods/4198), [Codeware](https://www.nexusmods.com/cyberpunk2077/mods/7780), [redscript](https://www.nexusmods.com/cyberpunk2077/mods/1511). [Cyber Engine Tweaks](https://www.nexusmods.com/cyberpunk2077/mods/107) is optional (the script also logs to its game log).
- To build: 64-bit Windows PowerShell, Python 3, and the Deceptious Bug Fixes 1.4.3 archive (`#DeceptiousBugFixes.archive`). The game's own Oodle DLL is used to read it. If the red-light sector differs from the 1.4.3 one, the build stops unless you pass `-Force`, because the tuning rules were written for that exact file.

Don't run it together with the full Deceptious Bug Fixes, which contains the same nightmare files.

## Build and install

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 -DbfArchive "<path>\#DeceptiousBugFixes.archive" [-Game "<Cyberpunk 2077 folder>"] [-Python "<command>"]
```

- Keep the quotes around the archive path: unquoted, an argument starting with `#` is a PowerShell comment.
- `-Game` defaults to the Epic Games folder (`C:\Program Files\Epic Games\Cyberpunk2077`). Steam and GOG users pass their game folder.
- Python is found through the `py` launcher, or `python` if there is no launcher. Use `-Python` with an executable name or full path to pick another one.
- Don't end a quoted path with a backslash (`"...\Cyberpunk2077\"`): Windows PowerShell reads `\"` as an escaped quote and mixes up the arguments after it.

Then copy `build\NightmareLightFix\archive` and `build\NightmareLightFix\r6` into the game folder.

To test, load a save from before V wakes up in the apartment at the start of Act 2, for example when V enters the apartment in the wheelchair. The script logs to `r6\logs` and the CET game log under the `NightmareLightFix` tag.

To uninstall, delete `archive\pc\mod\NightmareLightFix.archive`, `archive\pc\mod\NightmareLightFix.archive.xl` and `r6\scripts\NightmareLightFix\`.

## Files

| Path | What it is |
| --- | --- |
| `build.ps1` | Extracts the red-light sector from Deceptious's archive, tunes and converts it, and writes the mod to `build\` |
| `tools/convert-sector-25.py` | Converts a version 62 sector to 2.5 (record layout, version, nodeRefs order, variant ranges) and rebuilds the archive |
| `tools/tune-nightmare.py` | The look changes listed above |
| `tools/extract-rdar.ps1` | Small read-only `.archive` extractor that uses the game's Oodle DLL |
| `mod/` | The script (an independent rewrite that keeps Deceptious's lamp ref names for compatibility) and the ArchiveXL file |

## Credits

The nightmare fix, its red-light sector, quest phase and scene are by **Deceptious** ([Deceptious Bug Fixes](https://www.nexusmods.com/cyberpunk2077/mods/18318)). This repository only contains tools, notes and a rewritten script, and is meant to help update that fix for 2.5.

The code in this repository is MIT licensed (see `LICENSE`). Cyberpunk 2077 is a trademark of CD PROJEKT S.A.; this project is not affiliated with CD PROJEKT RED or Deceptious.
