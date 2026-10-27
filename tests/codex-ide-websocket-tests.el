;;; codex-ide-websocket-tests.el --- Tests for codex-ide-websocket -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the WebSocket framing used by the shared Codex daemon proxy.

;;; Code:

(require 'ert)
(require 'codex-ide-test-fixtures)
(require 'codex-ide-websocket)

(ert-deftest codex-ide-websocket-computes-rfc-accept-value ()
  (should
   (equal (codex-ide-websocket--accept-value "dGhlIHNhbXBsZSBub25jZQ==")
          "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")))

(ert-deftest codex-ide-websocket-encodes-masked-client-frame ()
  (let ((frame
         (codex-ide-websocket--encode-frame
          1
          (string-as-unibyte "Hello")
          (unibyte-string #x37 #xfa #x21 #x3d))))
    (should (equal (string-to-list frame)
                   '(#x81 #x85 #x37 #xfa #x21 #x3d
                     #x7f #x9f #x4d #x51 #x58)))))

(ert-deftest codex-ide-websocket-parses-server-frame-and-remainder ()
  (let* ((bytes (concat (unibyte-string #x81 5)
                        (string-as-unibyte "Hello")
                        (unibyte-string #x81)))
         (parsed (codex-ide-websocket--parse-frame bytes)))
    (should parsed)
    (should (plist-get (car parsed) :fin))
    (should (= (plist-get (car parsed) :opcode) 1))
    (should (equal (plist-get (car parsed) :payload) "Hello"))
    (should (equal (string-to-list (cdr parsed)) '(#x81)))))

(ert-deftest codex-ide-websocket-handshake-flushes-queue-and-delivers-frame ()
  (codex-ide-test-with-fake-processes
    (let* ((process (make-process :name "websocket-test" :command '("unused")))
           (received nil))
      (codex-ide-websocket-configure
       process
       (lambda (_process text) (push text received)))
      (codex-ide-websocket-send-text process "queued request")
      (let* ((key (process-get process 'codex-ide-websocket-key))
             (response
              (format (concat "HTTP/1.1 101 Switching Protocols\r\n"
                              "Upgrade: websocket\r\n"
                              "Connection: Upgrade\r\n"
                              "Sec-WebSocket-Accept: %s\r\n\r\n")
                      (codex-ide-websocket--accept-value key)))
             (server-message "{\"id\":1,\"result\":{}}")
             (server-frame
              (concat (unibyte-string #x81 (length server-message))
                      (string-as-unibyte server-message))))
        (codex-ide-websocket-process-filter
         process
         (concat (string-as-unibyte response) server-frame)))
      (should-not (process-get process 'codex-ide-websocket-error))
      (should (eq (process-get process 'codex-ide-websocket-state) 'open))
      (should (equal received '("{\"id\":1,\"result\":{}}")))
      (let* ((sent (codex-ide-test-process-sent-strings process))
             (queued-frame (car (last sent)))
             (parsed (codex-ide-websocket--parse-frame queued-frame)))
        (should (= (length sent) 2))
        (should (= (plist-get (car parsed) :opcode) 1))
        (should (equal (decode-coding-string
                        (plist-get (car parsed) :payload)
                        'utf-8 t)
                       "queued request"))))))

(provide 'codex-ide-websocket-tests)

;;; codex-ide-websocket-tests.el ends here
