;;; codex-ide-agents.el --- Browse Codex agent sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Duncan Gillis

;;; Commentary:

;; A flat, global `tabulated-list-mode' view of sessions known to the shared
;; Codex app-server daemon.  Unlike `codex-ide-status', this view deliberately
;; does not filter or group sessions by working directory.

;;; Code:

(require 'subr-x)
(require 'codex-ide)
(require 'codex-ide-agent-detail)
(require 'codex-ide-session-list)

(defvar-local codex-ide-agents--query-directory nil
  "Directory used to host the query connection for this agents buffer.")

(defvar-local codex-ide-agents--threads-by-id nil
  "Threads displayed in this agents buffer, keyed by thread id.")

(defvar codex-ide-agents-mode-map
  (make-sparse-keymap)
  "Keymap for `codex-ide-agents-mode'.")

(set-keymap-parent codex-ide-agents-mode-map codex-ide-session-list-mode-map)
(define-key codex-ide-agents-mode-map (kbd "l") #'codex-ide-agents-refresh)
(define-key codex-ide-agents-mode-map (kbd "i") #'codex-ide-agents-detail)
(define-key codex-ide-agents-mode-map (kbd "d") #'codex-ide-agents-mark-delete)
(define-key codex-ide-agents-mode-map (kbd "u") #'codex-ide-agents-unmark)
(define-key codex-ide-agents-mode-map (kbd "U") #'codex-ide-agents-unmark-all)
(define-key codex-ide-agents-mode-map (kbd "X") #'codex-ide-agents-execute-deletions)
(define-key codex-ide-agents-mode-map (kbd "D") #'codex-ide-agents-delete)

(define-derived-mode codex-ide-agents-mode codex-ide-session-list-mode
  "Codex-Agents"
  "Mode for browsing Codex sessions across all working directories."
  ;; A Unicode ellipsis can have a logical width that differs from its fallback
  ;; font's pixel width, shifting columns after a truncated session title.
  (setq-local truncate-string-ellipsis "...")
  (setq-local revert-buffer-function #'codex-ide-agents-refresh))

(defun codex-ide-agents--active-status-p (status)
  "Return non-nil when normalized STATUS represents active work."
  (member status '("running" "submitted" "starting" "interrupting" "approval")))

(defun codex-ide-agents--thread-session (thread)
  "Return this Emacs instance's live session for THREAD, if any."
  (when-let* ((thread-id (alist-get 'id thread)))
    (codex-ide--session-for-thread-id-any thread-id)))

(defun codex-ide-agents--thread-status (thread session)
  "Return the normalized display status for THREAD and local SESSION."
  (let* ((server-status
          (codex-ide--normalize-session-status (alist-get 'status thread)))
         (local-status
          (and session
               (codex-ide--normalize-session-status
                (codex-ide-session-status session))))
         (status
          (cond
           ((equal server-status "running")
            (if (codex-ide-agents--active-status-p local-status)
                local-status
              server-status))
           (local-status local-status)
           (server-status server-status)
           (t "stored"))))
    (if (equal (downcase status) "notloaded")
        "stored"
      status)))

(defun codex-ide-agents--running-in (status session)
  "Describe whether STATUS is associated with this Emacs or an external client."
  (cond
   (session "Emacs")
   ((codex-ide-agents--active-status-p status) "External")
   (t "")))

(defun codex-ide-agents--title (thread)
  "Return a one-line display title for THREAD."
  (let ((title
         (codex-ide--thread-choice-preview
          (or (alist-get 'name thread)
              (alist-get 'preview thread)
              ""))))
    (setq title (replace-regexp-in-string "[\n\r]+" "↵" title))
    (if (string-empty-p title) "Untitled" title)))

(defun codex-ide-agents--directory (thread)
  "Return THREAD's abbreviated working directory for display."
  (if-let* ((directory (alist-get 'cwd thread)))
      (abbreviate-file-name directory)
    ""))

(defun codex-ide-agents--entry (thread)
  "Return a tabulated-list entry for THREAD."
  (let* ((thread-id (alist-get 'id thread))
         (directory (alist-get 'cwd thread))
         (session (codex-ide-agents--thread-session thread))
         (status (codex-ide-agents--thread-status thread session))
         (status-label (codex-ide-renderer-status-label status))
         (running-in (codex-ide-agents--running-in status session))
         (updated
          (codex-ide--format-thread-updated-at (alist-get 'updatedAt thread))))
    (list (cons thread-id directory)
          (vector
           (codex-ide-session-list-cell
            (codex-ide-agents--title thread)
            'codex-ide-session-list-primary-face)
           (codex-ide-session-list-cell
            status-label
            'codex-ide-session-list-status-face)
           (codex-ide-session-list-cell
            running-in
            (if (string-empty-p running-in)
                'codex-ide-session-list-secondary-face
              'codex-ide-session-list-primary-face))
           (codex-ide-session-list-cell
            updated
            'codex-ide-session-list-time-face)
           (codex-ide-session-list-cell
            (codex-ide-agents--directory thread)
            'codex-ide-session-list-secondary-face)))))

(defun codex-ide-agents--updated-less-p (left right)
  "Return non-nil when LEFT was updated before RIGHT.
LEFT and RIGHT are tabulated-list entries whose thread metadata is stored in
`codex-ide-agents--threads-by-id'."
  (let ((left-thread
         (gethash (car (car left)) codex-ide-agents--threads-by-id))
        (right-thread
         (gethash (car (car right)) codex-ide-agents--threads-by-id)))
    (time-less-p (codex-ide--thread-updated-at-time left-thread)
                 (codex-ide--thread-updated-at-time right-thread))))

(defun codex-ide-agents--entries ()
  "Return global Codex session entries for the current agents buffer."
  (unless codex-ide-agents--query-directory
    (error "No query directory is associated with this agents buffer"))
  (codex-ide--prepare-session-operations)
  (let ((session
         (codex-ide--ensure-query-session-for-thread-selection
          codex-ide-agents--query-directory)))
    (let ((threads (codex-ide--list-threads-across-directories session)))
      (setq codex-ide-agents--threads-by-id (make-hash-table :test #'equal))
      (dolist (thread threads)
        (puthash (alist-get 'id thread)
                 thread
                 codex-ide-agents--threads-by-id))
      (mapcar #'codex-ide-agents--entry threads))))

(defun codex-ide-agents--visit (row-id)
  "Display or resume the session identified by ROW-ID."
  (let ((thread-id (car row-id))
        (directory (cdr row-id)))
    (unless (and (stringp thread-id) (stringp directory))
      (user-error "This Codex session has no resumable thread or directory"))
    (codex-ide--prepare-session-operations)
    (codex-ide--show-or-resume-thread thread-id directory)))

(defun codex-ide-agents-detail ()
  "Inspect metadata and relationships for the agent session at point."
  (interactive)
  (let* ((row-id (tabulated-list-get-id))
         (thread-id (car-safe row-id))
         (thread (and thread-id
                      (gethash thread-id codex-ide-agents--threads-by-id))))
    (unless thread
      (user-error "No Codex agent session at point"))
    (codex-ide-agent-detail-show thread codex-ide-agents--query-directory)))

(defun codex-ide-agents--thread-at-point ()
  "Return the agent thread at point, or signal a user error."
  (let* ((row-id (tabulated-list-get-id))
         (thread-id (car-safe row-id))
         (thread (and thread-id
                      (gethash thread-id codex-ide-agents--threads-by-id))))
    (or thread (user-error "No Codex agent session at point"))))

(defun codex-ide-agents-mark-delete ()
  "Mark the Codex session at point for deletion and advance one row."
  (interactive)
  (codex-ide-agents--thread-at-point)
  (tabulated-list-put-tag "D" t))

(defun codex-ide-agents-unmark ()
  "Remove the deletion mark from the Codex session at point and advance."
  (interactive)
  (codex-ide-agents--thread-at-point)
  (tabulated-list-put-tag " " t))

(defun codex-ide-agents-unmark-all ()
  "Remove every deletion mark from the current agents list."
  (interactive)
  (let ((count 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (and (tabulated-list-get-id)
                   (eq (char-after (line-beginning-position)) ?D))
          (tabulated-list-put-tag " ")
          (setq count (1+ count)))
        (forward-line 1)))
    (message "Cleared %d deletion %s"
             count
             (if (= count 1) "mark" "marks"))))

(defun codex-ide-agents--marked-threads ()
  "Return threads marked for deletion in the current agents buffer."
  (let (threads)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (eq (char-after (line-beginning-position)) ?D)
          (when-let* ((row-id (tabulated-list-get-id))
                      (thread-id (car-safe row-id))
                      (thread (gethash thread-id codex-ide-agents--threads-by-id)))
            (push thread threads)))
        (forward-line 1)))
    (nreverse threads)))

(defun codex-ide-agents--show-delete-failures (failures)
  "Show deletion FAILURES as a list of (THREAD-ID . ERROR-DATA)."
  (let ((buffer (get-buffer-create "*Codex Agents Operation*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Codex session deletion failed\n\n")
        (dolist (failure failures)
          (insert "Thread: " (car failure) "\n"
                  "Error: " (error-message-string (cdr failure)) "\n\n"))
        (insert "Tip: Refresh the agents list with l and check whether each "
                "thread still has a rollout file in CODEX_HOME/sessions. "
                "Stop active work before retrying deletion.\n")
        (special-mode)))
    (display-buffer buffer)))

(defun codex-ide-agents--delete-threads (threads)
  "Confirm and permanently delete THREADS, then refresh the agents list."
  (let ((count (length threads)))
    (when (yes-or-no-p
           (if (= count 1)
               (let ((thread (car threads)))
                 (format "Permanently delete Codex session %s (%s)? "
                         (codex-ide-agents--title thread)
                         (alist-get 'id thread)))
             (format "Permanently delete %d marked Codex sessions? " count)))
      (let (deleted failures)
        (dolist (thread threads)
          (let ((thread-id (alist-get 'id thread)))
            (condition-case err
                (progn
                  (codex-ide-delete-session-thread thread-id t)
                  (setq deleted t))
              (error
               (push (cons thread-id err) failures)))))
        (when deleted
          (codex-ide-agents-refresh))
        (when failures
          (codex-ide-agents--show-delete-failures (nreverse failures)))))))

(defun codex-ide-agents-execute-deletions ()
  "Confirm and permanently delete every session marked with `d'."
  (interactive)
  (let ((threads (codex-ide-agents--marked-threads)))
    (unless threads
      (user-error "No Codex agent sessions marked for deletion"))
    (codex-ide-agents--delete-threads threads)))

(defun codex-ide-agents-delete ()
  "Confirm and permanently delete the Codex session at point."
  (interactive)
  (codex-ide-agents--delete-threads
   (list (codex-ide-agents--thread-at-point))))

(defun codex-ide-agents-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the global Codex agents list."
  (interactive)
  (tabulated-list-print t))

;;;###autoload
(defun codex-ide-agents ()
  "Show a flat list of Codex sessions across all working directories."
  (interactive)
  (let* ((directory (codex-ide--normalize-directory
                     (codex-ide--get-working-directory)))
         (buffer
          (codex-ide-session-list--setup
           "*Codex Agents*"
           #'codex-ide-agents-mode
           [("Session" 15 t)
            ("Status" 14 t)
            ("Running In" 12 t)
            ("Updated" 16 codex-ide-agents--updated-less-p)
            ("Directory" 36 t)]
           #'codex-ide-agents--entries
           #'codex-ide-agents--visit
           nil
           (lambda ()
             (setq-local default-directory directory)
             (setq-local codex-ide-agents--query-directory directory)))))
    (pop-to-buffer buffer)))

(provide 'codex-ide-agents)

;;; codex-ide-agents.el ends here
