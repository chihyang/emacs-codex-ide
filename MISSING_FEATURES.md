# Missing Codex CLI Features

This document summarizes user-facing features available in Codex CLI that are
missing or incomplete in `codex-ide`. It is based on Codex CLI 0.163.0 and the
official Codex documentation as reviewed on 2026-10-22.

## High priority

| Status | Feature | Missing functionality |
| --- | --- | --- |
| TODO | Code review workflow | Add a dedicated review command with targets for uncommitted changes, a commit, a base branch, or custom review instructions. Review events can already be rendered, but `codex-ide` cannot initiate review mode. |
| COMPLETE | Conversation forks | Fork a selected active or stored session's complete history from the global agents browser and open the new thread in the same directory. Branching from an earlier prompt remains optional follow-up work. |
| TODO | Context compaction | Let users explicitly request conversation compaction. Compaction events are already rendered when the server initiates them. |
| COMPLETE | Shared local app server | Connect through the shared managed Codex daemon instead of starting an independent app-server for every Emacs session. |
| TODO | Remote app servers | Connect to remote WebSocket or Unix-socket app servers. |
| COMPLETE | Global agent browser | Browse and resume sessions across all working directories, including their status, directory, and whether active work is running in this Emacs or externally. |
| COMPLETE | Agent detail overview | Inspect session metadata from the global agents browser and navigate parent and direct subagent threads. |
| TODO | Codex Cloud | Browse cloud tasks, select environments, submit tasks, inspect results and diffs, and apply cloud changes locally. |
| NATIVE ALTERNATIVE | Managed worktrees | Use Magit for worktree lifecycle, then start or resume Codex in that directory. Codex-specific worktree management is intentionally out of scope. |

## Medium priority

| Status | Feature | Missing functionality |
| --- | --- | --- |
| TODO | Plugin management | Browse marketplaces and install, remove, enable, or disable plugins. |
| TODO | Apps and connectors | Browse available apps, authenticate connections, and insert app mentions into prompts. |
| TODO | MCP management | List general MCP servers and tools, inspect diagnostics, add or remove servers, and perform MCP OAuth login/logout. Existing MCP tool calls and elicitations are already supported. |
| TODO | Complete prompt mentions | Add `@` completion for files, directories, apps, and plugins. Only `$skill` completion is currently implemented. |
| COMPLETE | Session lifecycle | Archive, unarchive, rename, and official app-server-backed deletion are implemented. |
| TODO | Plan mode | Add an explicit plan-mode toggle and plan-oriented submission flow. Plan output already renders correctly. |
| TODO | Persistent goals | Create, inspect, edit, pause, resume, and clear session goals. |
| TODO | Memories | Control memory injection and generation and show active memory state. |
| TODO | Skills UI | Browse skill details and errors and enable, disable, install, or refresh skills. Skill discovery and `$skill` completion already exist. |
| TODO | Lifecycle hooks | Inspect configured hooks and manage hook trust and enabled state. |
| TODO | Background terminals | List long-running commands, show recent output, and stop background terminal processes. |
| TODO | Local shell input | Provide an Emacs-native equivalent of the CLI's `!` composer shortcut using the active sandbox and approval policy. |
| TODO | Web-search control | Add a first-class per-session control for native web search. Web-search events already render correctly when search is enabled. |
| TODO | Additional runtime settings | Add structured controls for configuration profiles, OSS providers, extra writable directories, automatic approval review, strict configuration, and feature flags. Raw app-server flags are currently available only through `codex-ide-cli-extra-flags`. |

## Lower priority and administrative features

| Status | Feature | Missing functionality |
| --- | --- | --- |
| TODO | Detailed usage | Add historical usage views and earned-reset actions. |
| TODO | Import and migration | Import Claude Code or Cursor configuration, projects, and chats. |
| TODO | Feedback submission | Submit feedback with optional diagnostic logs. |
| TODO | Desktop-app handoff | Continue an Emacs session in the ChatGPT desktop app. |
| TODO | Authentication management | Add login, logout, and login-status interfaces. |
| TODO | CLI maintenance and diagnostics | Expose CLI update, doctor, feature inspection, rollout migration, and standalone sandbox helpers. |
| TODO | Non-interactive execution | Support `codex exec` workflows, including JSONL events, output schemas, final-message files, ephemeral runs, and CI-oriented execution. |
| TODO | Cloud-diff application | Add an equivalent of `codex apply`. |

## Already implemented

The following CLI capabilities already have direct or Emacs-native
counterparts and should not be treated as missing:

- Starting, resuming, interrupting, and resetting sessions.
- Multiple simultaneous session buffers and stored-session browsing.
- Streaming assistant messages, reasoning summaries, plans, command output,
  file changes, web searches, MCP calls, dynamic tools, and subagent activity.
- Command, file-change, permissions, and MCP-elicitation approval flows.
- Steering an active turn and queuing the next prompt.
- Local image and clipboard-image attachment.
- Model, reasoning-effort, fast-mode, personality, sandbox, and approval-policy
  configuration.
- Token and rate-limit status.
- Skill discovery and `$skill` prompt completion.
- Live, transcript-relative, pinned, and turn-specific diff views.
- Emacs buffer, file, selection, and window context through prompt context and
  the optional Emacs MCP bridge.

Terminal-only presentation features such as alternate-screen mode, Vim input,
raw terminal scrollback, terminal themes and titles, pets, and shell completion
are not considered parity gaps for a native Emacs interface.

## References

- [Codex CLI overview](https://learn.chatgpt.com/docs/codex/cli)
- [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
- [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server)
