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

;;;###autoload
(defcustom codex-ide-agents-auto-refresh-interval 5
  "Seconds between fallback refreshes of visible agents buffers.
Set this to nil or a non-positive number to disable timer polling.  Session
events can still schedule automatic refreshes when polling is disabled."
  :type '(choice (const :tag "Disable polling" nil) number)
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-agents-event-refresh-delay 0.1
  "Idle delay used to coalesce agents refreshes after session events."
  :type 'number
  :group 'codex-ide)

(defvar-local codex-ide-agents--query-directory nil
  "Directory used to host the query connection for this agents buffer.")

(defvar-local codex-ide-agents--threads-by-id nil
  "Threads displayed in this agents buffer, keyed by thread id.")

(defvar-local codex-ide-agents--poll-timer nil
  "Fallback timer used to reconcile this agents buffer with the app server.")

(defvar-local codex-ide-agents--refresh-timer nil
  "Idle timer used to coalesce automatic agents refreshes.")

(defvar-local codex-ide-agents--event-listener nil
  "Function registered on `codex-ide-session-event-hook' for this buffer.")

(defvar-local codex-ide-agents--interaction-active nil
  "Non-nil while an interactive agents operation is in progress.")

(defvar-local codex-ide-agents--last-refresh-error nil
  "Most recent background refresh error message, or nil after success.")

(defvar-local codex-ide-agents--auto-refresh-enabled t
  "Non-nil when this agents buffer refreshes automatically.")

(defvar codex-ide-agents-mode-map
  (make-sparse-keymap)
  "Keymap for `codex-ide-agents-mode'.")

(defvar codex-ide-agents-mark-by-map
  (make-sparse-keymap)
  "Prefix map for marking agent sessions by a displayed column.")

(define-key codex-ide-agents-mark-by-map (kbd "t")
            #'codex-ide-agents-mark-by-title)
(define-key codex-ide-agents-mark-by-map (kbd "s")
            #'codex-ide-agents-mark-by-status)
(define-key codex-ide-agents-mark-by-map (kbd "r")
            #'codex-ide-agents-mark-by-running-in)
(define-key codex-ide-agents-mark-by-map (kbd "u")
            #'codex-ide-agents-mark-by-updated)
(define-key codex-ide-agents-mark-by-map (kbd "d")
            #'codex-ide-agents-mark-by-directory)

(set-keymap-parent codex-ide-agents-mode-map codex-ide-session-list-mode-map)
(define-key codex-ide-agents-mode-map (kbd "i") #'codex-ide-agents-detail)
(define-key codex-ide-agents-mode-map (kbd "c") #'codex-ide-agents-create)
(define-key codex-ide-agents-mode-map (kbd "e") #'codex-ide-agents-rename)
(define-key codex-ide-agents-mode-map (kbd "m") #'codex-ide-agents-mark)
(define-key codex-ide-agents-mode-map (kbd "k") #'codex-ide-agents-mark-close)
(define-key codex-ide-agents-mode-map (kbd "d") #'codex-ide-agents-mark-delete)
(define-key codex-ide-agents-mode-map (kbd "a") #'codex-ide-agents-mark-archive)
(define-key codex-ide-agents-mode-map (kbd "r") #'codex-ide-agents-mark-unarchive)
(define-key codex-ide-agents-mode-map (kbd "u") #'codex-ide-agents-unmark)
(define-key codex-ide-agents-mode-map (kbd "U") #'codex-ide-agents-unmark-all)
(define-key codex-ide-agents-mode-map (kbd "x")
            #'codex-ide-agents-execute-marks)
(define-key codex-ide-agents-mode-map (kbd "X") nil)
(define-key codex-ide-agents-mode-map (kbd "K") #'codex-ide-agents-close)
(define-key codex-ide-agents-mode-map (kbd "D") #'codex-ide-agents-delete)
(define-key codex-ide-agents-mode-map (kbd "A") #'codex-ide-agents-archive)
(define-key codex-ide-agents-mode-map (kbd "R") #'codex-ide-agents-unarchive)
(define-key codex-ide-agents-mode-map (kbd "t")
            #'codex-ide-agents-toggle-auto-refresh)
(define-key codex-ide-agents-mode-map (kbd "%") codex-ide-agents-mark-by-map)

(define-derived-mode codex-ide-agents-mode codex-ide-session-list-mode
  "Codex-Agents"
  "Mode for browsing Codex sessions across all working directories."
  ;; A Unicode ellipsis can have a logical width that differs from its fallback
  ;; font's pixel width, shifting columns after a truncated session title.
  (setq-local truncate-string-ellipsis "...")
  (setq-local revert-buffer-function #'codex-ide-agents-refresh)
  (setq-local mode-line-process
              '(:eval (codex-ide-agents--mode-line-refresh-status)))
  (codex-ide-agents--teardown-auto-refresh)
  (codex-ide-agents--setup-auto-refresh))

(defconst codex-ide-agents--session-events
  '(created destroyed thread-attached status-changed turn-started
            turn-completed approval-requested reset thread-deleted
            thread-name-updated
            config-changed)
  "Session events that should schedule an agents list refresh.")

(defmacro codex-ide-agents--with-interaction (&rest body)
  "Run BODY while automatic agents refreshes are deferred."
  (declare (indent 0) (debug t))
  `(let ((codex-ide-agents--interaction-active t))
     ,@body))

(defun codex-ide-agents--mode-line-refresh-status ()
  "Return mode-line status for automatic agents refresh."
  (cond
   (codex-ide-agents--last-refresh-error
    (propertize " [refresh failed]"
                'face 'warning
                'help-echo codex-ide-agents--last-refresh-error))
   ((not codex-ide-agents--auto-refresh-enabled)
    (propertize " [auto refresh off]" 'face 'shadow))))

(defun codex-ide-agents--visible-p ()
  "Return non-nil when the current agents buffer is visible on any frame."
  (get-buffer-window (current-buffer) 'visible))

(defun codex-ide-agents--auto-refresh-safe-p ()
  "Return non-nil when the current agents buffer may refresh in background."
  (and codex-ide-agents--auto-refresh-enabled
       (derived-mode-p 'codex-ide-agents-mode)
       codex-ide-agents--query-directory
       (codex-ide-agents--visible-p)
       (not codex-ide-agents--interaction-active)
       (not (active-minibuffer-window))))

(defun codex-ide-agents--cancel-refresh-timer ()
  "Cancel the pending coalesced refresh timer in the current buffer."
  (when (timerp codex-ide-agents--refresh-timer)
    (cancel-timer codex-ide-agents--refresh-timer))
  (setq codex-ide-agents--refresh-timer nil))

(defun codex-ide-agents--cancel-poll-timer ()
  "Cancel fallback polling for the current agents buffer."
  (when (timerp codex-ide-agents--poll-timer)
    (cancel-timer codex-ide-agents--poll-timer))
  (setq codex-ide-agents--poll-timer nil))

(defun codex-ide-agents--background-refresh ()
  "Refresh the current agents buffer without interrupting the user on error."
  (condition-case err
      (progn
        (codex-ide-agents--refresh-list)
        (setq codex-ide-agents--last-refresh-error nil))
    (error
     (setq codex-ide-agents--last-refresh-error (error-message-string err))))
  (force-mode-line-update))

(defun codex-ide-agents--run-scheduled-refresh (buffer)
  "Run or defer a coalesced automatic refresh of agents BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq codex-ide-agents--refresh-timer nil)
      (if (codex-ide-agents--auto-refresh-safe-p)
          (codex-ide-agents--background-refresh)
        (when (and (derived-mode-p 'codex-ide-agents-mode)
                   codex-ide-agents--query-directory
                   (codex-ide-agents--visible-p))
          (codex-ide-agents--schedule-refresh))))))

(defun codex-ide-agents--schedule-refresh ()
  "Schedule one coalesced automatic refresh for the current agents buffer."
  (unless (timerp codex-ide-agents--refresh-timer)
    (setq codex-ide-agents--refresh-timer
          (run-with-idle-timer
           codex-ide-agents-event-refresh-delay
           nil
           #'codex-ide-agents--run-scheduled-refresh
           (current-buffer)))))

(defun codex-ide-agents--poll (buffer)
  "Schedule fallback reconciliation for visible live agents BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (codex-ide-agents--auto-refresh-safe-p)
        (codex-ide-agents--schedule-refresh)))))

(defun codex-ide-agents--handle-session-event (event _session _payload)
  "Schedule a list refresh when the global agents view is affected by EVENT."
  (when (and codex-ide-agents--auto-refresh-enabled
             (memq event codex-ide-agents--session-events)
             (codex-ide-agents--visible-p))
    (codex-ide-agents--schedule-refresh)))

(defun codex-ide-agents--setup-auto-refresh ()
  "Subscribe this agents buffer to events and optional fallback polling."
  (when codex-ide-agents--auto-refresh-enabled
    (unless codex-ide-agents--event-listener
      (let ((buffer (current-buffer)))
        (setq codex-ide-agents--event-listener
              (lambda (event session payload)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (codex-ide-agents--handle-session-event
                     event session payload)))))))
    (add-hook 'codex-ide-session-event-hook codex-ide-agents--event-listener)
    (when (and (numberp codex-ide-agents-auto-refresh-interval)
               (> codex-ide-agents-auto-refresh-interval 0))
      (setq codex-ide-agents--poll-timer
            (run-with-timer
             codex-ide-agents-auto-refresh-interval
             codex-ide-agents-auto-refresh-interval
             #'codex-ide-agents--poll
             (current-buffer))))
    (add-hook 'kill-buffer-hook #'codex-ide-agents--teardown-auto-refresh nil t)
    (add-hook 'change-major-mode-hook
              #'codex-ide-agents--teardown-auto-refresh nil t)))

(defun codex-ide-agents--teardown-auto-refresh ()
  "Remove automatic refresh timers and event subscriptions for this buffer."
  (codex-ide-agents--cancel-refresh-timer)
  (codex-ide-agents--cancel-poll-timer)
  (when codex-ide-agents--event-listener
    (remove-hook 'codex-ide-session-event-hook codex-ide-agents--event-listener)
    (setq codex-ide-agents--event-listener nil))
  (remove-hook 'kill-buffer-hook #'codex-ide-agents--teardown-auto-refresh t)
  (remove-hook 'change-major-mode-hook
               #'codex-ide-agents--teardown-auto-refresh t))

(defun codex-ide-agents-toggle-auto-refresh (&optional arg)
  "Toggle automatic refresh in the current agents buffer.
With a positive prefix ARG, enable it.  With a non-positive prefix ARG,
disable it.  Manual refresh with `g' remains available while disabled."
  (interactive "P")
  (unless (derived-mode-p 'codex-ide-agents-mode)
    (user-error "Not in a Codex agents buffer"))
  (let ((enable
         (if arg
             (> (prefix-numeric-value arg) 0)
           (not codex-ide-agents--auto-refresh-enabled))))
    (codex-ide-agents--teardown-auto-refresh)
    (setq codex-ide-agents--auto-refresh-enabled enable)
    (when enable
      (codex-ide-agents--setup-auto-refresh))
    (force-mode-line-update)
    (message "Codex agents automatic refresh %s"
             (if enable "enabled" "disabled"))))

(defun codex-ide-agents--active-status-p (status)
  "Return non-nil when normalized STATUS represents active work."
  (member status '("running" "submitted" "starting" "interrupting" "approval")))

(defun codex-ide-agents--thread-session (thread)
  "Return this Emacs instance's live session for THREAD, if any."
  (when-let* ((thread-id (alist-get 'id thread)))
    (codex-ide--session-for-thread-id-any thread-id)))

(defun codex-ide-agents--thread-status (thread session)
  "Return the normalized display status for THREAD and local SESSION."
  (if (alist-get 'archived thread)
      "archived"
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
        status))))

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
    (let* ((active (codex-ide--list-threads-across-directories session))
           (archived (codex-ide--list-threads-across-directories
                      session :archived t))
           (threads
            (sort (append active
                          (mapcar (lambda (thread)
                                    (cons '(archived . t) thread))
                                  archived))
                  (lambda (left right)
                    (time-less-p
                     (codex-ide--thread-updated-at-time right)
                     (codex-ide--thread-updated-at-time left))))))
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

(defun codex-ide-agents--local-session (thread)
  "Return THREAD's live session in this Emacs, or signal a user error."
  (or (codex-ide-agents--thread-session thread)
      (user-error "This Codex session is not running in this Emacs")))

(defun codex-ide-agents--show-operation-failures (operation failures tip)
  "Show OPERATION FAILURES and recovery TIP.
FAILURES is a list of (THREAD-ID . ERROR-DATA)."
  (let ((buffer (get-buffer-create "*Codex Agents Operation*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Codex session %s failed\n\n" operation))
        (dolist (failure failures)
          (insert "Thread: " (car failure) "\n"
                  "Error: " (error-message-string (cdr failure)) "\n\n"))
        (insert "Tip: " tip "\n")
        (special-mode)))
    (display-buffer buffer)))

(defun codex-ide-agents-create ()
  "Create a new Codex session in the selected agent's directory."
  (interactive)
  (codex-ide-agents--with-interaction
    (let* ((thread (codex-ide-agents--thread-at-point))
           (thread-id (alist-get 'id thread))
           (recorded-directory (alist-get 'cwd thread)))
      (unless (and (stringp recorded-directory)
                   (not (string-empty-p recorded-directory)))
        (user-error "This Codex session has no working directory"))
      (let ((directory (file-name-as-directory
                        (expand-file-name recorded-directory))))
        (unless (file-accessible-directory-p directory)
          (user-error
           "Cannot create a Codex session; directory is unavailable: %s"
           (abbreviate-file-name directory)))
        (condition-case err
            (let ((default-directory directory))
              (codex-ide))
          (error
           (codex-ide-agents--show-operation-failures
            "creation"
            (list (cons thread-id err))
            (concat
             "Verify that the directory and Codex app server are available, "
             "then retry with c."))))))))

(defun codex-ide-agents-rename ()
  "Prompt for and set the explicit name of the Codex session at point."
  (interactive)
  (codex-ide-agents--with-interaction
    (let* ((thread (codex-ide-agents--thread-at-point))
           (thread-id (alist-get 'id thread))
           (current-name (alist-get 'name thread))
           (name
            (string-trim
             (read-string
              "Rename Codex session: "
              (if (stringp current-name) current-name "")))))
      (when (string-empty-p name)
        (user-error "Codex session name cannot be empty"))
      (let (renamed)
        (condition-case err
            (progn
              (codex-ide--prepare-session-operations)
              (codex-ide--set-thread-name
               (codex-ide--ensure-query-session-for-thread-selection
                codex-ide-agents--query-directory)
               thread-id
               name)
              (setq renamed t))
          (error
           (codex-ide-agents--show-operation-failures
            "rename"
            (list (cons thread-id err))
            (concat
             "Refresh the agents list with g, verify that the thread still "
             "exists, and retry the rename."))))
        (when renamed
          (condition-case err
              (progn
                (codex-ide-agents-refresh)
                (message "Renamed Codex session to %s" name))
            (error
             (codex-ide-agents--show-operation-failures
              "refresh after rename"
              (list (cons thread-id err))
              (concat
               "The rename succeeded. Refresh the agents list with g to show "
               "the new name.")))))))))

(defun codex-ide-agents-mark ()
  "Mark the Codex session at point with `>' and advance one row."
  (interactive)
  (codex-ide-agents--mark-with-character ?>))

(defun codex-ide-agents--mark-with-character (character)
  "Mark the session at point with CHARACTER and advance one row."
  (codex-ide-agents--thread-at-point)
  (tabulated-list-put-tag (char-to-string character) t))

(defun codex-ide-agents-mark-delete ()
  "Mark the Codex session at point with `D' and advance one row."
  (interactive)
  (codex-ide-agents--mark-with-character ?D))

(defun codex-ide-agents-mark-close ()
  "Mark the Codex session at point with `K' and advance one row."
  (interactive)
  (codex-ide-agents--mark-with-character ?K))

(defun codex-ide-agents-mark-archive ()
  "Mark the Codex session at point with `A' and advance one row."
  (interactive)
  (codex-ide-agents--mark-with-character ?A))

(defun codex-ide-agents-mark-unarchive ()
  "Mark the Codex session at point with `R' and advance one row."
  (interactive)
  (codex-ide-agents--mark-with-character ?R))

(defun codex-ide-agents-unmark ()
  "Remove the operation mark from the Codex session at point and advance."
  (interactive)
  (codex-ide-agents--thread-at-point)
  (tabulated-list-put-tag " " t))

(defun codex-ide-agents--clear-marks ()
  "Clear all marks in the current agents list and return their count."
  (let ((count 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (and (tabulated-list-get-id)
                   (memq (char-after (line-beginning-position))
                         '(?> ?D ?K ?A ?R)))
          (tabulated-list-put-tag " ")
          (setq count (1+ count)))
        (forward-line 1)))
    count))

(defun codex-ide-agents--clear-thread-marks (thread-ids)
  "Clear marks for rows whose thread ids are in THREAD-IDS."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when-let* ((row-id (tabulated-list-get-id))
                  (thread-id (car-safe row-id)))
        (when (member thread-id thread-ids)
          (tabulated-list-put-tag " ")))
      (forward-line 1))))

(defun codex-ide-agents-unmark-all ()
  "Remove every operation mark from the current agents list."
  (interactive)
  (let ((count (codex-ide-agents--clear-marks)))
    (message "Cleared %d operation %s"
             count
             (if (= count 1) "mark" "marks"))))

(defun codex-ide-agents--marked-threads ()
  "Return all marked threads in current buffer order."
  (let (threads)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* (((memq (char-after (line-beginning-position))
                            '(?> ?D ?K ?A ?R)))
                    (row-id (tabulated-list-get-id))
                    (thread-id (car-safe row-id))
                    (thread (gethash thread-id codex-ide-agents--threads-by-id)))
          (push thread threads))
        (forward-line 1)))
    (nreverse threads)))

(defun codex-ide-agents--restore-marks (marks)
  "Restore MARKS after a list refresh.
MARKS contains (THREAD-ID . CHARACTER) pairs."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when-let* ((row-id (tabulated-list-get-id))
                  (thread-id (car-safe row-id))
                  (mark (alist-get thread-id marks nil nil #'equal)))
        (tabulated-list-put-tag (char-to-string mark)))
      (forward-line 1))))

(defun codex-ide-agents--marks ()
  "Return marks keyed by thread id in the current list."
  (let (marks)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((mark (and (memq (char-after (line-beginning-position))
                                      '(?> ?D ?K ?A ?R))
                                (char-after (line-beginning-position))))
                    (row-id (tabulated-list-get-id))
                    (thread-id (car-safe row-id)))
          (push (cons thread-id mark) marks))
        (forward-line 1)))
    (nreverse marks)))

(defun codex-ide-agents--action-for-mark (mark)
  "Return the batch action represented by special MARK.
A generic `>' mark has no batch action."
  (pcase mark
    (?D 'delete)
    (?K 'close)
    (?A 'archive)
    (?R 'unarchive)))

(defun codex-ide-agents--marked-actions (marks &optional generic-action)
  "Return action and thread pairs represented by MARKS.
When GENERIC-ACTION is non-nil, select only generic `>' marks and use that
action for each.  Otherwise select only mnemonic marks and use the action
encoded by each marker."
  (delq
   nil
   (mapcar
    (lambda (mark)
      (when-let* ((action (if generic-action
                              (and (eq (cdr mark) ?>) generic-action)
                            (codex-ide-agents--action-for-mark (cdr mark))))
                  (thread (gethash (car mark)
                                   codex-ide-agents--threads-by-id)))
        (cons action thread)))
    marks)))

(defun codex-ide-agents--column-value (thread column)
  "Return THREAD's full displayed value for COLUMN."
  (pcase column
    ('title (codex-ide-agents--title thread))
    ('status
     (codex-ide-renderer-status-label
      (codex-ide-agents--thread-status
       thread (codex-ide-agents--thread-session thread))))
    ('running-in
     (let* ((session (codex-ide-agents--thread-session thread))
            (status (codex-ide-agents--thread-status thread session)))
       (codex-ide-agents--running-in status session)))
    ('updated
     (codex-ide--format-thread-updated-at (alist-get 'updatedAt thread)))
    ('directory (codex-ide-agents--directory thread))))

(defun codex-ide-agents--mark-by-column (column label regexp)
  "Mark rows whose COLUMN value matches REGEXP.
LABEL is the user-facing column name."
  (let ((case-fold-search t)
        (count 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((row-id (tabulated-list-get-id))
                    (thread-id (car-safe row-id))
                    (thread (gethash thread-id codex-ide-agents--threads-by-id)))
          (when (string-match-p regexp
                                (codex-ide-agents--column-value thread column))
            (unless (eq (char-after (line-beginning-position)) ?>)
              (setq count (1+ count)))
            (tabulated-list-put-tag ">")))
        (forward-line 1)))
    (message "Marked %d Codex %s matching %s"
             count (if (= count 1) "session" "sessions") label)))

(defun codex-ide-agents--read-and-mark-column (column label)
  "Read a regexp and mark rows by COLUMN named LABEL."
  (codex-ide-agents--mark-by-column
   column label (read-regexp (format "Mark by %s regexp: " label))))

(defun codex-ide-agents-mark-by-title ()
  "Mark sessions whose full title matches a regexp."
  (interactive)
  (codex-ide-agents--read-and-mark-column 'title "Title"))

(defun codex-ide-agents-mark-by-status ()
  "Mark sessions whose displayed status matches a regexp."
  (interactive)
  (codex-ide-agents--read-and-mark-column 'status "Status"))

(defun codex-ide-agents-mark-by-running-in ()
  "Mark sessions whose Running In value matches a regexp."
  (interactive)
  (codex-ide-agents--read-and-mark-column 'running-in "Running In"))

(defun codex-ide-agents-mark-by-updated ()
  "Mark sessions whose displayed update time matches a regexp."
  (interactive)
  (codex-ide-agents--read-and-mark-column 'updated "Updated"))

(defun codex-ide-agents-mark-by-directory ()
  "Mark sessions whose full displayed directory matches a regexp."
  (interactive)
  (codex-ide-agents--read-and-mark-column 'directory "Directory"))

(defun codex-ide-agents--point-state (position)
  "Return stable row and line state for buffer POSITION."
  (save-excursion
    (goto-char (min (max position (point-min)) (point-max)))
    (list :thread-id (car-safe (tabulated-list-get-id))
          :line (line-number-at-pos)
          :column (current-column))))

(defun codex-ide-agents--point-for-state (state)
  "Return the best current buffer position corresponding to STATE."
  (save-excursion
    (unless (codex-ide-agents--goto-thread-id (plist-get state :thread-id))
      (goto-char (point-min))
      (forward-line (1- (max 1 (or (plist-get state :line) 1)))))
    (move-to-column (or (plist-get state :column) 0))
    (point)))

(defun codex-ide-agents--window-states ()
  "Return visible agents windows with their point and scroll state."
  (mapcar
   (lambda (window)
     (list :window window
           :point (codex-ide-agents--point-state (window-point window))
           :start (codex-ide-agents--point-state (window-start window))))
   (get-buffer-window-list (current-buffer) nil 'visible)))

(defun codex-ide-agents--capture-refresh-state ()
  "Capture interactive state that should survive an agents list refresh."
  (list :point (codex-ide-agents--point-state (point))
        :marks (codex-ide-agents--marks)
        :windows (codex-ide-agents--window-states)))

(defun codex-ide-agents--goto-thread-id (thread-id)
  "Move to the row for THREAD-ID and return non-nil when it exists."
  (when thread-id
    (let (found)
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (when (equal (car-safe (tabulated-list-get-id)) thread-id)
          (setq found t))
        (unless found
          (forward-line 1)))
      found)))

(defun codex-ide-agents--restore-refresh-state (state)
  "Restore agents buffer interaction STATE after a successful refresh."
  (goto-char (codex-ide-agents--point-for-state (plist-get state :point)))
  (codex-ide-agents--restore-marks (plist-get state :marks))
  (dolist (window-state (plist-get state :windows))
    (let ((window (plist-get window-state :window)))
      (when (window-live-p window)
        (set-window-point
         window
         (codex-ide-agents--point-for-state
          (plist-get window-state :point)))
        (set-window-start
         window
         (codex-ide-agents--point-for-state
          (plist-get window-state :start))
         t)))))

(defun codex-ide-agents--refresh-list ()
  "Refresh the agents list while preserving selection, marks, and scrolling."
  (let* ((state (codex-ide-agents--capture-refresh-state))
         ;; Resolve the server request before `tabulated-list-print' changes the
         ;; buffer so a background failure leaves the last good rows intact.
         (entries (if (functionp tabulated-list-entries)
                      (funcall tabulated-list-entries)
                    tabulated-list-entries)))
    (let ((tabulated-list-entries entries))
      (tabulated-list-print t))
    (codex-ide-agents--restore-refresh-state state)))

(defun codex-ide-agents--close-thread (thread)
  "Close THREAD's local Emacs session without deleting its stored thread."
  (codex-ide--close-session (codex-ide-agents--local-session thread)))

(defun codex-ide-agents--active-close-count (threads)
  "Return the number of THREADS whose close may interrupt active work."
  (let ((count 0))
    (dolist (thread threads count)
      (when-let* ((session (codex-ide-agents--thread-session thread))
                  (status (codex-ide--normalize-session-status
                           (codex-ide-session-status session))))
        (when (codex-ide-agents--active-status-p status)
          (setq count (1+ count)))))))

(defun codex-ide-agents--action-label (kind)
  "Return a user-facing action label for KIND."
  (pcase kind
    ('close "Close local")
    ('delete "Permanently delete")
    ('archive "Archive")
    ('unarchive "Unarchive")))

(defun codex-ide-agents--confirm-action (kind threads)
  "Return non-nil when the user confirms KIND for THREADS."
  (let* ((count (length threads))
         (active-count (and (eq kind 'close)
                            (codex-ide-agents--active-close-count threads)))
         (prompt
          (if (= count 1)
              (let ((thread (car threads)))
                (format "%s Codex session %s (%s)"
                        (codex-ide-agents--action-label kind)
                        (codex-ide-agents--title thread)
                        (alist-get 'id thread)))
            (format "%s %d marked Codex sessions"
                    (codex-ide-agents--action-label kind) count))))
    (when (and active-count (> active-count 0))
      (setq prompt
            (concat
             prompt
             (format "; %d active %s will be interrupted"
                     active-count
                     (if (= active-count 1) "session" "sessions")))))
    (when (eq kind 'archive)
      (setq prompt
            (concat prompt "; spawned descendants may also be archived")))
    (yes-or-no-p (concat prompt "? "))))

(defun codex-ide-agents--confirm-actions (actions)
  "Return non-nil when the user confirms marked ACTIONS."
  (let ((kinds (delete-dups (mapcar #'car actions))))
    (if (= (length kinds) 1)
        (codex-ide-agents--confirm-action
         (car kinds) (mapcar #'cdr actions))
      (let ((close-count 0)
            (delete-count 0)
            (archive-count 0)
            (unarchive-count 0)
            close-threads)
        (dolist (action actions)
          (pcase (car action)
            ('close
             (setq close-count (1+ close-count))
             (push (cdr action) close-threads))
            ('delete (setq delete-count (1+ delete-count)))
            ('archive (setq archive-count (1+ archive-count)))
            ('unarchive (setq unarchive-count (1+ unarchive-count)))))
        (let* ((summary
                (string-join
                 (delq nil
                       (list (when (> close-count 0)
                               (format "close %d local" close-count))
                             (when (> delete-count 0)
                               (format "permanently delete %d" delete-count))
                             (when (> archive-count 0)
                               (format "archive %d" archive-count))
                             (when (> unarchive-count 0)
                               (format "unarchive %d" unarchive-count))))
                 " and "))
               (active-count
                (codex-ide-agents--active-close-count close-threads))
               (prompt
                (format "%s%s Codex sessions"
                        (upcase (substring summary 0 1))
                        (substring summary 1))))
          (when (> active-count 0)
            (setq prompt
                  (concat
                   prompt
                   (format "; %d active %s will be interrupted"
                           active-count
                           (if (= active-count 1) "session" "sessions")))))
          (when (> archive-count 0)
            (setq prompt
                  (concat
                   prompt "; spawned descendants may also be archived")))
          (yes-or-no-p (concat prompt "? ")))))))

(defun codex-ide-agents--execute-actions (actions)
  "Confirm and execute ACTIONS, clearing marks only for successful rows."
  (codex-ide-agents--with-interaction
    (when (codex-ide-agents--confirm-actions actions)
      (let (succeeded failures query-session)
        (dolist (action actions)
          (let* ((kind (car action))
                 (thread (cdr action))
                 (thread-id (alist-get 'id thread)))
              (condition-case err
                  (progn
                    (pcase kind
                      ('close (codex-ide-agents--close-thread thread))
                      ('delete (codex-ide-delete-session-thread thread-id t))
                      ('archive
                       (when (alist-get 'archived thread)
                         (user-error "Session is already archived"))
                       (unless query-session
                         (codex-ide--prepare-session-operations)
                         (setq query-session
                               (codex-ide--ensure-query-session-for-thread-selection
                                codex-ide-agents--query-directory)))
                       (codex-ide--set-thread-archived
                        query-session thread-id t))
                      ('unarchive
                       (unless (alist-get 'archived thread)
                         (user-error "Session is not archived"))
                       (unless query-session
                         (codex-ide--prepare-session-operations)
                         (setq query-session
                               (codex-ide--ensure-query-session-for-thread-selection
                                codex-ide-agents--query-directory)))
                       (codex-ide--set-thread-archived
                        query-session thread-id nil)))
                    (push thread-id succeeded))
                (error
                 (push
                  (cons thread-id
                        (list 'error
                              (format "%s failed: %s"
                                      (capitalize (symbol-name kind))
                                      (error-message-string err))))
                  failures)))))
        (when succeeded
          (codex-ide-agents--clear-thread-marks succeeded)
          (codex-ide-agents-refresh))
        (when failures
          (codex-ide-agents--show-operation-failures
           "marked operation"
           (nreverse failures)
           (concat
            "Any failed marked rows remain marked. Refresh with g and retry. "
            "A close "
            "requires a session running in this Emacs. If an app-server "
            "method is unavailable, upgrade Codex.")))))))

(defun codex-ide-agents--execute-current-action (kind)
  "Execute KIND for generic marks, or for the session at point.
Mnemonic marks are not selected by this command."
  (let ((actions (codex-ide-agents--marked-actions
                  (codex-ide-agents--marks) kind)))
    (codex-ide-agents--execute-actions
     (or actions
         (list (cons kind (codex-ide-agents--thread-at-point)))))))

(defun codex-ide-agents-execute-marks ()
  "Execute every special mark, ignoring generic `>' marks."
  (interactive)
  (let* ((marks (codex-ide-agents--marks))
         (actions (codex-ide-agents--marked-actions marks)))
    (unless marks
      (user-error "No Codex agent sessions marked"))
    (unless actions
      (user-error "No D, K, A, or R marks to execute"))
    (codex-ide-agents--execute-actions actions)))

(defun codex-ide-agents-close ()
  "Confirm and close generically marked sessions, or the session at point."
  (interactive)
  (codex-ide-agents--execute-current-action 'close))

(defun codex-ide-agents-delete ()
  "Confirm and delete generically marked sessions, or the session at point."
  (interactive)
  (codex-ide-agents--execute-current-action 'delete))

(defun codex-ide-agents-archive ()
  "Confirm and archive generically marked sessions, or the session at point."
  (interactive)
  (codex-ide-agents--execute-current-action 'archive))

(defun codex-ide-agents-unarchive ()
  "Confirm and restore generically marked sessions, or the session at point."
  (interactive)
  (codex-ide-agents--execute-current-action 'unarchive))

(defun codex-ide-agents-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the global Codex agents list."
  (interactive)
  (codex-ide-agents--refresh-list)
  (setq codex-ide-agents--last-refresh-error nil)
  (force-mode-line-update))

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
