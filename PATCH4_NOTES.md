# KYZU patch 4 — rebased onto latest uploaded tree

This patch was applied to the repository uploaded as `kyzu(1).zip` on 2026-09-11.

## Changes

1. Added `game.cmd.list_units` / `game.event.unit_list`.
   - Returns the authoritative current units so a newly connected viewer does not need to reconstruct them from missed events.
   - Includes unit id, owner, unit type, longitude, latitude, HP and level.

2. Moved `game.event.position` stdout I/O outside `UnitsLock` in `AdvanceUnits`.
   - The JSON event is built while the unit is protected, then the lock is released before `SendLine` flushes stdout.
   - This prevents a slow downstream consumer from holding the main unit-state lock during network/process I/O.

3. Updated `KYZU_VDRX_API.md` with the new snapshot command/event.

## Compatibility

The existing event format and command envelope are unchanged. This is additive apart from the lock-scope improvement.

## Verification

The source was checked against the uploaded tree and the generated diffs contain only the changes above. I cannot run Free Pascal compilation in this environment because FPC/Lazarus is not installed here; compile with the same toolchain you used for the previous successful patches.
