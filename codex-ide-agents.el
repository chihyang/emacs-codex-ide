;;; codex-ide-agents.el --- Browse Codex agent sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Duncan Gillis

;;; Commentary:

;; A flat, global `tabulated-list-mode' view of sessions known to the shared
;; Codex app-server daemon.  Unlike `codex-ide-status', this view deliberately
;; does not filter or group sessions by working directory.

;;; Code:

(require 'subr-x)
(require 'seq)
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

(set-keymap-parent codex-ide-agents-mode-map codex-ide-session-list-mode-map)
(define-key codex-ide-agents-mode-map (kbd "i") #'codex-ide-agents-detail)
(define-key codex-ide-agents-mode-map (kbd "c") #'codex-ide-agents-create)
(define-key codex-ide-agents-mode-map (kbd "r") #'codex-ide-agents-rename)
(define-key codex-ide-agents-mode-map (kbd "k") #'codex-ide-agents-mark-close)
(define-key codex-ide-agents-mode-map (kbd "d") #'codex-ide-agents-mark-delete)
(define-key codex-ide-agents-mode-map (kbd "u") #'codex-ide-agents-unmark)
(define-key codex-ide-agents-mode-map (kbd "U") #'codex-ide-agents-unmark-all)
(define-key codex-ide-agents-mode-map (kbd "X") #'codex-ide-agents-execute-marked)
(define-key codex-ide-agents-mode-map (kbd "K") #'codex-ide-agents-close)
(define-key codex-ide-agents-mode-map (kbd "D") #'codex-ide-agents-delete)
(define-key codex-ide-agents-mode-map (kbd "A")
            #'codex-ide-agents-toggle-auto-refresh)

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

(defun codex-ide-agents-mark-delete ()
  "Mark the Codex session at point for deletion and advance one row."
  (interactive)
  (codex-ide-agents--thread-at-point)
  (tabulated-list-put-tag "D" t))

(defun codex-ide-agents-mark-close ()
  "Mark the local Codex session at point for closing and advance one row."
  (interactive)
  (codex-ide-agents--local-session (codex-ide-agents--thread-at-point))
  (tabulated-list-put-tag "K" t))

(defun codex-ide-agents-unmark ()
  "Remove the operation mark from the Codex session at point and advance."
  (interactive)
  (codex-ide-agents--thread-at-point)
  (tabulated-list-put-tag " " t))

(defun codex-ide-agents-unmark-all ()
  "Remove every close or deletion mark from the current agents list."
  (interactive)
  (let ((count 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (and (tabulated-list-get-id)
                   (memq (char-after (line-beginning-position)) '(?D ?K)))
          (tabulated-list-put-tag " ")
          (setq count (1+ count)))
        (forward-line 1)))
    (message "Cleared %d operation %s"
             count
             (if (= count 1) "mark" "marks"))))

(defun codex-ide-agents--marked-actions ()
  "Return marked actions in the current agents buffer.
Each element is an (ACTION . THREAD) pair, where ACTION is `close' or
`delete'."
  (let (actions)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((action
                     (pcase (char-after (line-beginning-position))
                       (?D 'delete)
                       (?K 'close)))
                    (row-id (tabulated-list-get-id))
                    (thread-id (car-safe row-id))
                    (thread (gethash thread-id codex-ide-agents--threads-by-id)))
          (push (cons action thread) actions))
        (forward-line 1)))
    (nreverse actions)))

(defun codex-ide-agents--marked-threads ()
  "Return threads marked for deletion in the current agents buffer."
  (let (threads)
    (dolist (action (codex-ide-agents--marked-actions))
      (when (eq (car action) 'delete)
        (push (cdr action) threads)))
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
  "Return close and deletion marks keyed by thread id in the current list."
  (let (marks)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((mark (and (memq (char-after (line-beginning-position))
                                      '(?D ?K))
                                (char-after (line-beginning-position))))
                    (row-id (tabulated-list-get-id))
                    (thread-id (car-safe row-id)))
          (push (cons thread-id mark) marks))
        (forward-line 1)))
    (nreverse marks)))

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

(defun codex-ide-agents--active-close-count (actions)
  "Return the number of close ACTIONS that may interrupt active work."
  (let ((count 0))
    (dolist (action actions count)
      (when (and (eq (car action) 'close)
                 (when-let* ((session
                              (codex-ide-agents--thread-session (cdr action))))
                   (codex-ide-agents--active-status-p
                    (codex-ide--normalize-session-status
                     (codex-ide-session-status session)))))
        (setq count (1+ count))))))

(defun codex-ide-agents--confirm-actions (actions)
  "Return non-nil when the user confirms marked ACTIONS."
  (let* ((close-count (seq-count (lambda (action)
                                   (eq (car action) 'close))
                                 actions))
         (delete-count (- (length actions) close-count))
         (active-count (codex-ide-agents--active-close-count actions))
         (prompt
          (cond
           ((= (length actions) 1)
            (let* ((action (car actions))
                   (thread (cdr action)))
              (if (eq (car action) 'close)
                  (format "Close local Codex session %s (%s)"
                          (codex-ide-agents--title thread)
                          (alist-get 'id thread))
                (format "Permanently delete Codex session %s (%s)"
                        (codex-ide-agents--title thread)
                        (alist-get 'id thread)))))
           ((and (> close-count 0) (> delete-count 0))
            (format "Close %d local and permanently delete %d Codex sessions"
                    close-count delete-count))
           ((> close-count 0)
            (format "Close %d marked local Codex sessions" close-count))
           (t
            (format "Permanently delete %d marked Codex sessions"
                    delete-count)))))
    (when (> active-count 0)
      (setq prompt
            (concat
             prompt
             (format "; %d active %s will be interrupted"
                     active-count
                     (if (= active-count 1) "session" "sessions")))))
    (yes-or-no-p (concat prompt "? "))))

(defun codex-ide-agents--execute-actions (actions)
  "Confirm and execute marked ACTIONS, then refresh the agents list."
  (codex-ide-agents--with-interaction
    (when (codex-ide-agents--confirm-actions actions)
      (let (succeeded failures failed-marks)
        (dolist (action actions)
          (let* ((kind (car action))
                 (thread (cdr action))
                 (thread-id (alist-get 'id thread)))
            (condition-case err
                (progn
                  (pcase kind
                    ('close (codex-ide-agents--close-thread thread))
                    ('delete (codex-ide-delete-session-thread thread-id t)))
                  (setq succeeded t))
              (error
               (push
                (cons thread-id
                      (list 'error
                            (format "%s failed: %s"
                                    (capitalize (symbol-name kind))
                                    (error-message-string err))))
                failures)
               (push (cons thread-id (if (eq kind 'close) ?K ?D))
                     failed-marks)))))
        (when succeeded
          (codex-ide-agents-refresh))
        (codex-ide-agents--restore-marks failed-marks)
        (when failures
          (codex-ide-agents--show-operation-failures
           "marked operation"
           (nreverse failures)
           (concat
            "Failed rows remain marked. A close requires a session running in "
            "this Emacs. If thread/delete is unavailable, upgrade Codex or "
            "manage that session with a compatible client.")))))))

(defun codex-ide-agents-execute-marked ()
  "Confirm and execute every session operation marked with `d' or `k'."
  (interactive)
  (let ((actions (codex-ide-agents--marked-actions)))
    (unless actions
      (user-error "No Codex agent sessions marked for an operation"))
    (codex-ide-agents--execute-actions actions)))

(defalias 'codex-ide-agents-execute-deletions
  #'codex-ide-agents-execute-marked)

(defun codex-ide-agents-close ()
  "Confirm and close the local Codex session at point."
  (interactive)
  (let ((thread (codex-ide-agents--thread-at-point)))
    (codex-ide-agents--local-session thread)
    (codex-ide-agents--execute-actions (list (cons 'close thread)))))

(defun codex-ide-agents--delete-threads (threads)
  "Confirm and permanently delete THREADS, then refresh the agents list."
  (codex-ide-agents--with-interaction
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
            (codex-ide-agents--show-operation-failures
             "deletion"
             (nreverse failures)
             (concat
              "Refresh the agents list with g and retry. If thread/delete is "
              "unavailable, upgrade Codex or manage that session with a "
              "compatible client."))))))))

(defun codex-ide-agents-delete ()
  "Confirm and permanently delete the Codex session at point."
  (interactive)
  (codex-ide-agents--delete-threads
   (list (codex-ide-agents--thread-at-point))))

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
