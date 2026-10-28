;;; codex-ide-agents-tests.el --- Tests for codex-ide agents list -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the global tabulated session browser.

;;; Code:

(require 'ert)
(require 'codex-ide-test-fixtures)
(require 'codex-ide-agents)

(defun codex-ide-agents-test--thread
    (id directory title status updated-at)
  "Build test thread ID in DIRECTORY with TITLE, STATUS, and UPDATED-AT."
  `((id . ,id)
    (cwd . ,directory)
    (name . ,title)
    (preview . ,title)
    (status . ((type . ,status)))
    (updatedAt . ,updated-at)))

(ert-deftest codex-ide-agents-renders-flat-sessions-across-directories ()
  (let* ((root-dir (codex-ide-test--make-temp-project))
         (project-a (expand-file-name "alpha" root-dir))
         (project-b (expand-file-name "beta" root-dir))
         (threads
          (list
           (codex-ide-agents-test--thread
            "thread-a" project-a "First task" "notLoaded" 20)
           (codex-ide-agents-test--thread
            "thread-b" project-b "Second task" "active" 10))))
    (make-directory project-a t)
    (make-directory project-b t)
    (codex-ide-test-with-fixture root-dir
      (cl-letf (((symbol-function 'codex-ide--prepare-session-operations)
                 #'ignore)
                ((symbol-function 'codex-ide--ensure-query-session-for-thread-selection)
                 (lambda (_directory) 'query-session))
                ((symbol-function 'codex-ide--list-threads-across-directories)
                 (lambda (session &rest _)
                   (should (eq session 'query-session))
                   threads))
                ((symbol-function 'codex-ide--format-thread-updated-at)
                 (lambda (value) (format "updated-%s" value)))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _) buffer)))
        (codex-ide-agents)
        (with-current-buffer "*Codex Agents*"
          (should (derived-mode-p 'codex-ide-agents-mode))
          (should
           (equal (mapcar #'car (append tabulated-list-format nil))
                  '("Session" "Status" "Running In" "Updated" "Directory")))
          (should (= (nth 1 (aref tabulated-list-format 0)) 15))
          (should (eq (nth 2 (aref tabulated-list-format 3))
                      #'codex-ide-agents--updated-less-p))
          (should (string-match-p "First task" (buffer-string)))
          (should (string-match-p "Second task" (buffer-string)))
          (should (string-match-p "Stored" (buffer-string)))
          (should (string-match-p "External" (buffer-string)))
          (let ((entries (funcall tabulated-list-entries)))
            (should
             (equal
              (mapcar
               (lambda (entry)
                 (substring-no-properties (aref (cadr entry) 4)))
               entries)
              (list project-a project-b))))
          (should-not (string-match-p "Thread ID" (buffer-string))))))))

(ert-deftest codex-ide-agents-running-in-shows-associated-emacs-buffer ()
  (let* ((project-dir (codex-ide-test--make-temp-project))
         (recorded-dir (expand-file-name "recorded-elsewhere" project-dir)))
    (make-directory recorded-dir t)
    (codex-ide-test-with-fixture project-dir
      (codex-ide-test-with-fake-processes
        (let* ((session (codex-ide--create-process-session))
               (thread
                (codex-ide-agents-test--thread
                 "thread-local" recorded-dir "Local task" "notLoaded" 20)))
          (setf (codex-ide-session-thread-id session) "thread-local"
                (codex-ide-session-status session) "idle")
          (let ((cells (cadr (codex-ide-agents--entry thread))))
            (should (equal (substring-no-properties (aref cells 1)) "Idle"))
            (should (equal (substring-no-properties (aref cells 2)) "Emacs")))
          (setf (codex-ide-session-status session) "running")
          (setcdr (assq 'status thread) '((type . "active")))
          (let ((cells (cadr (codex-ide-agents--entry thread))))
            (should (equal (substring-no-properties (aref cells 2)) "Emacs")))
          (setf (codex-ide-session-thread-id session) "different-thread")
          (let ((cells (cadr (codex-ide-agents--entry thread))))
            (should (equal (substring-no-properties (aref cells 2))
                           "External"))))))))

(ert-deftest codex-ide-agents-return-resumes-row-thread-in-its-directory ()
  (let* ((root-dir (codex-ide-test--make-temp-project))
         (project-dir (expand-file-name "project" root-dir))
         (thread
          (codex-ide-agents-test--thread
           "thread-visit" project-dir "Visit me" "notLoaded" 20))
         (visited nil))
    (make-directory project-dir t)
    (codex-ide-test-with-fixture root-dir
      (cl-letf (((symbol-function 'codex-ide--prepare-session-operations)
                 #'ignore)
                ((symbol-function 'codex-ide--ensure-query-session-for-thread-selection)
                 (lambda (_directory) 'query-session))
                ((symbol-function 'codex-ide--list-threads-across-directories)
                 (lambda (&rest _) (list thread)))
                ((symbol-function 'codex-ide--show-or-resume-thread)
                 (lambda (thread-id directory)
                   (setq visited (cons thread-id directory))))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _) buffer)))
        (codex-ide-agents)
        (with-current-buffer "*Codex Agents*"
          (goto-char (point-min))
          (search-forward "Visit me")
          (beginning-of-line)
          (call-interactively
           #'codex-ide-session-list-display-session-at-point))
        (should (equal visited (cons "thread-visit" project-dir)))))))

(ert-deftest codex-ide-agents-inherits-list-navigation-bindings ()
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "RET"))
              #'codex-ide-session-list-display-session-at-point))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "M-<return>"))
              #'codex-ide-session-list-display-session-at-point-other-window))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "l"))
              #'codex-ide-agents-refresh)))

(ert-deftest codex-ide-agents-uses-width-stable-truncation-ellipsis ()
  (with-temp-buffer
    (codex-ide-agents-mode)
    (should (equal truncate-string-ellipsis "..."))
    (let ((truncated
           (truncate-string-to-width (make-string 60 ?x) 15 nil nil t t)))
      (should (equal (get-text-property (1- (length truncated))
                                        'display
                                        truncated)
                     "...")))))

(ert-deftest codex-ide-agents-sorts-updated-by-raw-timestamp ()
  (let ((codex-ide-agents--threads-by-id (make-hash-table :test #'equal))
        (older (codex-ide-agents-test--thread
                "older" "/tmp/older" "Older" "notLoaded" 10))
        (newer (codex-ide-agents-test--thread
                "newer" "/tmp/newer" "Newer" "notLoaded" 20)))
    (puthash "older" older codex-ide-agents--threads-by-id)
    (puthash "newer" newer codex-ide-agents--threads-by-id)
    (let ((older-entry (codex-ide-agents--entry older))
          (newer-entry (codex-ide-agents--entry newer)))
      (should (codex-ide-agents--updated-less-p older-entry newer-entry))
      (should-not (codex-ide-agents--updated-less-p newer-entry older-entry)))))

(provide 'codex-ide-agents-tests)

;;; codex-ide-agents-tests.el ends here
