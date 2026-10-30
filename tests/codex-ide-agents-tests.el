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
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "g"))
              #'revert-buffer))
  (should-not (lookup-key codex-ide-agents-mode-map (kbd "l")))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "i"))
              #'codex-ide-agents-detail))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "c"))
              #'codex-ide-agents-create))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "r"))
              #'codex-ide-agents-rename))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "k"))
              #'codex-ide-agents-mark-close))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "d"))
              #'codex-ide-agents-mark-delete))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "u"))
              #'codex-ide-agents-unmark))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "U"))
              #'codex-ide-agents-unmark-all))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "X"))
              #'codex-ide-agents-execute-marked))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "K"))
              #'codex-ide-agents-close))
  (should (eq (lookup-key codex-ide-agents-mode-map (kbd "D"))
              #'codex-ide-agents-delete)))

(defmacro codex-ide-agents-test--with-selected-row (&rest body)
  "Run BODY in an agents buffer with one selected test row."
  (declare (indent 0))
  `(with-temp-buffer
     (codex-ide-agents-mode)
     (let ((thread (codex-ide-agents-test--thread
                    "thread-delete" "/tmp/project" "Delete me" "notLoaded" 20)))
       (setq-local codex-ide-agents--query-directory "/tmp/query/"
                   codex-ide-agents--threads-by-id
                   (make-hash-table :test #'equal))
       (puthash "thread-delete" thread codex-ide-agents--threads-by-id)
       (setq tabulated-list-format [("Session" 15 t)]
             tabulated-list-padding 2
             tabulated-list-entries
             (list (list (cons "thread-delete" "/tmp/project")
                         (vector "Delete me"))))
       (tabulated-list-init-header)
       (tabulated-list-print)
       (goto-char (point-min))
       (search-forward "Delete me")
       (beginning-of-line)
       ,@body)))

(ert-deftest codex-ide-agents-create-uses-selected-row-directory ()
  (let ((directory (codex-ide-test--make-temp-project))
        captured-directory
        choose-directory)
    (codex-ide-agents-test--with-selected-row
      (setf (alist-get 'cwd
                       (gethash "thread-delete"
                                codex-ide-agents--threads-by-id))
            directory)
      (cl-letf (((symbol-function 'codex-ide)
                 (lambda (&optional choose)
                   (setq captured-directory default-directory
                         choose-directory choose))))
        (codex-ide-agents-create)))
    (should (equal captured-directory (file-name-as-directory directory)))
    (should-not choose-directory)))

(ert-deftest codex-ide-agents-create-rejects-unavailable-directory ()
  (let ((directory (expand-file-name
                    "missing-codex-directory"
                    (codex-ide-test--make-temp-project)))
        created)
    (codex-ide-agents-test--with-selected-row
      (setf (alist-get 'cwd
                       (gethash "thread-delete"
                                codex-ide-agents--threads-by-id))
            directory)
      (cl-letf (((symbol-function 'codex-ide)
                 (lambda (&rest _) (setq created t))))
        (let ((err (should-error (codex-ide-agents-create) :type 'user-error)))
          (should (string-match-p "directory is unavailable"
                                  (error-message-string err))))))
    (should-not created)))

(ert-deftest codex-ide-agents-create-rejects-row-without-directory ()
  (let (created)
    (codex-ide-agents-test--with-selected-row
      (setf (alist-get 'cwd
                       (gethash "thread-delete"
                                codex-ide-agents--threads-by-id))
            nil)
      (cl-letf (((symbol-function 'codex-ide)
                 (lambda (&rest _) (setq created t))))
        (let ((err (should-error (codex-ide-agents-create) :type 'user-error)))
          (should (string-match-p "has no working directory"
                                  (error-message-string err))))))
    (should-not created)))

(ert-deftest codex-ide-agents-create-failure-shows-error-and-tip ()
  (let ((directory (codex-ide-test--make-temp-project))
        shown)
    (unwind-protect
        (progn
          (codex-ide-agents-test--with-selected-row
            (setf (alist-get 'cwd
                             (gethash "thread-delete"
                                      codex-ide-agents--threads-by-id))
                  directory)
            (cl-letf (((symbol-function 'codex-ide)
                       (lambda (&rest _) (error "startup rejected")))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _) (setq shown buffer))))
              (codex-ide-agents-create)))
          (should (buffer-live-p shown))
          (with-current-buffer shown
            (should (derived-mode-p 'special-mode))
            (should (string-match-p "session creation failed"
                                    (buffer-string)))
            (should (string-match-p "startup rejected" (buffer-string)))
            (should (string-match-p "Tip:" (buffer-string)))))
      (when (buffer-live-p shown)
        (kill-buffer shown)))))

(ert-deftest codex-ide-agents-rename-seeds-name-requests-and-refreshes ()
  (let (initial-input request refreshed)
    (codex-ide-agents-test--with-selected-row
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt initial &rest _)
                   (setq initial-input initial)
                   "Renamed session"))
                ((symbol-function 'codex-ide--prepare-session-operations)
                 #'ignore)
                ((symbol-function 'codex-ide--ensure-query-session-for-thread-selection)
                 (lambda (directory)
                   (should (equal directory "/tmp/query/"))
                   'query-session))
                ((symbol-function 'codex-ide--set-thread-name)
                 (lambda (session thread-id name)
                   (setq request (list session thread-id name))))
                ((symbol-function 'codex-ide-agents-refresh)
                 (lambda (&rest _) (setq refreshed t))))
        (codex-ide-agents-rename)))
    (should (equal initial-input "Delete me"))
    (should (equal request
                   '(query-session "thread-delete" "Renamed session")))
    (should refreshed)))

(ert-deftest codex-ide-agents-rename-rejects-empty-name-before-request ()
  (let (prepared requested)
    (codex-ide-agents-test--with-selected-row
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) "   "))
                ((symbol-function 'codex-ide--prepare-session-operations)
                 (lambda () (setq prepared t)))
                ((symbol-function 'codex-ide--set-thread-name)
                 (lambda (&rest _) (setq requested t))))
        (should-error (codex-ide-agents-rename) :type 'user-error)))
    (should-not prepared)
    (should-not requested)))

(ert-deftest codex-ide-agents-rename-failure-shows-error-without-refresh ()
  (let (refreshed shown)
    (unwind-protect
        (progn
          (codex-ide-agents-test--with-selected-row
            (cl-letf (((symbol-function 'read-string)
                       (lambda (&rest _) "Renamed session"))
                      ((symbol-function 'codex-ide--prepare-session-operations)
                       #'ignore)
                      ((symbol-function 'codex-ide--ensure-query-session-for-thread-selection)
                       (lambda (&rest _) 'query-session))
                      ((symbol-function 'codex-ide--set-thread-name)
                       (lambda (&rest _) (error "rename rejected")))
                      ((symbol-function 'codex-ide-agents-refresh)
                       (lambda (&rest _) (setq refreshed t)))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _) (setq shown buffer))))
              (codex-ide-agents-rename)))
          (should-not refreshed)
          (should (buffer-live-p shown))
          (with-current-buffer shown
            (should (derived-mode-p 'special-mode))
            (should (string-match-p "session rename failed" (buffer-string)))
            (should (string-match-p "thread-delete" (buffer-string)))
            (should (string-match-p "rename rejected" (buffer-string)))
            (should (string-match-p "Tip:" (buffer-string)))))
      (when (buffer-live-p shown)
        (kill-buffer shown)))))

(ert-deftest codex-ide-agents-mark-and-unmark-delete-without-deleting ()
  (let (deleted)
    (codex-ide-agents-test--with-selected-row
      (cl-letf (((symbol-function 'codex-ide-delete-session-thread)
                 (lambda (&rest _) (setq deleted t))))
        (codex-ide-agents-mark-delete)
        (forward-line -1)
        (should (eq (char-after (line-beginning-position)) ?D))
        (codex-ide-agents-unmark)
        (forward-line -1)
        (should (eq (char-after (line-beginning-position)) ?\s))))
    (should-not deleted)))

(ert-deftest codex-ide-agents-mark-close-requires-local-session ()
  (codex-ide-agents-test--with-selected-row
    (should-error (codex-ide-agents-mark-close) :type 'user-error)
    (should-error (codex-ide-agents-close) :type 'user-error)
    (should (eq (char-after (line-beginning-position)) ?\s))))

(ert-deftest codex-ide-agents-close-and-delete-marks-replace-each-other ()
  (codex-ide-agents-test--with-selected-row
    (cl-letf (((symbol-function 'codex-ide-agents--thread-session)
               (lambda (&rest _) 'local-session)))
      (codex-ide-agents-mark-delete)
      (forward-line -1)
      (should (eq (char-after (line-beginning-position)) ?D))
      (codex-ide-agents-mark-close)
      (forward-line -1)
      (should (eq (char-after (line-beginning-position)) ?K))
      (codex-ide-agents-mark-delete)
      (forward-line -1)
      (should (eq (char-after (line-beginning-position)) ?D)))))

(ert-deftest codex-ide-agents-unmark-all-clears-close-marks ()
  (codex-ide-agents-test--with-selected-row
    (cl-letf (((symbol-function 'codex-ide-agents--thread-session)
               (lambda (&rest _) 'local-session)))
      (codex-ide-agents-mark-close)
      (forward-line -1)
      (should (eq (char-after (line-beginning-position)) ?K))
      (codex-ide-agents-unmark-all)
      (should (eq (char-after (line-beginning-position)) ?\s))
      (should-not (codex-ide-agents--marked-actions)))))

(ert-deftest codex-ide-agents-unmark-all-clears-deletion-marks ()
  (codex-ide-agents-test--with-selected-row
    (codex-ide-agents-mark-delete)
    (forward-line -1)
    (should (eq (char-after (line-beginning-position)) ?D))
    (codex-ide-agents-unmark-all)
    (should (eq (char-after (line-beginning-position)) ?\s))
    (should-not (codex-ide-agents--marked-threads))))

(ert-deftest codex-ide-agents-execute-deletions-confirms-and-refreshes ()
  (let (deleted refreshed prompt)
    (codex-ide-agents-test--with-selected-row
      (codex-ide-agents-mark-delete)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (text) (setq prompt text) t))
                ((symbol-function 'codex-ide-delete-session-thread)
                 (lambda (thread-id skip-confirmation)
                   (setq deleted (cons thread-id skip-confirmation))))
                ((symbol-function 'codex-ide-agents-refresh)
                 (lambda (&rest _) (setq refreshed t))))
        (codex-ide-agents-execute-deletions)))
    (should (string-match-p "Delete me" prompt))
    (should (equal deleted '("thread-delete" . t)))
    (should refreshed)))

(ert-deftest codex-ide-agents-direct-close-confirms-and-refreshes ()
  (let (closed refreshed prompt)
    (codex-ide-agents-test--with-selected-row
      (cl-letf (((symbol-function 'codex-ide-agents--thread-session)
                 (lambda (&rest _) 'local-session))
                ((symbol-function 'codex-ide-agents--active-close-count)
                 (lambda (&rest _) 1))
                ((symbol-function 'yes-or-no-p)
                 (lambda (text) (setq prompt text) t))
                ((symbol-function 'codex-ide--close-session)
                 (lambda (session) (setq closed session)))
                ((symbol-function 'codex-ide-agents-refresh)
                 (lambda (&rest _) (setq refreshed t))))
        (codex-ide-agents-close)))
    (should (eq closed 'local-session))
    (should refreshed)
    (should (string-match-p "Close local Codex session Delete me" prompt))
    (should (string-match-p "active session will be interrupted" prompt))))

(ert-deftest codex-ide-agents-direct-close-cancel-keeps-session ()
  (let (closed refreshed)
    (codex-ide-agents-test--with-selected-row
      (cl-letf (((symbol-function 'codex-ide-agents--thread-session)
                 (lambda (&rest _) 'local-session))
                ((symbol-function 'codex-ide-agents--active-close-count)
                 (lambda (&rest _) 0))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                ((symbol-function 'codex-ide--close-session)
                 (lambda (&rest _) (setq closed t)))
                ((symbol-function 'codex-ide-agents-refresh)
                 (lambda (&rest _) (setq refreshed t))))
        (codex-ide-agents-close)))
    (should-not closed)
    (should-not refreshed)))

(ert-deftest codex-ide-agents-execute-marked-dispatches-close-and-delete ()
  (let ((close-thread
         (codex-ide-agents-test--thread
          "thread-close" "/tmp/close" "Close me" "active" 30))
        (delete-thread
         (codex-ide-agents-test--thread
          "thread-delete" "/tmp/delete" "Delete me" "notLoaded" 20))
        closed deleted refreshed prompt)
    (with-temp-buffer
      (codex-ide-agents-mode)
      (setq-local codex-ide-agents--threads-by-id
                  (make-hash-table :test #'equal))
      (puthash "thread-close" close-thread codex-ide-agents--threads-by-id)
      (puthash "thread-delete" delete-thread codex-ide-agents--threads-by-id)
      (setq tabulated-list-format [("Session" 15 t)]
            tabulated-list-padding 2
            tabulated-list-entries
            (list (list (cons "thread-close" "/tmp/close")
                        (vector "Close me"))
                  (list (cons "thread-delete" "/tmp/delete")
                        (vector "Delete me"))))
      (tabulated-list-init-header)
      (tabulated-list-print)
      (goto-char (point-min))
      (search-forward "Close me")
      (beginning-of-line)
      (cl-letf (((symbol-function 'codex-ide-agents--thread-session)
                 (lambda (thread)
                   (and (equal (alist-get 'id thread) "thread-close")
                        'local-session)))
                ((symbol-function 'codex-ide-agents--active-close-count)
                 (lambda (&rest _) 0))
                ((symbol-function 'yes-or-no-p)
                 (lambda (text) (setq prompt text) t))
                ((symbol-function 'codex-ide--close-session)
                 (lambda (session) (setq closed session)))
                ((symbol-function 'codex-ide-delete-session-thread)
                 (lambda (thread-id skip-confirmation)
                   (setq deleted (cons thread-id skip-confirmation))))
                ((symbol-function 'codex-ide-agents-refresh)
                 (lambda (&rest _) (setq refreshed (1+ (or refreshed 0))))))
        (codex-ide-agents-mark-close)
        (search-forward "Delete me")
        (beginning-of-line)
        (codex-ide-agents-mark-delete)
        (codex-ide-agents-execute-marked)))
    (should (eq closed 'local-session))
    (should (equal deleted '("thread-delete" . t)))
    (should (= refreshed 1))
    (should (string-match-p "Close 1 local" prompt))
    (should (string-match-p "permanently delete 1" prompt))))

(ert-deftest codex-ide-agents-close-failure-retains-mark-and-shows-error ()
  (let (refreshed shown)
    (unwind-protect
        (progn
          (codex-ide-agents-test--with-selected-row
            (cl-letf (((symbol-function 'codex-ide-agents--thread-session)
                       (lambda (&rest _) 'local-session))
                      ((symbol-function 'codex-ide-agents--active-close-count)
                       (lambda (&rest _) 0))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                      ((symbol-function 'codex-ide--close-session)
                       (lambda (&rest _) (error "close rejected")))
                      ((symbol-function 'codex-ide-agents-refresh)
                       (lambda (&rest _) (setq refreshed t)))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _) (setq shown buffer))))
              (codex-ide-agents-close)
              (should (eq (char-after (line-beginning-position)) ?K))))
          (should-not refreshed)
          (should (buffer-live-p shown))
          (with-current-buffer shown
            (should (string-match-p "Close failed: close rejected"
                                    (buffer-string)))))
      (when (buffer-live-p shown)
        (kill-buffer shown)))))

(ert-deftest codex-ide-agents-direct-delete-confirms-before-deleting ()
  (let (deleted prompt)
    (codex-ide-agents-test--with-selected-row
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (text) (setq prompt text) t))
                ((symbol-function 'codex-ide-delete-session-thread)
                 (lambda (thread-id skip-confirmation)
                   (setq deleted (cons thread-id skip-confirmation))))
                ((symbol-function 'codex-ide-agents-refresh) #'ignore))
        (codex-ide-agents-delete)))
    (should (string-match-p "Delete me" prompt))
    (should (equal deleted '("thread-delete" . t)))))

(ert-deftest codex-ide-agents-execute-deletions-cancel-keeps-session ()
  (let (deleted refreshed)
    (codex-ide-agents-test--with-selected-row
      (codex-ide-agents-mark-delete)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                ((symbol-function 'codex-ide-delete-session-thread)
                 (lambda (&rest _) (setq deleted t)))
                ((symbol-function 'codex-ide-agents-refresh)
                 (lambda (&rest _) (setq refreshed t))))
        (codex-ide-agents-execute-deletions)))
    (should-not deleted)
    (should-not refreshed)))

(ert-deftest codex-ide-agents-execute-deletions-failure-shows-error-and-tip ()
  (let (refreshed shown)
    (unwind-protect
        (progn
          (codex-ide-agents-test--with-selected-row
            (codex-ide-agents-mark-delete)
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                      ((symbol-function 'codex-ide-delete-session-thread)
                       (lambda (&rest _) (error "rollout missing")))
                      ((symbol-function 'codex-ide-agents-refresh)
                       (lambda (&rest _) (setq refreshed t)))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _) (setq shown buffer))))
              (codex-ide-agents-execute-deletions)))
          (should-not refreshed)
          (should (buffer-live-p shown))
          (with-current-buffer shown
            (should (derived-mode-p 'special-mode))
            (should (string-match-p "thread-delete" (buffer-string)))
            (should (string-match-p "rollout missing" (buffer-string)))
            (should (string-match-p "Tip:" (buffer-string)))))
      (when (buffer-live-p shown)
        (kill-buffer shown)))))

(ert-deftest codex-ide-agents-detail-inspects-row-thread ()
  (let ((threads-by-id (make-hash-table :test #'equal))
        (query-directory "/tmp/query/")
        (thread (codex-ide-agents-test--thread
                 "thread-detail" "/tmp/project" "Inspect me" "notLoaded" 20))
        inspected)
    (puthash "thread-detail" thread threads-by-id)
    (with-temp-buffer
      (codex-ide-agents-mode)
      (setq-local codex-ide-agents--threads-by-id
                  threads-by-id
                  codex-ide-agents--query-directory
                  query-directory)
      (setq tabulated-list-format [("Session" 15 t)]
            tabulated-list-entries
            (list (list (cons "thread-detail" "/tmp/project")
                        (vector "Inspect me"))))
      (tabulated-list-init-header)
      (tabulated-list-print)
      (goto-char (point-min))
      (search-forward "Inspect me")
      (beginning-of-line)
      (cl-letf (((symbol-function 'codex-ide-agent-detail-show)
                 (lambda (selected directory)
                   (setq inspected (list selected directory)))))
        (codex-ide-agents-detail)))
    (should (equal inspected (list thread "/tmp/query/")))))

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

(ert-deftest codex-ide-agents-refresh-preserves-selection-sort-and-marks ()
  (with-temp-buffer
    (let ((codex-ide-agents-auto-refresh-interval nil))
      (codex-ide-agents-mode))
    (setq-local codex-ide-agents--query-directory "/tmp/query/")
    (let ((entries
           (list (list (cons "thread-a" "/tmp/a") (vector "Alpha"))
                 (list (cons "thread-b" "/tmp/b") (vector "Beta")))))
      (setq tabulated-list-format [("Session" 15 t)]
            tabulated-list-padding 2
            tabulated-list-sort-key '("Session" . nil)
            tabulated-list-entries entries)
      (tabulated-list-init-header)
      (tabulated-list-print)
      (goto-char (point-min))
      (search-forward "Alpha")
      (beginning-of-line)
      (tabulated-list-put-tag "D")
      (search-forward "Beta")
      (beginning-of-line)
      (setq tabulated-list-entries (lambda () (reverse entries)))
      (codex-ide-agents-refresh)
      (should (equal (car-safe (tabulated-list-get-id)) "thread-b"))
      (should (equal tabulated-list-sort-key '("Session" . nil)))
      (goto-char (point-min))
      (search-forward "Alpha")
      (beginning-of-line)
      (should (eq (char-after (line-beginning-position)) ?D)))))

(ert-deftest codex-ide-agents-session-events-coalesce-refreshes ()
  (with-temp-buffer
    (let ((codex-ide-agents-auto-refresh-interval nil))
      (codex-ide-agents-mode))
    (setq-local codex-ide-agents--query-directory "/tmp/query/")
    (let (scheduled)
      (cl-letf (((symbol-function 'codex-ide-agents--visible-p)
                 (lambda () t))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (&rest _)
                   (setq scheduled (1+ (or scheduled 0)))
                   'agents-refresh-timer))
                ((symbol-function 'timerp)
                 (lambda (value) (eq value 'agents-refresh-timer))))
        (codex-ide-agents--handle-session-event 'status-changed nil nil)
        (codex-ide-agents--handle-session-event 'turn-started nil nil)
        (codex-ide-agents--handle-session-event 'unrelated nil nil))
      (should (= scheduled 1)))))

(ert-deftest codex-ide-agents-poll-schedules-only-while-visible-and-safe ()
  (with-temp-buffer
    (let ((codex-ide-agents-auto-refresh-interval nil))
      (codex-ide-agents-mode))
    (setq-local codex-ide-agents--query-directory "/tmp/query/")
    (let (visible scheduled)
      (cl-letf (((symbol-function 'codex-ide-agents--visible-p)
                 (lambda () visible))
                ((symbol-function 'codex-ide-agents--schedule-refresh)
                 (lambda () (setq scheduled (1+ (or scheduled 0))))))
        (codex-ide-agents--poll (current-buffer))
        (should-not scheduled)
        (setq visible t
              codex-ide-agents--interaction-active t)
        (codex-ide-agents--poll (current-buffer))
        (should-not scheduled)
        (setq codex-ide-agents--interaction-active nil)
        (codex-ide-agents--poll (current-buffer)))
      (should (= scheduled 1)))))

(ert-deftest codex-ide-agents-background-failure-retains-list-and-warns ()
  (with-temp-buffer
    (let ((codex-ide-agents-auto-refresh-interval nil))
      (codex-ide-agents-mode))
    (let ((inhibit-read-only t))
      (insert "last good agents list"))
    (let ((before (buffer-string)) displayed)
      (cl-letf (((symbol-function 'codex-ide-agents--refresh-list)
                 (lambda () (error "daemon unavailable")))
                ((symbol-function 'display-buffer)
                 (lambda (&rest _) (setq displayed t))))
        (codex-ide-agents--background-refresh))
      (should (equal (buffer-string) before))
      (should-not displayed)
      (should (equal codex-ide-agents--last-refresh-error
                     "daemon unavailable"))
      (should (string-match-p
               "refresh failed"
               (substring-no-properties
                (codex-ide-agents--mode-line-refresh-status)))))))

(ert-deftest codex-ide-agents-auto-refresh-cleans-up-timers-and-hook ()
  (let ((buffer (generate-new-buffer " *codex-agents-auto-refresh-test*"))
        listener poll-timer cancelled
        (original-cancel-timer (symbol-function 'cancel-timer)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (let ((codex-ide-agents-auto-refresh-interval 60))
              (codex-ide-agents-mode))
            (setq listener codex-ide-agents--event-listener
                  poll-timer codex-ide-agents--poll-timer))
          (cl-letf (((symbol-function 'cancel-timer)
                     (lambda (timer)
                       (push timer cancelled)
                       (funcall original-cancel-timer timer))))
            (kill-buffer buffer))
          (should (memq poll-timer cancelled))
          (should-not (memq listener codex-ide-session-event-hook)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-ide-agents-disabled-polling-keeps-event-refresh ()
  (with-temp-buffer
    (let ((codex-ide-agents-auto-refresh-interval nil))
      (codex-ide-agents-mode))
    (should-not codex-ide-agents--poll-timer)
    (should (memq codex-ide-agents--event-listener
                  codex-ide-session-event-hook))))

(provide 'codex-ide-agents-tests)

;;; codex-ide-agents-tests.el ends here
