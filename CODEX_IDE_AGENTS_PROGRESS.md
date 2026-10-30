# `codex-ide-agents` Implementation Progress

This document records the agreed design, implementation state, validation
results, and remaining work for the global Codex agent-session browser.

## Goal

Add an Emacs-native equivalent of `codex agents` named
`codex-ide-agents`. It should show sessions known to the shared local Codex
daemon across every working directory, rather than limiting results to the
current project as `codex-ide-status` does.

The primary browser remains a flat `tabulated-list-mode` interface. A separate
detail buffer shows complete session metadata and navigable parent/subagent
relationships. Replacing `codex-ide-status` remains deferred.

## Agreed user interface

The buffer is named `*Codex Agents*` and contains one row per session, without
grouping rows by directory.

| Column | Meaning |
| --- | --- |
| `Session` | Explicit session name, falling back to its preview or `Untitled`, displayed within a 15-character column. |
| `Status` | Normalized daemon or live Emacs status, such as `Running`, `Idle`, `Stored`, or `Archived`. |
| `Running In` | `Emacs` when the session has a live buffer in this Emacs, `External` when an active session has no local buffer, and blank for inactive sessions without a local buffer. |
| `Updated` | Human-readable last-update time, sortable by the underlying timestamp. |
| `Directory` | Full working directory, abbreviated with `~` where applicable. |

Key behavior:

- `RET` displays an existing Emacs session buffer or resumes the stored thread
  in another window when possible, preserving the agents list and selecting
  the session window.
- `M-RET` and `C-M-j` perform the same action in another window through the
  shared session-list bindings.
- The list automatically refreshes after local session events and reconciles
  external daemon activity every five seconds while visible. `g` still
  performs an immediate manual refresh.
- Automatic and manual refreshes preserve the selected session, sort order,
  scroll position, and marks for rows that still exist.
- `codex-ide-agents-auto-refresh-interval` customizes fallback polling; nil or
  a non-positive value disables polling without disabling event refreshes.
- `t` toggles all automatic updates for the current agents buffer while
  retaining manual `g`; the mode line reports when automatic refresh is off.
- Background failures retain the last good rows and show a mode-line warning
  instead of repeatedly opening an error buffer.
- Refresh state is captured per visible window, so a background refresh keeps
  each window's actual cursor row even when the agents buffer is not selected.
  If a row disappears, point falls back to the same line number when possible.
- `i` opens the selected session in `*Codex Agent Details*`.
- `c` creates a new session in the selected row's working directory through
  the normal Codex session lifecycle and window policy. Missing or inaccessible
  directories are rejected before session startup.
- `e` prompts for a non-empty explicit session name and renames the selected
  thread through the app server. Failures leave the displayed name unchanged
  and open `*Codex Agents Operation*` with recovery guidance.
- `m` places a generic `>` mark on the current row. `d`, `k`, `a`, and `r`
  place mnemonic `D`, `K`, `A`, and `R` marks. `u` removes one mark and `U`
  clears all marks.
- `D`, `K`, `A`, and `R` confirm and apply deletion, local close, archive, or
  restore to all generic `>` marks, falling back to the current row when there
  are no generic marks. Mnemonic marks do not affect their target selection.
- `x` confirms and dispatches every mnemonic mark as a mixed batch. Generic
  `>` marks are ignored and remain marked. Successful action rows lose their
  marks; failures retain their original marker and show an error and recovery
  tip in `*Codex Agents Operation*`.
- `% t`, `% s`, `% r`, `% u`, and `% d` add generic `>` marks by a
  case-insensitive regexp over the full Title, Status, Running In, Updated, or
  Directory value.
- Archive and restore use the app-server's `thread/archive` and
  `thread/unarchive` requests. Archiving may also archive spawned descendants.
- Deletion uses the official `thread/delete` app-server request. Local buffers
  and lifecycle state are closed only after server confirmation; rejection is
  non-destructive, and unsupported servers receive upgrade guidance rather
  than a direct-filesystem fallback.
