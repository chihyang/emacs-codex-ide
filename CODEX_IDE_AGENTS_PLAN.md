# Codex IDE Agents: Next Implementation Plan

## Status

This document records the agreed plan for the next `codex-ide-agents`
features. Implementation is proceeding in risk order: rename, local close,
create, automatic updates, then robust deletion. Session rename and local
close, session creation, automatic updates, and robust deletion are complete.

The first implementation milestone will add:

1. automatic updates,
2. creation of a session in a selected agent's directory,
3. session renaming,
4. local session closing, and
5. robust, app-server-backed deletion.

Archive and unarchive actions were added after this milestone. Remote
app-server support and broader replacement of `codex-ide-status` remain
deferred.

The action workflow now combines mnemonic and generic marks. `m` and `%`
produce `>`; `d`, `k`, `a`, and `r` produce `D`, `K`, `A`, and `R`. Capital
`D`, `K`, `A`, or `R` performs its action on every generic `>` mark, or on the
current row when no generic marks exist. Mnemonic marks do not affect that
selection.
Rename moved to `e`, automatic-refresh toggling moved to `t`, and `%` gained
Title, Status, Running In, Updated, and Directory regexp marking commands.
Lowercase `x` dispatches a mixed batch of mnemonic marks while ignoring and
preserving generic `>` marks.

## User-facing behavior

### Automatic updates

The agents buffer should stay current without requiring repeated manual `g`
refreshes.

- React to app-server lifecycle notifications when they are available.
- Use a low-frequency Emacs timer as a reconciliation fallback for changes
  made by other clients that do not produce a notification visible to this
  Emacs process.
- Refresh only while an agents buffer is live and visible.
- Coalesce rapid events rather than issuing one list request per event.
- Do not refresh while a confirmation or minibuffer interaction initiated by
  the agents buffer is active.
- Preserve the selected session, window position, sort order, and close or
  deletion marks across refreshes whenever the corresponding rows still exist.
- Keep the standard Emacs `g` revert binding as the manual refresh command.
- Provide `A` to toggle both event-driven and timer-driven refresh for the
  current agents buffer, with a mode-line indication while disabled.
- Background refresh failures should not repeatedly pop up an error buffer;
  the buffer should retain its last good contents and make the failure visible
  unobtrusively. A manual refresh may show the full operation error.

Add a customization option such as
`codex-ide-agents-auto-refresh-interval`. A default of five seconds is a
reasonable starting point. `nil` or a non-positive value should disable timer
polling without disabling event-driven refreshes.

### Create a session with `c`

On an agent row, `c` should create a new Codex session whose working directory
is that row's directory.

- Read the directory from the selected row rather than from whichever Emacs
  buffer happens to be current.
- Verify that the directory still exists and is accessible before creating the
  session.
- Bind `default-directory` to it and reuse the existing `codex-ide` new-session
  lifecycle instead of duplicating process or transcript setup.
- Display and select the new session using the normal session-window policy.
- If the row does not have a usable directory, do not partially create a
  session; show actionable guidance instead.

`c` without a session row should report that a row must be selected. Choosing
an arbitrary fallback directory would make the command's behavior ambiguous.

### Rename a session with `r`

On an agent row, `r` should prompt for a new session name and send the official
app-server `thread/name/set` request.

- Seed the prompt with the current explicit name when one exists.
- For the first version, require a non-empty name. Clearing a name can be added
  later if the protocol and desired UI semantics are confirmed.
- Update the row after the server confirms success; do not make an optimistic
  change that could become stale on failure.
- React to `thread/name/updated` notifications so renames performed by another
  client also appear.
- Preserve point on the renamed session after the refresh.
- Show the server error and a short recovery tip if renaming fails.

### Close a local session with `k` or `K`

Closing is a local Emacs operation, distinct from deleting a Codex thread. It
should kill the session buffer and clear the associated in-memory process and
session state, while leaving the app-server thread available for later resume.

- `k` marks the current row as `killing` for deferred execution.
- `K` confirms, then closes all generic marks or, when none exist, the session
  on the current row.
- `x` executes all actionable pending marks, dispatching each row according to
  its mnemonic marker and leaving generic marks unchanged.
- `u` removes either kind of mark from the current row.
- `U` clears all close and deletion marks.

