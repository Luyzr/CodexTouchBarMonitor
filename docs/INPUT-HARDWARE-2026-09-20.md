# Background input validation — 2026-09-20

The user resumed the paused input test and requested a fresh reproduction.

## Reproduced and corrected
An AppKit regression fixture retained an option button from question 1, clicked it to
advance to question 2, and clicked the retained button again. Before the correction,
the second invocation answered question 2 and unexpectedly completed the request.
The regression assertion failed on the original implementation.

All rendered decision controls now capture their interaction identity, including the
request, question, capture state and navigation state. Clearing or accepting a session
invalidates old controls. Reusing an old button after a transition is ignored.

The compact scroll position resets when changing its document, so previous horizontal
scrolling cannot leave a newly shown input page offset. Actual 480-point AppKit layout
checks confirm Send and Cancel lie within the visible horizontal bounds.

## Verification
build host: 78 core + 52 integration + 20 AppKit assertions pass (150 total).
Release build and signature verification pass. No source development or build ran locally.
Archive SHA256: 9671959f7fd0ec612fb317ebbc420c698ede7a8a3a90008dc065a17dd9939b0a.

A focused --demo --background-demo --input-demo scene contains only one fixture input
request. Network and quota stay live; no real decision response is sent.
Physical display, real Chinese IME composition, and focus return remain pending.

## Physical blank input investigation
The user reported the input page entirely blank after Other. Opt-in diagnostics on
hardware show capture=true, panel key=true, Safari still frontmost, and bar/item
isVisible=true. The document is 480x30; the input stack is 444x20 and Send/Cancel
have nonzero frames inside the visible clip. A later switch to Codex cancels capture
as expected. This does not establish a width overflow or a hidden modal bar.

A candidate correction replaces the controls item root scroll view on page transitions
instead of mutating its existing document in the live Touch Bar host. It preserves
the modal bar and persistent tray, without dismissing/re-presenting the bar.
151 assertions and the release build passed on build host. Physical verification of
this candidate remains pending; Chinese IME is not yet accepted.
Candidate archive SHA256: 67533ecb2caa88957c5899a6b6ae44de371a18a98a16d7e585e403e67131accd.
Diagnostics contain only visibility, geometry and focus metadata, no input contents.

The root replacement candidate did NOT resolve the physical blank page and was reverted.
The next candidate associates the existing task Touch Bar with the nonactivating input
panel and text responder before it becomes key. Text completion is disabled for the
transparent editor; IME composition remains native. All 150 checks pass on build host.
Archive SHA256: 8dbd147a641ff299a071acb231ec8c2e08a8cf89822773931915f58390f3552c.
This candidate requires physical display verification; cause is still a hypothesis.

## Direct Touch Bar capture
The user reported the focus-association candidate still blank. Native screencapture -b
on the test Mac confirms the entire dynamic area is black, including the return item,
while the persistent tray remains. AppKit isVisible remains true despite this.

A temporary demo-only staged probe delayed keyboard focus by six seconds and then
re-presented the modal bar six seconds later. Captured stage-10 shows the input cursor,
Send and Cancel before keyboard focus. Stage-12 shows the area black after focus.
Stage-16 remains black after dismiss/re-present. This isolates the trigger to keyboard
focus acquisition rather than input layout or scroll document refresh. The probe code
has been removed; it is not a product interaction.

Next candidate transfers the bar from system-modal presentation to the native input
panel/responder while input owns keyboard focus. Normal modal presentation is suppressed
during input; ending capture restores it via the existing render path. Hardware pending.
150 checks pass. Archive a348c03f6a8efeac06610051f22dd66386e979f4fb5656b95d744cf4fcf92e40.


## User decision: defer Touch Bar text input
The native-panel ownership candidate also remained blank on physical hardware.
The user explicitly requested that text input be deferred. The ownership experiments
were removed. The free-text/secret reply entry now opens the corresponding Codex task;
it does not capture keyboard focus or send a response. Structured choices and approval
buttons remain on the Touch Bar. Internal text-input scaffolding is retained for future
work, but has no user-facing entry and is not hardware-accepted.
The local test app is restored to live mode, with no demo fixtures.
Final deferred-input build: 78 core + 52 integration + 23 UI assertions (153 total).
The UI regression confirms free-text routing leaves keyboard capture inactive and the
request pending. Build and code signature verified; packaged on build host only.
Archive SHA256: fceef2e7d89d3415540214f50dc19a27effebc09abad5c66905000079f12b76e.
