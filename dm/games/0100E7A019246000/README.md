# Library of Ruina (`0100E7A019246000`)

Update 1.0.3 (v262144, display version 1.03) over the cartridge base, SDK 15.3.2, Unity 2021.3.19f1 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`, the `sdk` and `subsdk0` builds of Blasphemous 2.

Status: plays on the Mac at full speed, from a fresh save and from an existing one, through the title menu and into the game; on an earlier, slowed run, also the first Reception to its end and back to the library, with no `[RED]` line. On an iPhone, installed through Xcode, it was reported working with this profile; no log was read from that run. [GitHub issue #739](https://github.com/seedds/nxnative/issues/739) reports the provisional profile on an iPhone 13 Pro Max.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | The NPDM declares 16 MB of system resource, enabling virtual address memory |
| `mem_stack 0x28000000` (640 MB) | `game.tsv` | Unity's thread stacks are placed at random in the stack region; see [Memory](#memory) |
| 5 GB guest block, 4 GB alias region (`mem_alias 0x100000000`), `app_pool 0x40000000` | `game.tsv` | The larger stack region comes out of the alias region. The 1 GB pool keeps StandardAllocator's region at 0.94 GB and leaves the rest of the alias region to Unity's own regions, as in the other Unity profiles |
| `EntryScene` order cut (`main+0x21100e0`, `+0x210f5c0`, code over `LoadingManager.TestStart`) | [`patches.py`](patches.py), `main` build `aeea627d…` | The game's own race between its splash and its load; see [Boot](#boot) |
| `shader_groups /Data/=data` | `game.tsv` | The serialized files and Addressables bundles all live under `Data/` |

## Boot

- **Resolved: stuck on the opening movie's last frame; `Data/level1` never opens and a button does nothing** (issue #739's idle game, reproduced on the Mac). `EntryScene.Update` calls `OnPlayEnd` once `SplashScreen.isFinished`; `OnPlayEnd` makes `_option` (`+0x20`) and `_latestData`. A coroutine calls `GotoTitleOrSelectLanguge` when the Addressables load ends, and that hands `_option` to `SaveManager.LoadOptionData`. Nothing orders the two. Measured with `DM_PROBE`, method names from the metadata: stuck, the load ended at frame 496 and the splash at 526, and `StartMoveSceneCoroutine` was never called; working, the splash ended at 491 and the load at 507. The Switch's slower CPU and storage should always put the load last (a run slowed with `taskpolicy -b` and logging, the load at 44 s, works, and 5 of 5 unslowed boots stuck); a Mac finishes first. The race is in the game's code, so a cut changes it: `GotoTitleOrSelectLanguge` calls `OnPlayEnd` first when `_option` is null, and `OnPlayEnd` returns when `_option` exists, so `Update`'s later call does not replace what `LoadOptionData` read. Nothing is delayed. Checked at full speed, no throttling or extra logging: 5 of 5 boots open `level1`; a fresh save reaches the title menu; an existing save plays on.
- **Not** `OnCompleteInitializePlatform_xboxlive` for the cut's code: it has no direct caller but runs at startup on this platform too. A first cut over it started the scene at 3 s and gave the menu of placeholder outlines that the issue reports when a mod forces the movie past.

## Memory

- **Resolved: an `nn::diag` abort at `sdk+0x12ff04` (Result 0).** The backtrace is `nn::os::detail::ThreadManager::CreateThread` (`sdk+0x12a390`) → `ThreadManagerImplByHorizon::MapAliasStack`, under an IL2CPP thread pool worker (`main+0x303f78`): [Thread stacks placed at random in the stack region](../../../docs/reference/memory.md#thread-stacks-placed-at-random-in-the-stack-region). Issue #739's log ends in it at 32 s on an iPhone 13 Pro Max, with 12 `IL2CPP Threadpool worker` threads alive; the Mac at full speed has 2 at 65 s and 85 MB of stacks, so it never fails there. The pool grows when the machine is slow, and `taskpolicy -b` on the Mac gives the same result as the phone: with the provisional 256 MB stack region 3 of 4 boots abort at this address with 116–133 MB of stacks mapped; with 640 MB, 0 of 4, up to 157 MB of stacks mapped and 57 threads created.
- **Current:** through the first Reception on the Mac the alias region reached +3.01 GB of its 4 GB, with at most 1.52 GB mapped, about 2.5 GB resident and 1.1 GB of Metal allocations. With the hardware pool (3.21 GB) StandardAllocator's region alone ends at +3.21 GB and the opening story already reaches +4.00 GB.

## Files and shaders

- 760 UnityFS bundles (2.77 GB), most of them Addressables under `Data/StreamingAssets/aa/Switch`, in a 5.7 GB merged RomFS. The shader split finds 16,841 shaders and 8,373 pairs. The first boot prebuilds their pipelines, about 40 s on an M1.
- The game's opening movie plays on every start, about 2 minutes on the Mac, and takes a press only once the menu has loaded behind it.

## Mac routes

- A fresh save reaches the story's first scene with `DM_KEYS="142:A,150:A*40/4"`. `Plus` skips a story scene. In the first Invitation: `A` on the `?`, `A` on Canard's scene `I`, `R` to the book panel, `A` to take the Book of Something, `Plus` to send, `A` on the stamp; `Plus` on the stage screen begins the Reception.

## Found on this game

No host or tool change was needed. The boot race is the game's own ([Boot](#boot)). A second case of a general mechanism:

- **Thread stacks placed at random in the stack region:** [the reference entry](../../../docs/reference/memory.md#thread-stacks-placed-at-random-in-the-stack-region); its check as a reproduction on the Mac (`taskpolicy -b`).

## Performance

- **Current:** on an iPhone (A15, docked, MetalFX, `DM_NVN_GPUPROF` and `DM_NVN_PASSDUMP` on, 1080p RGBA16F scene) the bottleneck is GPU attachment bandwidth, not CPU (`@cpu_ms` about 2 ms). Per frame, from `frames.tsv`: High texture quality with 2x MSAA, GPU 17.0 ms median, 302 MB attachment loads and 496 MB stores; with `DM_NVN_MSAA_CAP=1`, GPU 7.8 ms, 172 MB and 301 MB. Both run about 20 passes a frame, ten of them full 1920x1080 RGBA16F load / store passes.
- **Current:** what still costs with MSAA capped: between the large sprite passes the game switches to a depth-only target (one draw, depth cleared first), which ends the colour pass and makes the next one reload and store the whole scene. In one dumped frame that target (serial 1676) is cleared and stored eight times, 7.9 MB each, and never loaded or sampled; about 63 MB of the 269 MB stored. The default path has no look-ahead to turn those stores into DontCare.
- **Current:** `DM_NVN_TBDR=1` makes it worse, not better: 20 passes a frame become 450 or more (load 12.4 GB and store 7.7 GB a frame by the pass ledger, median frame 30 ms, p90 72 ms, 14 to 20 fps in the worst scenes), and `[gpuprof]` shows first start to last end of 50 to 59 ms against 12 to 15 ms of render time. Cause: `ubd_on()` is false in TBDR mode, so none of the roughly 850 inline uniform updates a frame is deferred (`in-pass uniform updates deferred 0`, `passes broken by copies / buffer updates 142186` by frame 1800), and each ends the pass; without `DM_NVN_TBDR` the same run deferred 135,877 and broke none. `DM_NVN_UB_DEFER=1` keeps the deferral on in TBDR mode.
- **Open:** whether `DM_NVN_TBDR=1 DM_NVN_UB_DEFER=1` keeps the picture right and what it saves: the pass count should return to about 20 and `saved by not storing unwritten attachments` and the store look-ahead should then act on them. Textures that did not load with `DM_NVN_TBDR=1` are not explained by the logs (the same eight `pulling library ... not usable` red lines appear with TBDR off); look for a missing attachment or a red ledger line on a run with the deferral on, and check whether LoR's shaders use bindless handles (`NVN_RB_TEXU`) before trusting the look-ahead's read inference.
- **Open:** thermal state 2 (serious) was reached on the capped run at the start; both frame-rate and GPU time need to be read against `thermal` in the `[nvn] on-screen` lines. Capture other scenes with `scripts/perf.py env full` and read them with `scripts/perf.py report` ([CPU time by game function](../../../docs/development.md#cpu-time-by-game-function)).

## Open

- On an iPhone: a Reception and memory, on a 6 GB phone as in issue #739.
- The host's crash report can wedge: one aborted run with `DM_THR=1 DM_SVC=1` never exited, every thread, the aborting one included, blocked in `flockfile` on the log, and the `perl alarm` of `boot.sh` did not end it either (`CRASH sig=14` is reported through the same log). Who held the lock was not found.
- The first boot with `DM_WATCH_STALL=40`, which fired during the pipeline prebuild, printed nothing more for 190 s until its alarm; the next boot, without that stall time reached, ran normally. Not looked into.
- Later Receptions and floors: memory against the 4 GB alias region (`DM_REGIONS`, the `[mem]` lines).
