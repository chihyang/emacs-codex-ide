;;; codex-ide-agent-detail.el --- Inspect Codex agent sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Duncan Gillis

;;; Commentary:

;; A focused detail view for sessions selected from `codex-ide-agents'.  The
;; view reads current thread metadata and exposes parent and direct subagent
;; relationships as navigable buttons.

;;; Code:

(require 'button)
(require 'subr-x)
(require 'codex-ide)
(require 'codex-ide-session-list)

(defvar-local codex-ide-agent-detail--query-directory nil
  "Directory used to host the detail view's query connection.")

(defvar-local codex-ide-agent-detail--thread-id nil
  "Thread id currently displayed in this detail buffer.")

(defvar-local codex-ide-agent-detail--thread nil
  "Current thread metadata displayed in this detail buffer.")

(defvar-local codex-ide-agent-detail--parent nil
  "Parent metadata for the current thread, when it has a parent.")

(defvar-local codex-ide-agent-detail--children nil
  "Direct child thread metadata for the current thread.")

(defvar-local codex-ide-agent-detail--seed-thread nil
  "List metadata used until the first detail read completes.")

(defvar codex-ide-agent-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap for `codex-ide-agent-detail-mode'.")

(define-key codex-ide-agent-detail-mode-map (kbd "g")
            #'codex-ide-agent-detail-refresh)
(define-key codex-ide-agent-detail-mode-map (kbd "o")
            #'codex-ide-agent-detail-open-session)
(define-key codex-ide-agent-detail-mode-map (kbd "^")
            #'codex-ide-agent-detail-parent)

(define-derived-mode codex-ide-agent-detail-mode special-mode "Codex-Agent-Detail"
  "Mode for inspecting one Codex agent session and its relationships."
  (setq-local revert-buffer-function #'codex-ide-agent-detail-refresh))

(defun codex-ide-agent-detail--response-thread (response)
  "Return thread metadata from a `thread/read' RESPONSE."
  (or (alist-get 'thread response) response))

(defun codex-ide-agent-detail--read-thread (session thread-id)
  "Read THREAD-ID metadata using query SESSION."
  (let ((thread
         (codex-ide-agent-detail--response-thread
          (codex-ide--read-thread session thread-id nil))))
    (unless (and (listp thread)
                 (equal (alist-get 'id thread) thread-id))
      (error "Codex returned no metadata for thread %s" thread-id))
    thread))

(defun codex-ide-agent-detail--active-status-p (status)
  "Return non-nil when normalized STATUS represents active work."
  (member status '("running" "submitted" "starting" "interrupting" "approval")))

(defun codex-ide-agent-detail--session (thread)
  "Return this Emacs instance's live session for THREAD, if any."
  (when-let* ((thread-id (alist-get 'id thread)))
    (codex-ide--session-for-thread-id-any thread-id)))

(defun codex-ide-agent-detail--status (thread)
  "Return THREAD's normalized status, accounting for a live Emacs session."
  (let* ((session (codex-ide-agent-detail--session thread))
         (server-status
          (codex-ide--normalize-session-status (alist-get 'status thread)))
         (local-status
          (and session
               (codex-ide--normalize-session-status
                (codex-ide-session-status session))))
         (status
          (cond
           ((equal server-status "running")
            (if (codex-ide-agent-detail--active-status-p local-status)
                local-status
              server-status))
           (local-status local-status)
           (server-status server-status)
           (t "stored"))))
    (if (equal (downcase status) "notloaded") "stored" status)))

(defun codex-ide-agent-detail--title (thread)
  "Return THREAD's one-line display title."
  (let ((title
         (codex-ide--thread-choice-preview
          (or (alist-get 'name thread)
              (alist-get 'preview thread)
              ""))))
    (setq title (replace-regexp-in-string "[\n\r]+" "↵" title))
    (if (string-empty-p title) "Untitled" title)))

(defun codex-ide-agent-detail--value-text (value)
  "Return a human-readable scalar representation of VALUE."
  (cond
   ((eq value t) "Yes")
   ((memq value '(nil :json-false)) (if value "No" ""))
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   ((numberp value) (number-to-string value))
   (t (format "%s" value))))

(defun codex-ide-agent-detail--source-label (source)
  "Return a compact display label for thread SOURCE."
  (cond
   ((or (stringp source) (symbolp source))
    (capitalize (codex-ide-agent-detail--value-text source)))
   ((and (listp source) (assq 'subAgent source)) "Subagent")
   ((listp source)
    (capitalize
     (codex-ide-agent-detail--value-text (caar source))))
   (t "")))

(defun codex-ide-agent-detail--insert-field (label value &optional face)
  "Insert metadata field LABEL with VALUE, optionally using FACE for VALUE."
  (let ((text (codex-ide-agent-detail--value-text value)))
    (unless (string-empty-p text)
      (insert (propertize (concat label ": ") 'face 'bold)
              (propertize text 'face (or face 'default))
              "\n"))))

(defun codex-ide-agent-detail--insert-thread-button (thread)
  "Insert a button that navigates to THREAD in this detail buffer."
  (let ((thread-id (alist-get 'id thread)))
    (insert-text-button
     (codex-ide-agent-detail--title thread)
     'follow-link t
     'help-echo (format "Inspect Codex thread %s" thread-id)
     'action (lambda (_button)
               (codex-ide-agent-detail--show-thread thread-id)))))

(defun codex-ide-agent-detail--insert-overview (thread)
  "Insert the overview fields for THREAD."
  (let* ((session (codex-ide-agent-detail--session thread))
         (status (codex-ide-agent-detail--status thread))
         (git-info (alist-get 'gitInfo thread)))
    (codex-ide-agent-detail--insert-field
     "Status" (codex-ide-renderer-status-label status)
     'codex-ide-session-list-status-face)
    (codex-ide-agent-detail--insert-field
     "Running In"
     (cond
      (session "Emacs")
      ((codex-ide-agent-detail--active-status-p status) "External")
      (t "")))
    (codex-ide-agent-detail--insert-field "Thread ID" (alist-get 'id thread)
                                          'codex-ide-session-list-id-face)
    (codex-ide-agent-detail--insert-field "Session ID" (alist-get 'sessionId thread)
                                          'codex-ide-session-list-id-face)
    (codex-ide-agent-detail--insert-field "Agent" (alist-get 'agentNickname thread))
    (codex-ide-agent-detail--insert-field "Role" (alist-get 'agentRole thread))
    (codex-ide-agent-detail--insert-field "Model" (alist-get 'model thread))
    (codex-ide-agent-detail--insert-field
     "Reasoning" (alist-get 'reasoningEffort thread))
    (codex-ide-agent-detail--insert-field
     "Provider" (alist-get 'modelProvider thread))
    (codex-ide-agent-detail--insert-field
     "Source" (codex-ide-agent-detail--source-label (alist-get 'source thread)))
    (codex-ide-agent-detail--insert-field "Originator" (alist-get 'originator thread))
    (codex-ide-agent-detail--insert-field "CLI Version" (alist-get 'cliVersion thread))
    (codex-ide-agent-detail--insert-field
     "Created" (codex-ide--format-thread-updated-at (alist-get 'createdAt thread)))
    (codex-ide-agent-detail--insert-field
     "Updated" (codex-ide--format-thread-updated-at (alist-get 'updatedAt thread)))
    (codex-ide-agent-detail--insert-field
     "Directory"
     (when-let* ((directory (alist-get 'cwd thread)))
       (abbreviate-file-name directory)))
    (when (listp git-info)
      (codex-ide-agent-detail--insert-field "Git Branch" (alist-get 'branch git-info))
      (codex-ide-agent-detail--insert-field "Git Commit" (alist-get 'sha git-info))
      (codex-ide-agent-detail--insert-field
       "Git Repository" (alist-get 'repositoryUrl git-info)))))

(defun codex-ide-agent-detail--insert-relationships ()
  "Insert parent and direct subagent navigation for the current thread."
  (insert (propertize "Relationships\n" 'face 'bold))
  (if codex-ide-agent-detail--parent
      (progn
        (insert "Parent: ")
        (codex-ide-agent-detail--insert-thread-button
         codex-ide-agent-detail--parent)
        (insert "\n"))
    (insert (propertize "Parent: None\n" 'face 'shadow)))
  (if codex-ide-agent-detail--children
      (progn
        (insert "Subagents:\n")
        (dolist (child codex-ide-agent-detail--children)
          (insert "  • ")
          (codex-ide-agent-detail--insert-thread-button child)
          (when-let* ((role (alist-get 'agentRole child)))
            (insert (propertize (format "  %s" role) 'face 'shadow)))
          (insert (propertize
                   (format "  %s"
                           (codex-ide-renderer-status-label
                            (codex-ide-agent-detail--status child)))
                   'face 'codex-ide-session-list-status-face)
                  "\n")))
    (insert (propertize "Subagents: None\n" 'face 'shadow))))

(defun codex-ide-agent-detail--render ()
  "Render the current agent detail state."
  (let ((inhibit-read-only t)
        (thread codex-ide-agent-detail--thread))
    (erase-buffer)
    (insert (propertize (codex-ide-agent-detail--title thread)
                        'face '(:height 1.3 :weight bold))
            "\n\n")
    (insert-text-button
     "Open session"
     'follow-link t
     'help-echo "Display or resume this Codex session"
     'action (lambda (_button) (codex-ide-agent-detail-open-session)))
    (insert "    "
            (propertize "g refresh   ^ parent   q quit" 'face 'shadow)
            "\n\n")
    (insert (propertize "Overview\n" 'face 'bold))
    (codex-ide-agent-detail--insert-overview thread)
    (insert "\n")
    (codex-ide-agent-detail--insert-relationships)
    (when-let* ((preview (alist-get 'preview thread))
                ((not (string-empty-p preview))))
      (insert "\n" (propertize "Preview\n" 'face 'bold) preview "\n"))
    (goto-char (point-min))))

(defun codex-ide-agent-detail--load ()
  "Load metadata and relationships for the current thread id."
  (unless codex-ide-agent-detail--query-directory
    (error "No query directory is associated with this detail buffer"))
  (codex-ide--prepare-session-operations)
  (let* ((session
          (codex-ide--ensure-query-session-for-thread-selection
           codex-ide-agent-detail--query-directory))
         (thread
          (condition-case err
              (codex-ide-agent-detail--read-thread
               session codex-ide-agent-detail--thread-id)
            (error
             (if (and codex-ide-agent-detail--seed-thread
                      (equal (alist-get 'id codex-ide-agent-detail--seed-thread)
                             codex-ide-agent-detail--thread-id))
                 codex-ide-agent-detail--seed-thread
               (signal (car err) (cdr err))))))
         (parent-id (alist-get 'parentThreadId thread)))
    (setq codex-ide-agent-detail--thread thread
          codex-ide-agent-detail--parent
          (and (stringp parent-id)
               (not (string-empty-p parent-id))
               (codex-ide-agent-detail--read-thread session parent-id))
          codex-ide-agent-detail--children
          (codex-ide--list-child-threads session (alist-get 'id thread))
          codex-ide-agent-detail--seed-thread nil)
    (when-let* ((directory (alist-get 'cwd thread)))
      (setq default-directory (file-name-as-directory directory)))))

(defun codex-ide-agent-detail--show-thread (thread-id)
  "Display THREAD-ID in the current agent detail buffer."
  (unless (and (stringp thread-id) (not (string-empty-p thread-id)))
    (user-error "No related Codex thread to inspect"))
  (setq codex-ide-agent-detail--thread-id thread-id
        codex-ide-agent-detail--seed-thread nil)
  (codex-ide-agent-detail-refresh))

(defun codex-ide-agent-detail-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current Codex agent detail view."
  (interactive)
  (codex-ide-agent-detail--load)
  (codex-ide-agent-detail--render))

(defun codex-ide-agent-detail-parent ()
  "Navigate to the current thread's parent."
  (interactive)
  (unless codex-ide-agent-detail--parent
    (user-error "This Codex thread has no parent"))
  (codex-ide-agent-detail--show-thread
   (alist-get 'id codex-ide-agent-detail--parent)))

(defun codex-ide-agent-detail-open-session ()
  "Display or resume the Codex session described by this detail view."
  (interactive)
  (let ((thread-id (alist-get 'id codex-ide-agent-detail--thread))
        (directory (alist-get 'cwd codex-ide-agent-detail--thread)))
    (unless (and (stringp thread-id) (stringp directory))
      (user-error "This Codex session has no resumable thread or directory"))
    (codex-ide--prepare-session-operations)
    (codex-ide--show-or-resume-thread thread-id directory)))

(defun codex-ide-agent-detail-show (thread query-directory)
  "Show detail for THREAD using a query connection in QUERY-DIRECTORY."
  (let ((thread-id (alist-get 'id thread)))
    (unless (and (stringp thread-id) (not (string-empty-p thread-id)))
      (user-error "This Codex session has no thread id"))
    (let ((buffer (get-buffer-create "*Codex Agent Details*")))
      (with-current-buffer buffer
        (codex-ide-agent-detail-mode)
        (setq-local codex-ide-agent-detail--query-directory query-directory
                    codex-ide-agent-detail--thread-id thread-id
                    codex-ide-agent-detail--seed-thread thread)
        (codex-ide-agent-detail-refresh))
      (pop-to-buffer buffer))))

(provide 'codex-ide-agent-detail)

;;; codex-ide-agent-detail.el ends here
