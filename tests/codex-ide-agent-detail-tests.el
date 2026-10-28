;;; codex-ide-agent-detail-tests.el --- Tests for Codex agent detail -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the global agent detail view and relationship navigation.

;;; Code:

(require 'ert)
(require 'codex-ide-agent-detail)
(require 'codex-ide-test-fixtures)

(defun codex-ide-agent-detail-test--thread
    (id title &optional parent-id role)
  "Build a test thread with ID, TITLE, PARENT-ID, and ROLE."
  `((id . ,id)
    (sessionId . "session-tree")
    (parentThreadId . ,parent-id)
    (agentNickname . ,(and role (concat role "-agent")))
    (agentRole . ,role)
    (cwd . "/tmp/project")
    (name . ,title)
    (preview . ,(concat title " preview"))
    (model . "gpt-test")
    (reasoningEffort . "high")
    (source . ,(if parent-id '((subAgent . "review")) "appServer"))
    (status . ((type . "notLoaded")))
    (createdAt . 10)
    (updatedAt . 20)))

(ert-deftest codex-ide-agent-detail-renders-overview-and-relationships ()
  (let* ((parent (codex-ide-agent-detail-test--thread
                  "parent" "Parent task"))
         (current (codex-ide-agent-detail-test--thread
                   "current" "Current task" "parent" "worker"))
         (child (codex-ide-agent-detail-test--thread
                 "child" "Child task" "current" "explorer"))
         (threads `(("parent" . ,parent)
                    ("current" . ,current)))
         (visited nil))
    (cl-letf (((symbol-function 'codex-ide--prepare-session-operations) #'ignore)
              ((symbol-function 'codex-ide--ensure-query-session-for-thread-selection)
               (lambda (directory)
                 (should (equal directory "/tmp/query/"))
                 'query-session))
              ((symbol-function 'codex-ide--read-thread)
               (lambda (session thread-id &optional _include-turns)
                 (should (eq session 'query-session))
                 `((thread . ,(cdr (assoc thread-id threads))))))
              ((symbol-function 'codex-ide--list-child-threads)
               (lambda (session thread-id &rest _)
                 (should (eq session 'query-session))
                 (if (equal thread-id "current") (list child) nil)))
              ((symbol-function 'codex-ide--format-thread-updated-at)
               (lambda (value) (format "time-%s" value)))
              ((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _)
                 (setq visited buffer))))
      (codex-ide-agent-detail-show current "/tmp/query/")
      (should (buffer-live-p visited))
      (with-current-buffer visited
        (should (derived-mode-p 'codex-ide-agent-detail-mode))
        (should (string-match-p "Current task" (buffer-string)))
        (should (string-match-p "Thread ID: current" (buffer-string)))
        (should (string-match-p "Session ID: session-tree" (buffer-string)))
        (should (string-match-p "Role: worker" (buffer-string)))
        (should (string-match-p "Model: gpt-test" (buffer-string)))
        (should (string-match-p "Parent: Parent task" (buffer-string)))
        (should (string-match-p "Child task  explorer" (buffer-string)))))))

(ert-deftest codex-ide-agent-detail-child-button-navigates-in-place ()
  (let* ((root (codex-ide-agent-detail-test--thread "root" "Root task"))
         (child (codex-ide-agent-detail-test--thread
                 "child" "Child task" "root" "worker"))
         (threads `(("root" . ,root) ("child" . ,child))))
    (with-temp-buffer
      (codex-ide-agent-detail-mode)
      (setq-local codex-ide-agent-detail--query-directory "/tmp/query/"
                  codex-ide-agent-detail--thread-id "root")
      (cl-letf (((symbol-function 'codex-ide--prepare-session-operations) #'ignore)
                ((symbol-function 'codex-ide--ensure-query-session-for-thread-selection)
                 (lambda (&rest _) 'query-session))
                ((symbol-function 'codex-ide--read-thread)
                 (lambda (_session thread-id &optional _include-turns)
                   `((thread . ,(cdr (assoc thread-id threads))))))
                ((symbol-function 'codex-ide--list-child-threads)
                 (lambda (_session thread-id &rest _)
                   (if (equal thread-id "root") (list child) nil))))
        (codex-ide-agent-detail-refresh)
        (goto-char (point-min))
        (search-forward "Child task")
        (backward-char 1)
        (push-button (point))
        (should (equal codex-ide-agent-detail--thread-id "child"))
        (should (string-match-p "Child task" (buffer-string)))
        (should (string-match-p "Parent: Root task" (buffer-string)))))))

(ert-deftest codex-ide-agent-detail-open-session-resumes-current-thread ()
  (let ((thread (codex-ide-agent-detail-test--thread "open-me" "Open task"))
        opened)
    (with-temp-buffer
      (codex-ide-agent-detail-mode)
      (setq-local codex-ide-agent-detail--thread thread)
      (cl-letf (((symbol-function 'codex-ide--prepare-session-operations) #'ignore)
                ((symbol-function 'codex-ide--show-or-resume-thread)
                 (lambda (thread-id directory)
                   (setq opened (cons thread-id directory)))))
        (codex-ide-agent-detail-open-session))
    (should (equal opened '("open-me" . "/tmp/project"))))))

(provide 'codex-ide-agent-detail-tests)

;;; codex-ide-agent-detail-tests.el ends here
