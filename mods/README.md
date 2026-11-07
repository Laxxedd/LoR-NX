# Mods

Each folder is one mod. Every mod in this folder is built into every IPA, and each one is **off until the player turns it on**: the settings screen has a *Mods* section with a *Browse mods* button, which opens a page with one switch per mod, grouped by category (it sets the mod's env switch, e.g. `DM_MOD_SPEEDDICE=1`; `Documents/env.txt` wins over the screen). A change takes effect at the next start.

```
mods/<id>/
  mod.json   id, title, launcher (env, label, note of its switch, category: Performance, Quality of Life, Content, Miscellaneous (default) or Cheats; the group on the launcher's mods page; forced: `<DM_VAR>=<value>`, a launcher setting that turns the switch on and locks it on while it has that value, as Touchscreen Mode does for touch-ui), gates (names), obs (gate rows per build of main), host (C file), romfs (folder)
  host.c     callbacks for the gates (call dm_mod_gate_run from dm/host/hle_modcall.c to run on the guest stack); attaches them from a constructor with gate_obs_set(), and returns from each callback while its env switch is not 1 (read at the first gate hit: the launcher's choices are not in the environment yet when constructors run)
  romfs/     files for the RomFS overlay (Data/StreamingAssets/... as in the game's RomFS); packed into the app, nothing to copy to the device
```

How it works: `scripts/apply_mods.py` numbers the gates (32-63), copies `host.c` into `dm/host/` (built by wildcard), writes `launcher_mods.json` (the Mods switches; `dm/games/settings.py` adds them to the app's `launcher.json` when `DM_MODS_SETTINGS` names the file, for the iOS and Mac builds alike), writes the gate rows the rewriter (`dm/tools/patch_nso.py`, `DM_MODS_PATCHES`) puts into the game's `main`, and copies each mod's romfs folder to `romfs/<id>/`, which `build_ipa.sh` packs into the app as `<App>/modromfs/<id>/`. A gate fires only in a build whose ID has rows in `mod.json`.

`dm/games/settings.py` is the one repo file this framework edits for the launcher (a `Mods` section and `mod_rows`).

Add a mod: copy `speed-dice/`, change the id, gates and `host.c`.

## Input

A mod reads keys with `dm_mod_keys()` (`dm/host/dm_input.h`): the bits of `dm_cheats_keys()` (every controller, the touch gamepad and the keyboard) and, in Touchscreen Mode, `DM_MOD_KEY_ALT` while the Alt key of the touchscreen keyboard is held. The mods' **special button** is `dm_mod_special()`: R3 (`DM_BTN_RS`), or Alt in Touchscreen Mode, where there is no R3. A mod that opens on the special button tests `dm_mod_keys() & dm_mod_special()` and describes it in its launcher note as "R3 or ALT" (Targetable Mass Attacks, Re-Extraction).

## Exefs patch mods

A mod with an `exefs` entry in its `mod.json` is made of Atmosphère exefs patches, the `.ips` / IPS32 and `.pchtxt` files as their author distributes them (Library-of-Ruina-NX-Mods), and needs no `host.c`:

```
mods/<id>/
  mod.json   id, title, launcher (env, label, note), exefs (the folder of the patch files)
  expect     optional: {build ID: {text offset: the game's original word}} for every patched word; apply_mods.py checks it covers the patches and the rewriter stops when the game's word differs (a wrong offset or build)
  exefs/     <NSO build ID>.ips (64 hex digits, the name Atmosphère uses) and / or *.pchtxt (@nsobid- line, hex patches, offset_shift as the file sets it)
```

Every word a patch changes becomes a switchable patch: `scripts/apply_mods.py` lists the words in `patches.json` (`SWITCH`, with the text offset, the mod's switch number and the patched word), and the rewriter (`dm/tools/patch_nso.py`, "Switchable patches"; stubs in `dm/tools/nso_switch.py`) replaces the instruction with a branch to a stub that runs the patched word when the mod's switch byte is 1 and the game's own word otherwise. `dm/host/hle_modsw.c` writes the bytes when the game starts from the mods' env switches (the Mods section of the launcher, `Documents/env.txt` wins), so with every switch off the game runs as it does without the mods. The choice is made at run time because the iPhone cannot write to code pages. A change takes effect at the next start, as for the other mods.

Offsets: an `.ips` file counts from the start of the NSO file (Atmosphère takes the 0x100-byte header off), a `.pchtxt` counts as `offset_shift` says; both give the text offset the rewriter uses (the same as the `obs` rows of the other mods). A patch must cover whole instructions at 4-byte aligned offsets, and only the build named in its file is patched (Library of Ruina 1.0.3, build ID `aeea627d...`). The rewrite log lists each site with the instruction it replaces (`switch N at ...`), and `main.switch.tsv` beside the rewritten modules has the same list: check a new patch's sites there. A site that is already a rewrite site (an x18, tpidr or svc instruction, a lock acquire) or an instruction the stub cannot move (`ldr` literal) stops the rewrite with a message.

## RomFS files of a mod

A mod's `romfs/` folder is built into the app (`<App>/modromfs/<id>/`, as the other game files of the build are) and `main.m` hands the host its location as `DM_MODS_ROMFS_DIR`. When the mod's switch is on, `dm/host/hle_fs.c` adds `<App>/modromfs/<id>` to the RomFS overlay when the game mounts `rom`, so the player copies no files and writes no `DM_ROMFS_OVERLAY` line. A `DM_ROMFS_OVERLAY` that is set still works and is looked in first (a relative folder such as `.` is the app's `Documents`), so a file there replaces the mod's own. With the switch off the folder is not used.
