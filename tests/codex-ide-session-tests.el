;;; codex-ide-session-tests.el --- Tests for codex-ide-session -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for Codex session and process lifecycle behavior.

;;; Code:

(require 'ert)
(require 'codex-ide-test-fixtures)
(require 'codex-ide)

(defun codex-ide-session-test--thread-read (thread-id)
  "Return a minimal replayable `thread/read` response for THREAD-ID."
  `((thread . ((id . ,thread-id)))
    (turns . (((id . "stored-turn")
               (items . (((type . "userMessage")
                          (content . (((type . "text")
                                       (text . "Stored prompt")))))
                         ((type . "agentMessage")
                          (id . "stored-response")
                          (text . "Stored response")))))))))

(ert-deftest codex-ide-app-server-daemon-command-uses-proxy ()
  (let ((codex-ide-cli-path "/tmp/codex")
        (codex-ide-app-server-transport 'daemon)
        (codex-ide-cli-extra-flags "--enable feature-name"))
    (should (equal (codex-ide--app-server-command)
                   '("/tmp/codex" "app-server" "proxy"
                     "--enable" "feature-name")))))

(ert-deftest codex-ide-daemon-session-configures-websocket-transport ()
  (let ((project-dir (codex-ide-test--make-temp-project)))
    (codex-ide-test-with-fixture project-dir
      (let ((codex-ide-app-server-transport 'daemon))
        (codex-ide-test-with-fake-processes
          (let* ((session (codex-ide--create-process-session))
                 (process (codex-ide-session-process session))
                 (make-spec
                  (plist-get (codex-ide-test-process-plist process)
                             :make-process-spec)))
            (should (equal (plist-get make-spec :command)
                           (list codex-ide-cli-path "app-server" "proxy")))
            (should (eq (plist-get make-spec :coding) 'binary))
            (should (eq (plist-get make-spec :filter)
                        #'codex-ide-websocket-process-filter))
            (should (eq (process-get process 'codex-ide-websocket-state)
                        'handshake))))))))

(ert-deftest codex-ide-ensure-query-session-retires-stale-query-session ()
  (let ((project-dir (codex-ide-test--make-temp-project)))
    (codex-ide-test-with-fixture project-dir
      (codex-ide-test-with-fake-processes
        (cl-letf (((symbol-function 'codex-ide--request-sync)
                   (lambda (_session method _params)
                     (pcase method
                       ("initialize" '((ok . t)))
                       (_ (ert-fail (format "Unexpected method %s" method)))))))
          (let ((query-session
                 (codex-ide--ensure-query-session-for-thread-selection project-dir))
                (session nil))
            (let ((default-directory project-dir))
              (setq session (codex-ide--create-process-session)))
            (should (eq (codex-ide--ensure-query-session-for-thread-selection
                         project-dir)
                        session))
            (should-not (memq query-session codex-ide--sessions))
            (should-not (process-live-p
                         (codex-ide-session-process query-session)))
            (should-not (process-live-p
                         (codex-ide-session-stderr-process query-session)))))))))

(ert-deftest codex-ide-show-or-resume-thread-retires-query-only-session ()
  (let ((project-dir (codex-ide-test--make-temp-project)))
    (codex-ide-test-with-fixture project-dir
      (codex-ide-test-with-fake-processes
        (cl-letf (((symbol-function 'codex-ide--request-sync)
                   (lambda (_session method _params)
                     (pcase method
                       ("initialize" '((ok . t)))
                       ("thread/read"
                        (codex-ide-session-test--thread-read "stored-thread"))
                       ("thread/resume" '((thread . ((id . "stored-thread")))))
                       (_ (ert-fail (format "Unexpected method %s" method))))))
                  ((symbol-function 'codex-ide-display-buffer)
                   (lambda (_buffer &optional _action) (selected-window))))
          (let ((query-session
                 (codex-ide--ensure-query-session-for-thread-selection project-dir)))
            (let ((session
                   (codex-ide--show-or-resume-thread "stored-thread" project-dir)))
              (should-not (eq session query-session))
              (should (equal codex-ide--sessions (list session)))
              (should-not (process-live-p
                           (codex-ide-session-process query-session)))
              (should-not (process-live-p
                           (codex-ide-session-stderr-process query-session))))))))))

(ert-deftest codex-ide-show-or-resume-thread-prefers-buffer-across-directories ()
  (let* ((root-dir (codex-ide-test--make-temp-project))
         (buffer-dir (expand-file-name "buffer-dir" root-dir))
         (recorded-dir (expand-file-name "recorded-dir" root-dir)))
    (make-directory buffer-dir t)
    (make-directory recorded-dir t)
    (codex-ide-test-with-fixture root-dir
      (codex-ide-test-with-fake-processes
        (let (session shown)
          (let ((default-directory buffer-dir))
            (setq session (codex-ide--create-process-session)))
          (setf (codex-ide-session-thread-id session) "shared-thread"
                (codex-ide-session-status session) "idle")
          (cl-letf (((symbol-function 'codex-ide--show-session-buffer)
                     (lambda (candidate &rest _)
                       (setq shown candidate)
                       candidate))
                    ((symbol-function 'codex-ide--create-process-session)
                     (lambda (&rest _)
                       (ert-fail "Must not create another session")))
                    ((symbol-function 'codex-ide--resume-thread-into-session)
                     (lambda (&rest _)
                       (ert-fail "Must not resume an already open thread")))
                    ((symbol-function 'codex-ide--schedule-usage-refresh)
                     #'ignore))
            (should
             (eq (codex-ide--show-or-resume-thread
                  "shared-thread" recorded-dir)
                 session))
            (should (eq shown session))))))))

(provide 'codex-ide-session-tests)

;;; codex-ide-session-tests.el ends here