- The daemon's `updated_at` ordering is preserved, so sessions initially appear
  newest first.
- Archived sessions appear alongside active sessions, fetched through the
  app-server's archived thread list and labeled `Archived` in `Status`.
- Sorting the `Updated` column compares raw timestamps rather than the
  human-readable labels.
- No transcript preview, expanded metadata, grouping, or inline detail pane is
  shown in the list.

The main transient menu also exposes the command as `a` (`Browse all agents`).
Session buffers expose `/agents`, which invokes the same global browser.

The detail buffer shows current status and runtime location, thread and session
IDs, agent identity and role, model settings, source, timestamps, directory,
Git metadata, and preview text. Parent and direct subagent names are buttons;
`RET` follows them in place. `^` moves to the parent, `o` opens or resumes the
displayed session, and `g` refreshes metadata and relationships.

The agents mode uses a buffer-local ASCII truncation ellipsis (`...`). Emacs's
default Unicode ellipsis can be counted as two character columns while its
fallback glyph occupies one monospace cell, shifting later columns for rows
whose session titles are truncated.

## Implementation completed

### Global thread querying

`codex-ide-protocol.el` now has:

- `codex-ide--list-threads-page`, which can omit the `cwd` parameter.
- The existing `codex-ide--list-threads`, still scoped to the current session's
  directory for backward compatibility.
- `codex-ide--list-threads-across-directories`, which omits `cwd` and follows
  every `nextCursor` returned by `thread/list`.
- Repeated-cursor detection to prevent an infinite pagination loop.
- `codex-ide--list-child-threads`, which filters by `parentThreadId` and
  paginates through every direct child.

Omitting `cwd` is the app-server protocol's supported way to list sessions
across all directories. Pagination ensures that “all sessions” does not
silently stop at the configured page size.

### Tabulated agents buffer

The new `codex-ide-agents.el` module contains:

- `codex-ide-agents-mode`, derived from `codex-ide-session-list-mode`.
- The interactive autoloaded command `codex-ide-agents`.
- Flat row construction and display formatting.
- Global query-session setup and refresh behavior.
- Row visitation through the existing `codex-ide--show-or-resume-thread`
  lifecycle function.
- Global live-session lookup by thread ID so an already-open session is
  displayed instead of resumed into a duplicate buffer, even when the daemon's
  recorded directory differs from the Emacs session directory.
- Session renaming through the official `thread/name/set` app-server method.
- Local session closing through the standard buffer teardown lifecycle, without
  deleting the stored app-server thread.
- New-session creation in a selected row's directory through the existing
  `codex-ide` entry point.
- Shared server-authoritative deletion through `thread/delete`, reused by the
  agents and project status interfaces without direct rollout-file removal.
- `thread/deleted` notification normalization into the shared session-event
  hook, including notifications received by query-only connections.
- `thread/name/updated` notification normalization through the same event
  path, so external renames schedule the existing coalesced agents refresh.
- Buffer-local session-event and fallback timers that coalesce automatic
  updates, refresh only while the agents list is visible, and are removed when
  the buffer is killed or changes mode.
- One state-preserving refresh path shared by manual and automatic updates,
  with background errors reported unobtrusively in the mode line.
- Shared-daemon notification routing recognizes thread IDs nested in
  `thread/started` payloads. Starting another session therefore cannot overwrite
  an existing buffer's thread association or make the agents browser resume a
  duplicate buffer.

### Agent detail buffer

The new `codex-ide-agent-detail.el` module contains:

- A read-only overview of current `thread/read` metadata.
- Parent lookup through `parentThreadId`.
- Direct subagent lookup through the filtered, paginated `thread/list` helper.
- In-place navigation between related threads.
- Session display/resume through the existing lifecycle function.

The agents list binds `i` to this detail view. Relationship buttons and `^`
navigate the session tree without creating additional detail buffers.

