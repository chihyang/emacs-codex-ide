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

(provide 'codex-ide-session-tests)

;;; codex-ide-session-tests.el ends here
