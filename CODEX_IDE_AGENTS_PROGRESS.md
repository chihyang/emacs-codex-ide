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
| `Status` | Normalized daemon or live Emacs status, such as `Running`, `Idle`, or `Stored`. |
| `Running In` | `Emacs` when the session has a live buffer in this Emacs, `External` when an active session has no local buffer, and blank for inactive sessions without a local buffer. |
| `Updated` | Human-readable last-update time, sortable by the underlying timestamp. |
| `Directory` | Full working directory, abbreviated with `~` where applicable. |

Key behavior:

- `RET` displays an existing Emacs session buffer or resumes the stored thread
  in another window when possible, preserving the agents list and selecting
  the session window.
- `M-RET` and `C-M-j` perform the same action in another window through the
  shared session-list bindings.
- `l` refreshes the list; standard tabulated-list refresh behavior remains
  available.
- `i` opens the selected session in `*Codex Agent Details*`.
- The daemon's `updated_at` ordering is preserved, so sessions initially appear
  newest first.
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
- `tests/codex-ide-slash-command-tests.el`
  - `/agents` is registered and dispatches the global browser.
- `tests/codex-ide-session-tests.el`
  - The resume path prefers an existing buffer across directory differences.
- `tests/codex-ide-transient-tests.el`
  - The main menu exposes the new agents command.

## Validation status

- Focused detail, agents, protocol, and slash-command tests: `39/39` passed.
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
- Full non-integration suite: `737/738` passed.
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
6. Review the final diff and commit only after explicit user approval.

## Deferred follow-up

- Automatic refresh for external daemon activity.
- Rename, archive, unarchive, and deletion actions.
- Remote app-server support.
- Replacing or redirecting `codex-ide-status` once the agents interface is a
  complete successor.