### Session slash command

`codex-ide-slash-command.el` registers `/agents` and preserves it when an older
default command registry is already loaded. Dispatch opens the same global
agents browser used by the transient menu.

`codex-ide-autoloads.el` contains a minimal autoload entry for the new command.
The full autoload generator was not used for the final diff because Emacs 31
rewrote unrelated generated sections after a transient load warning.

### Emacs-buffer association

Thread IDs are globally unique, so buffer reuse must not depend on the daemon's
recorded `cwd`. A session can otherwise appear stored and be resumed into a new
buffer even though the same thread already has a live Emacs buffer.

`codex-ide--session-for-thread-id-any` now provides one core lookup across all
live session buffers. It is used by:

- `codex-ide-agents` row formatting.
- `codex-ide-status` row formatting and buffer association.
- The central `codex-ide--show-or-resume-thread` path.
- The ordinary continue/resume command path.
- Stored-thread deletion support.

An associated local buffer therefore always displays `Emacs` in `Running In`,
whether its session is idle or running. An active daemon session without a
local buffer displays `External`.

### Feature checklist

`MISSING_FEATURES.md` was updated to separate completed and deferred work:

- `Shared local app server`: `COMPLETE`.
- `Remote app servers`: `TODO`.
- `Global agent browser`: `COMPLETE`.
- `Agent detail overview`: `COMPLETE`.

## Tests added

- `tests/codex-ide-agents-tests.el`
  - Flat rows from multiple directories.
  - Column definitions and absence of detail metadata.
  - Idle and running local-buffer rows display `Emacs` even when directories
    differ.
  - Active sessions without a local buffer display `External`.
  - `RET` resuming the selected thread with that row's directory.
  - Inherited list-navigation bindings.
  - Width-stable truncation for long session titles.
  - Raw timestamp ordering for the sortable `Updated` column.
  - `i` dispatching the selected row to the detail view.
  - `e` seeding the current explicit name, rejecting empty names, sending the
    rename request, refreshing on success, and reporting failure.
  - Generic marking, per-column regexp marking, capital action dispatch,
    cancellation, refresh, and failure mark retention.
  - `c` using the selected row's directory, rejecting unavailable directories,
    and reporting startup failures.
  - State preservation across refreshes, event coalescing, visible-buffer
    polling, interaction deferral, background failure handling, polling
    disablement, the all-refresh toggle, non-selected-window cursor
    preservation, line fallback, and timer/hook cleanup.
- `tests/codex-ide-delete-session-thread-tests.el`
  - Confirmation before requests, server confirmation before local teardown,
    non-destructive cancellation and failure, batch-confirmation bypass, and
    unsupported-server guidance.
- `tests/codex-ide-agent-detail-tests.el`
  - Metadata, parent, and direct subagent rendering.
  - In-place child navigation.
  - Opening or resuming the displayed session.
- `tests/codex-ide-session-buffer-list-tests.el`
  - `RET` uses the standard other-window display action.
  - Existing lists remain visible and newly displayed session windows receive
    focus.
- `tests/codex-ide-protocol-tests.el`
  - Global requests omit `cwd`.
  - Multiple pages are combined.
  - Repeated pagination cursors are rejected.
  - Direct subagent queries include `parentThreadId` and paginate.
  - Thread deletion sends the official `thread/delete` request and payload.
- `tests/codex-ide-slash-command-tests.el`
  - `/agents` is registered and dispatches the global browser.
- `tests/codex-ide-session-tests.el`
  - The resume path prefers an existing buffer across directory differences.
  - Closing a session kills its buffer and process and clears local state.
- `tests/codex-ide-tests.el`
  - A new thread's shared-daemon notification does not steal another live
    session's thread association, while the intended new session still accepts
    it.
  - Query-only connections normalize `thread/deleted` into a session event.
  - Query-only connections normalize `thread/name/updated` into a session event.
- `tests/codex-ide-transient-tests.el`
  - The main menu exposes the new agents command.