Only a session running within the current Emacs instance can be closed this
way. A stored session, a session owned by another client, or a row without a
live local session buffer should remain unchanged and display a clear message.

The mark column should distinguish the two pending operations. Keep `D` for
deletion and use `K` for closing. Applying `d` or `k` to an already marked row
should replace the previous mark so that every row has exactly one pending
operation.

Before closing, confirm if the session has an active turn, pending approval,
elicitation, or another state for which teardown could discard an interaction.
For a batch `x`, the confirmation should summarize close and delete counts in
one prompt. Declining must perform neither operation.

Closing should reuse the existing session teardown path rather than manually
clearing individual variables. It should terminate only resources owned by
that session, remove the session from local registries, kill its session
buffer, and then refresh the agents list. Closing must not send
`thread/delete`, remove rollout files, or otherwise make the thread
unresumable.

If local teardown fails, keep or restore the close mark where possible and
report the failure in `*Codex Agents Operation*`. Other marked operations may
continue, with all failures summarized at the end.

### Robust deletion

Keep the existing Dired-style controls:

- `d` marks a row for deletion.
- `u` removes the current row's close or deletion mark.
- `U` clears all close and deletion marks.
- `x` confirms once, then performs each mnemonic-marked operation.
- `D` confirms, then deletes all generic marks or, when none exist, the
  session on the current row.

Change the deletion implementation to use the official app-server
`thread/delete` request rather than deleting rollout files directly.

- Never send a delete request before confirmation.
- Do not tear down an Emacs session buffer or alter local bookkeeping until
  the server confirms that deletion succeeded.
- If the server rejects deletion, preserve the row, session buffer, transcript,
  and deletion mark so the user can inspect the failure and retry.
- Report failures in a reusable `*Codex Agents Operation*` buffer, including
  the session ID, server error, and a concise recovery tip.
- When deleting several marked sessions, continue after an individual failure,
  remove only successfully deleted rows, and summarize all failures together.
- Handle `thread/deleted` notifications so deletion by another client removes
  stale rows on the next coalesced refresh.
- Do not silently fall back to filesystem deletion when `thread/delete` is
  unavailable. Explain that the app server must be upgraded or that the
  session must be managed by a compatible server.

"Robust deletion" therefore means that the app server remains the authority,
failure is non-destructive, partial batch success is represented accurately,
and UI state is reconciled after every result.

## Internal design

### Protocol layer

Add focused request helpers in `codex-ide-protocol.el` for:

- `thread/name/set`, and
- `thread/delete`.

Normalize relevant lifecycle notifications into the existing session-event
mechanism:

- `thread/name/updated`,
- `thread/deleted`,
- `thread/archived`, and
- `thread/unarchived`.

Archive notifications are included in the normalization work so later archive
commands can reuse it, but archive UI actions are not part of this milestone.
Notification handling must be safe for query-only/shared-daemon connections
that do not own a transcript buffer.

### Agents buffer controller

Keep list presentation in `codex-ide-agents.el`, but separate these concerns
into small helpers:

- capture and restore buffer state around a refresh,
- schedule and cancel the buffer-local timer,
- coalesce event-driven refresh requests,
- determine whether the buffer is visible and safe to refresh,
- resolve the selected row's ID and directory,
- run create, rename, close, and delete operations, and
- collect and display operation failures.

Use the existing `codex-ide-session-event-hook` pattern already used by status
mode. Timer and hook registration must be buffer-local and must be removed when
the buffer is killed or its mode changes.

Manual and automatic refreshes should share the same state-preserving list
update path. They should differ only in error presentation and whether the
request was explicitly initiated by the user.

### Session lifecycle and deletion ownership

Creation should reuse the existing public new-session entry point with a
dynamically bound `default-directory`.

Closing should reuse the central local session teardown primitive. If the
current teardown implementation combines local shutdown with persistent thread
deletion, split those responsibilities before wiring `k` and `K`; the close
path must affect local Emacs state only.

Protocol-backed deletion should be centralized so other interfaces, especially
`codex-ide-status`, do not retain a separate direct-file deletion path. Preserve
compatible callers where practical, but make the server-confirmed operation the
single source of deletion behavior.

### Error presentation

Generalize the current deletion failure presentation into an operation failure
renderer shared by close, delete, rename, create, and explicit refresh
operations.
Each entry should contain:

