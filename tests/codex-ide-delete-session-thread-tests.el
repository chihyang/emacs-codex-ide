;;; codex-ide-delete-session-thread-tests.el --- Tests for delete-session-thread -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused ERT coverage for app-server-backed thread deletion.

;;; Code:

(require 'ert)
(require 'codex-ide-test-fixtures)
(require 'codex-ide)

(ert-deftest codex-ide-delete-session-thread-requests-before-closing-live-session ()
  (let ((project-dir (codex-ide-test--make-temp-project))
        (actions nil)
        (prompt nil))
    (codex-ide-test-with-fixture project-dir
	(codex-ide-test-with-fake-processes
	  (let ((session (codex-ide--create-process-session)))
	    (setf (codex-ide-session-thread-id session) "thread-delete-1")
	    (cl-letf (((symbol-function 'yes-or-no-p)
		       (lambda (message)
			 (setq prompt message)
			 t))
		      ((symbol-function 'codex-ide--delete-thread)
		       (lambda (request-session thread-id)
			 (should (buffer-live-p (codex-ide-session-buffer session)))
			 (setq actions
			       (append actions
				       (list (list 'request request-session thread-id))))))
		      ((symbol-function 'codex-ide--delete-live-thread-session)
		       (lambda (deleted-session)
			 (setq actions
			       (append actions (list (list 'close deleted-session)))))))
	      (codex-ide-delete-session-thread "thread-delete-1")
	      (should (equal actions
			     (list (list 'request session "thread-delete-1")
				   (list 'close session))))
	      (should (string-match-p
		       (regexp-quote
			(buffer-name (codex-ide-session-buffer session)))
		       prompt))))))))

(ert-deftest codex-ide-delete-session-thread-cancel-keeps-live-session ()
  (let ((project-dir (codex-ide-test--make-temp-project))
        requested
        closed)
    (codex-ide-test-with-fixture project-dir
	(codex-ide-test-with-fake-processes
	  (let ((session (codex-ide--create-process-session)))
	    (setf (codex-ide-session-thread-id session) "thread-delete-2")
	    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
		      ((symbol-function 'codex-ide--delete-thread)
		       (lambda (&rest _) (setq requested t)))
		      ((symbol-function 'codex-ide--delete-live-thread-session)
		       (lambda (&rest _) (setq closed t))))
	      (should-error (codex-ide-delete-session-thread "thread-delete-2")
			    :type 'user-error)
	      (should-not requested)
	      (should-not closed)
	      (should (buffer-live-p (codex-ide-session-buffer session)))))))))

(ert-deftest codex-ide-delete-session-thread-server-failure-keeps-live-session ()
  (let ((project-dir (codex-ide-test--make-temp-project)) closed)
    (codex-ide-test-with-fixture project-dir
	(codex-ide-test-with-fake-processes
	  (let ((session (codex-ide--create-process-session)))
	    (setf (codex-ide-session-thread-id session) "thread-delete-failed")
	    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
		      ((symbol-function 'codex-ide--delete-thread)
		       (lambda (&rest _) (error "server rejected deletion")))
		      ((symbol-function 'codex-ide--delete-live-thread-session)
		       (lambda (&rest _) (setq closed t))))
	      (let ((err
		     (should-error
		      (codex-ide-delete-session-thread "thread-delete-failed"))))
		(should (string-match-p "server rejected deletion"
					(error-message-string err))))
	      (should-not closed)
	      (should (memq session codex-ide--sessions))
	      (should (buffer-live-p (codex-ide-session-buffer session)))))))))

(ert-deftest codex-ide-delete-session-thread-skip-confirmation-bypasses-prompt ()
  (let ((project-dir (codex-ide-test--make-temp-project)) prompted request)
    (codex-ide-test-with-fixture project-dir
	(cl-letf (((symbol-function 'yes-or-no-p)
		   (lambda (&rest _)
		     (setq prompted t)
		     (ert-fail "Unexpected confirmation prompt")))
		  ((symbol-function 'codex-ide--thread-deletion-session)
		   (lambda (&rest _) 'query-session))
		  ((symbol-function 'codex-ide--delete-thread)
		   (lambda (session thread-id)
		     (setq request (list session thread-id)))))
	  (codex-ide-delete-session-thread "thread-delete-3" t)
	  (should (equal request '(query-session "thread-delete-3")))
	  (should-not prompted)))))

(ert-deftest codex-ide-delete-session-thread-explains-unsupported-server ()
  (let ((project-dir (codex-ide-test--make-temp-project)))
    (codex-ide-test-with-fixture project-dir
	(cl-letf (((symbol-function 'codex-ide--thread-deletion-session)
		   (lambda (&rest _) 'query-session))
		  ((symbol-function 'codex-ide--delete-thread)
		   (lambda (&rest _) (error "Method not found: thread/delete"))))
	  (let ((err (should-error
		      (codex-ide-delete-session-thread "thread-old-server" t)
		      :type 'user-error)))
	    (should (string-match-p "upgrade Codex"
				    (error-message-string err))))))))

(provide 'codex-ide-delete-session-thread-tests)

;;; codex-ide-delete-session-thread-tests.el ends here