## Validation status

- Focused detail, agents, protocol, and slash-command tests: `39/39` passed.
- Focused agents tests after adding Dired-style deletion controls: `13/13`
  passed.
- Focused protocol and agents tests after adding rename: `21/21` passed.
- Focused agents and session tests after adding local close: `29/29` passed.
- Focused agents tests after adding row-directory creation: `27/27` passed.
- Focused agents tests after adding automatic refresh: `33/33` passed.
- Focused agents tests after adding the refresh toggle and per-window point
  preservation: `36/36` passed.
- Focused core and agents tests after adding external name notifications:
  `291/291` passed.
- Focused deletion, protocol, and agents tests after switching to
  app-server-backed deletion: `45/45` passed.
- Focused core notification and deletion regression suite: `254/254` passed.
- Focused agents and protocol tests after generic, mnemonic, and per-column
  marking, ibuffer-style capital actions, and mixed `x` dispatch: `54/54`
  passed.
- Byte compilation passed for the modified runtime files:
  - `codex-ide-agent-detail.el`
  - `codex-ide-agents.el`
  - `codex-ide-protocol.el`
  - `codex-ide-slash-command.el`
- Earlier validation for the browser also passed for:
  - `codex-ide-core.el`
  - `codex-ide-delete-session-thread.el`
  - `codex-ide-session.el`
  - `codex-ide-status-mode.el`
  - `codex-ide-threads.el`
  - `codex-ide-transient.el`
- Focused core and agents suites after fixing nested `thread/started`
  notification routing: `279/279` passed.
- Full non-integration suite after adding row-directory creation and the
  session-routing regression fix: `761/762` passed.
- Full non-integration suite after adding automatic refresh: `767/768` passed;
  the sole failure remains the unrelated MCP bridge fixture described below.
- Full non-integration suite after app-server-backed deletion: `771/772`
  passed; the sole failure remains the same unrelated MCP bridge fixture.
- Full non-integration suite after the cursor-preservation fix: `774/775`
  passed; the sole failure remains the same unrelated MCP bridge fixture.
- Full non-integration suite after external name notifications: `775/776`
  passed; the sole failure remains the same unrelated MCP bridge fixture.
- Full non-integration suite after generic, mnemonic, and per-column marking:
  `786/787` passed; the sole failure remains the same unrelated MCP bridge
  fixture.
- Modified runtime files were successfully reloaded into the running Emacs
  session with `bin/elisp-reload.sh`.
- `git diff --check` passes and no generated `.elc` files remain.
- Live pixel-width verification in the configured Emacs font showed every
  `Stored` status cell beginning at the same 714-pixel offset.

The one full-suite failure is pre-existing and unrelated:

`codex-ide-mcp-bridge-get-current-context-describes-selected-window`

The test creates a project below `/tmp`, but this environment contains
`/tmp/.git`. Emacs consequently reports `/tmp/` as the project root instead of
the temporary fixture directory. The failing assertion observed:

```text
(member "/tmp/" (:json-null "/tmp/codex-ide-tests-.../"))
```

No integration tests were run, in accordance with `AGENTS.md`.

## Remaining work before submission

1. Manually run `M-x codex-ide-agents` against the live shared daemon.
2. Confirm that rows from several directories appear and pagination does not
   introduce noticeable delay.
3. Confirm `RET` on both an idle stored session and a running external session.
4. Verify that idle and running sessions with Emacs buffers display `Emacs`,
   while an active terminal-only session displays `External`.
5. Confirm `i` shows live metadata and parent/subagent navigation against the
   shared daemon.
6. Confirm local and external activity updates the visible list without `g`,
   and that selection and marks survive those updates.
7. Review the final diff and commit only after explicit user approval.

## Deferred follow-up

- Persistent filtering or grouping for very large session lists.
- Remote app-server support.
- Replacing or redirecting `codex-ide-status` once the agents interface is a
  complete successor.
