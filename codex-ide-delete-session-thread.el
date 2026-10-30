;;; codex-ide-delete-session-thread.el --- Delete Codex threads -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Duncan Gillis
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: ai, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Shared deletion support for permanently removing Codex threads through the
;; official app-server API.  Agents and status interfaces use this command so
;; confirmation, server authority, and local teardown follow one lifecycle.

;;; Code:

(require 'subr-x)
(require 'codex-ide-core)
(require 'codex-ide-protocol)

(declare-function codex-ide--close-session "codex-ide-session" (session))
(declare-function codex-ide--ensure-query-session-for-thread-selection
                  "codex-ide-session" (&optional directory))
(declare-function codex-ide--prepare-session-operations
                  "codex-ide-session" ())
(declare-function codex-ide--query-session-for-thread-selection
                  "codex-ide-session" (&optional directory))

(defun codex-ide--codex-home ()
  "Return the active Codex home directory."
  (expand-file-name (or (getenv "CODEX_HOME")
                        "~/.codex")))

(defun codex-ide--delete-live-thread-session (session)
  "Close local SESSION after its thread was deleted by the app server."
  (when session
    (codex-ide--close-session session)))

(defun codex-ide--thread-delete-unsupported-p (err)
  "Return non-nil when ERR indicates that `thread/delete' is unavailable."
  (string-match-p
   (rx (or "method not found"
           "unknown method"
           "not supported"
           "-32601"))
   (downcase (error-message-string err))))

(defun codex-ide--thread-deletion-session (live-session)
  "Return a live app-server session for deleting a thread.
Prefer LIVE-SESSION, then an existing session for the current directory, and
only create a query session when no suitable connection already exists."
  (or live-session
      (codex-ide--get-default-session-for-current-buffer)
      (codex-ide--query-session-for-thread-selection default-directory)
      (progn
        (codex-ide--prepare-session-operations)
        (codex-ide--ensure-query-session-for-thread-selection
         default-directory))))

;;;###autoload
(defun codex-ide-delete-session-thread (thread-id &optional skip-confirmation)
  "Permanently delete Codex THREAD-ID through the app server.

If a live session buffer is attached to THREAD-ID, prompt before requesting
deletion.  Tear down that local session only after the server confirms success.
Server failure therefore leaves its buffer, transcript, and lifecycle state
unchanged.

When SKIP-CONFIRMATION is non-nil, delete without prompting.  This is intended
for batch callers that already presented a single confirmation."
  (interactive
   (list
    (read-string "Delete Codex thread ID: "
                 (when-let* ((session (codex-ide--get-default-session-for-current-buffer)))
                   (codex-ide-session-thread-id session)))))
  (unless (and (stringp thread-id)
               (not (string-empty-p (string-trim thread-id))))
    (user-error "Invalid thread id: %S" thread-id))
  (setq thread-id (string-trim thread-id))
  (let* ((session (codex-ide--session-for-thread-id-any thread-id))
         (buffer (and session (codex-ide-session-buffer session)))
         (buffer-name (and (buffer-live-p buffer) (buffer-name buffer))))
    (unless (or skip-confirmation
                (yes-or-no-p
                 (if buffer-name
                     (format "Delete Codex buffer %s and permanently remove thread %s from %s? "
                             buffer-name
                             thread-id
                             (abbreviate-file-name (codex-ide--codex-home)))
                   (format "Permanently remove Codex thread %s from %s? "
                           thread-id
                           (abbreviate-file-name (codex-ide--codex-home))))))
      (user-error "Canceled deletion of Codex thread %s" thread-id))
    (let ((request-session (codex-ide--thread-deletion-session session)))
      (condition-case err
          (codex-ide--delete-thread request-session thread-id)
        (error
         (if (codex-ide--thread-delete-unsupported-p err)
             (user-error
              (concat
               "This Codex app server does not support thread/delete; "
               "upgrade Codex or delete the session with a compatible client"))
           (signal (car err) (cdr err))))))
    (when session
      (codex-ide--delete-live-thread-session session))
    (message "Deleted Codex thread %s" thread-id)))

(provide 'codex-ide-delete-session-thread)

;;; codex-ide-delete-session-thread.el ends here