- the operation,
- session ID and display name when available,
- the normalized server or local error, and
- a short suggested next step.

Expected operational failures should not enter the debugger. Unexpected Lisp
errors should still retain enough diagnostic detail in the existing log
facilities.

## Implementation sequence

1. Add protocol helpers and lifecycle notification normalization.
2. Convert the shared deletion path to server-confirmed `thread/delete` and
   update the existing `D`/`x` workflow.
3. Separate and verify the local teardown primitive, then add `k`/`K` and
   mixed-operation `x` handling.
4. Add `c` using the selected row's directory and the existing new-session
   lifecycle.
5. Add `r` using `thread/name/set`.
6. Refactor refresh into a state-preserving path used by both manual and
   automatic updates.
7. Add event-driven refresh scheduling and the visible-buffer timer fallback.
8. Update command help, README documentation, and the progress document.
9. Run focused tests, the full non-integration suite, byte compilation, and
   live reload validation.

This order establishes authoritative mutation behavior before adding automatic
reconciliation, which makes refresh behavior easier to test and reason about.

## Test plan

Add or update ERT coverage for the following behavior.

### Protocol tests

- Rename and delete requests use the correct methods and payloads.
- Success and JSON-RPC error responses are normalized correctly.
- Lifecycle notifications emit the expected session events.
- Notifications are safe without a transcript buffer.

### Agents buffer tests

- `c` uses the selected row's directory and rejects missing directories.
- `r` seeds the prompt, rejects an empty name, refreshes after success, and
  preserves the old row after failure.
- `d`, `k`, `u`, `U`, `x`, `D`, and `K` use the documented mark and
  confirmation semantics.
- `d` and `k` replace one another's mark rather than stacking operations on a
  row.
- `K` closes a live local session but does not delete its app-server thread or
  rollout data.
- `K` rejects rows that are not backed by a live session in this Emacs
  instance.
- Declining `K` confirmation leaves the local session unchanged.
- A mixed `x` confirmation reports separate close and delete counts and
  dispatches each marked row to the correct operation.
- A close failure retains the row and mark while allowing other marked
  operations to proceed.
- No delete request occurs when confirmation is declined.
- Successful deletion removes only the confirmed session.
- Failed deletion preserves the session, its mark, and its local buffer.
- A mixed-success batch reports failures and retains only failed marks.
- Manual refresh preserves point, sort order, window position, and marks.
- Event bursts schedule one coalesced refresh.
- Timer refresh runs only for a visible live agents buffer.
- Timer and hooks are cleaned up when the buffer is killed.
- Automatic refresh is deferred during create, rename, close, and delete
  interactions.
- Background failures retain the last good list without repeatedly opening the
  operation buffer.

### Broader regression tests

- Existing session creation remains unchanged outside the agents buffer.
- Closing one session does not disturb other local session buffers or state.
- A closed thread remains resumable from the app server.
- Status-mode deletion uses the same server-backed behavior.
- Detail view and parent/subagent navigation continue to work after refresh.
- `/agents` and the transient command still open the agents interface.

Do not run human-driven integration tests as part of automated validation.
After the automated checks, manually exercise the five features against a live
shared daemon before considering the milestone complete.

## Acceptance criteria

The milestone is complete when:

- an open, visible agents buffer converges on external daemon changes without
  manual intervention;
- `c` reliably creates a normal Codex session in the selected row's directory;
- `r` renames the selected session through the app server and shows external
  renames;
- `k`, `K`, and `x` close only live sessions owned by this Emacs instance,
  clear their local state, and leave their threads resumable;
- `D` and `x` use confirmed, server-authoritative deletion and never remove
  local state after a failed request;
- partial batch deletion is accurately represented and recoverable;
- interactive state is preserved across automatic refreshes;
- all new behavior has focused ERT coverage;
- the full non-integration suite and byte compilation pass apart from any
  separately documented pre-existing failure;
- modified runtime files reload successfully; and
- no generated `.elc` artifacts remain.

## Later work

- A deliberate UI for clearing an explicit session name.
- Remote app-server support.
- Final decision on replacing or redirecting `codex-ide-status`.
- Additional filtering or grouping if automatic updates make very large agent
  lists difficult to navigate.
