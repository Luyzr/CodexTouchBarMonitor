# Desktop IPC and background dynamic area

## User-approved interaction
A physical placement-0 probe left the persistent tile visible while replacing Safari controls.
The user approved temporary app-area switching, with one-tap return to native controls.
`‹ App` dismisses the dynamic area without activating Monitor or Codex. New decisions can
reopen it; ordinary progress updates do not undo a user's dismissal. CTB → Show task controls
explicitly reopens it. The sole persistent tile still opens Codex when tapped.

## Actual Desktop connection
Prefer the existing user-owned ~/.codex/ipc/ipc.sock. Initialize a monitor client, then
follow thread streams using versioned desktop broadcasts. Frames are UInt32LE length + JSON.
Version 11 snapshots and Immer path-array patches are reconciled atomically with revision checks.
A revision gap clears actionable requests and asks the owner for a fresh snapshot.
The initial local candidate catalog comes from an independent app-server thread/list read;
only active snapshots or previously monitored executions enter the dashboard. No history turn
is resumed. The local catalog is paginated to completion so older active tasks are not excluded by a 100-thread limit.
Remote-host discovery still needs expansion and acceptance.

Responses target the observed owner, thread and request, require the same connection and turn,
mark the request sent before writing, and never retry ambiguous delivery automatically.
No source archive, snapshot, prompt or input text is persisted by the production adapter.

## Verified in this session
- The compiled runtime probe received a real local task snapshot and revisioned events.
- Packaged runtime: one active task, zero decisions, live network and weekly quota.
- 78 core assertions include revision gaps, atomic invalid patches and request insertion/removal.
- 49 integration assertions include fragmented IPC frames and exact-target Unicode responses.
- 17 AppKit flow assertions cover decisions, input, secure input and native composition.
- All builds/tests execute on build host. The external project volume cannot host Unix sockets;
  the fixture uses a disposable build host /private/tmp socket and removes it afterward.

Pending physical acceptance: background automatic display and return; demo approval; real
Chinese IME candidate selection with Safari still foreground; Send/Cancel focus return.
A live pending server request has not been approved/rejected as part of testing.

## Physical feedback and follow-up
The user confirmed automatic display in Safari, persistent live values, and return to native controls.
They then requested a direct reopening gesture, reported vertically low Open task controls, and
asked for comparison with Pock. After correction, the user confirmed all three were OK:
- single tap opens Codex; double tap opens task controls without opening Codex first;
- task buttons are vertically centered;
- the tested switching flicker is acceptable.

Pock reference: https://github.com/pock/pock/blob/main/Pock/UI/TouchBar/PockTouchBarController/PockTouchBarController.swift
Its withControlStrip mode uses placement 0; it guards repeated presentation with isVisible and
caches touch items. We retain cached items/scroll containers and materialize layout before presenting.
We do not modify global Touch Bar preferences, restart ControlStrip, or use full-width placement 1.

The background demo keeps live network/quota while routing only fixture decisions locally.
Real decisions remain disconnected in this mode. The current automated total is 147 assertions
(78 core + 52 integration + 17 AppKit), including single/double-tap arbitration.
