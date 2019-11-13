;;; julia-snail.el --- Julia Snail -*- lexical-binding: t -*-


;;; --- requirements

(require 'cl-lib)
(require 'cl-macs)
(require 'json)
(require 's)
(require 'spinner)
(require 'subr-x)
(require 'thingatpt)
(require 'vterm)

(require 'julia-snail-parser "parser.el")


;;; --- customization

(defgroup julia-snail nil
  "Customization options for Julia Snail mode."
  :group 'external)

(defcustom julia-snail-executable "julia"
  "Julia executable to run as a Snail server."
  :tag "Julia executable"
  :group 'julia-snail
  :type 'string)

(defcustom julia-snail-port 10011
  "Default Snail server port."
  :tag "Snail server port"
  :group 'julia-snail
  :safe 'integerp
  :type 'integer)
(make-variable-buffer-local 'julia-snail-port)

(defcustom julia-snail-repl-buffer "*julia*"
  "Default buffer to use for Julia REPL interaction."
  :tag "Julia REPL buffer"
  :group 'julia-snail
  :safe 'stringp
  :type 'string)
(make-variable-buffer-local 'julia-snail-repl-buffer)

(defcustom julia-snail-show-error-window t
  "When t, show compilation errors in separate window. When nil,
just display them in the minibuffer."
  :tag "Show compilation errors in separate window"
  :group 'julia-snail
  :type 'boolean)


;;; --- variables

(defvar-local julia-snail--process nil)

(defvar julia-snail--server-file
  (concat (if load-file-name
                (file-name-directory load-file-name)
              (file-name-as-directory default-directory))
          "JuliaSnail.jl"))

(defvar julia-snail--requests
  (make-hash-table :test #'equal))


;;; --- Snail protocol request tracking data structure

(cl-defstruct julia-snail--request-tracker
  repl-buf
  originating-buf
  (callback-success (lambda () (message "Snail command succeeded")))
  (callback-failure (lambda () (message "Snail command failed")))
  tmpfile)


;;; --- supporting functions

(defun julia-snail--process-buffer-name (repl-buf)
  (let ((real-buf (get-buffer repl-buf)))
    (unless real-buf
      (error "no REPL buffer found"))
    (format "%s process" (buffer-name (get-buffer real-buf)))))

(defun julia-snail--error-buffer-name (repl-buf)
  (let ((real-buf (get-buffer repl-buf)))
    (unless real-buf
      (error "no REPL buffer found"))
    (format "%s error" (buffer-name (get-buffer real-buf)))))

(defun julia-snail--flash-region (start end &optional timeout)
  ;; borrowed from SLIME
  (let ((overlay (make-overlay start end)))
    (overlay-put overlay 'face 'highlight)
    (run-with-timer (or timeout 0.2) nil 'delete-overlay overlay)))

(defun julia-snail--construct-module-path (module)
  "Return a Julia array representing the module path, as Julia
symbols, given by MODULE. MODULE can be:
- nil, which returns [:Main]
- an Elisp keyword, which returns [<keyword>], including the
  leading colon in the keyword
- an Elisp list, which can contain either keywords or strings,
  and which is converted to a Julia array literal with the
  entries of the input list converted to Julia keywords"
  (cond ((null module) "[:Main]")
        ((keywordp module) (format "[%s]" module))
        ((listp module) (format
                         "[%s]"
                         (s-join " " (-map (lambda (s)
                                             (if (keywordp s)
                                                 (format "%s" s)
                                               (format ":%s" s)))
                                           module))))
        (t (error "Malformed module specification"))))


;;; --- connection management functions

(defun julia-snail--cleanup ()
  (let ((process-buf (get-buffer (julia-snail--process-buffer-name (current-buffer)))))
    (when process-buf
      (kill-buffer process-buf)))
  (setq julia-snail--process nil))

(defun julia-snail--enable ()
  (add-hook 'kill-buffer-hook #'julia-snail--cleanup nil t)
  (let ((repl-buf (current-buffer))
        (process-buf (get-buffer-create (julia-snail--process-buffer-name (current-buffer)))))
    (when (fboundp #'persp-add-buffer) ; perspective-el support
      (persp-add-buffer process-buf))
    (with-current-buffer process-buf
      (unless julia-snail--process
        (setq julia-snail-port (buffer-local-value 'julia-snail-port repl-buf))
        ;; XXX: This is currently necessary because there does not appear to be
        ;; a way to pass arguments to an interactive Julia session. This does
        ;; not work: `julia -L JuliaSnail.jl -- $PORT`.
        ;; https://github.com/JuliaLang/julia/issues/10226 refers to this
        ;; problem and supposedly fixes it, but it does not work for me with
        ;; Julia 1.0.4.
        ;; TODO: Follow-up on https://github.com/JuliaLang/julia/issues/33752
        (julia-snail--send-to-repl repl-buf
          (format "JuliaSnail.start(%d);" julia-snail-port)
          :async nil)
        (with-current-buffer repl-buf
          (setq julia-snail--process ; NB: buffer-local variable!
                (open-network-stream "julia-process" process-buf "localhost" julia-snail-port))
          (set-process-filter julia-snail--process #'julia-snail--server-response-filter))))))

(defun julia-snail--disable ()
  (julia-snail--cleanup))


;;; --- Julia REPL and Snail server interaction functions

(cl-defun julia-snail--send-to-repl (repl-buf str &key (async t))
  "Insert str directly into the REPL buffer. When :async is nil,
wait for the REPL prompt to return, otherwise return immediately."
  (declare (indent defun))
  (unless repl-buf
    (error "no REPL buffer given"))
  (with-current-buffer repl-buf
    (vterm-send-string str)
    (vterm-send-return)
    (unless async
      (sleep-for 0 20)
      ;; wait for the inclusion to succeed (i.e., the prompt prints)
      (let ((sleep-total 0))
        (while (and (< sleep-total 5000)
                    (not (string-equal "julia>" (current-word))))
          (sleep-for 0 20)
          (setf sleep-total (+ sleep-total 20)))))))

(cl-defun julia-snail--send-to-server
    (repl-buf module str &key callback-success callback-failure)
  "Send str to Snail server."
  (declare (indent defun))
  (unless repl-buf
    (error "no REPL buffer given"))
  (let* ((process-buf (get-buffer (julia-snail--process-buffer-name repl-buf)))
         (module-ns (julia-snail--construct-module-path module))
         (reqid (format "%04x%04x" (random (expt 16 4)) (random (expt 16 4))))
         (msg (format "(ns = %s, reqid = \"%s\", code = %s)\n"
                      module-ns
                      reqid
                      (json-encode-string str))))
    (with-current-buffer process-buf
      (goto-char (point-max))
      (insert msg))
    (process-send-string process-buf msg)
    (spinner-start 'progress-bar)
    (puthash reqid
             (make-julia-snail--request-tracker
              :repl-buf repl-buf
              :originating-buf (current-buffer)
              :callback-success callback-success
              :callback-failure callback-failure)
             julia-snail--requests)
    reqid))

(cl-defun julia-snail--send-to-server-via-tmp-file
    (repl-buf module str &key callback-success callback-failure)
  "Send str to server by first writing it to a tmpfile, calling
Julia include on the tmpfile, and then deleting the file."
  (declare (indent defun))
  (unless repl-buf
    (error "no REPL buffer given"))
  (let ((text (s-trim str))
        (tmpfile (make-temp-file
                  (expand-file-name "julia-tmp"
                                    (or small-temporary-file-directory
                                        temporary-file-directory)))))
    (progn
      (with-temp-file tmpfile
        (insert text))
      (let ((reqid (julia-snail--send-to-server
                     repl-buf
                     module
                     (format "include(\"%s\");" tmpfile)
                     :callback-success callback-success
                     :callback-failure callback-failure)))
        (puthash reqid
                 (make-julia-snail--request-tracker
                  :repl-buf repl-buf
                  :originating-buf (current-buffer)
                  :callback-success callback-success
                  :callback-failure callback-failure
                  :tmpfile tmpfile)
                 julia-snail--requests)))))

(defun julia-snail--server-response-filter (proc str)
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      ;; insert at the end unconditionally
      (goto-char (point-max))
      (insert str)
      (set-marker (process-mark proc) (point))
      ;; scary
      (eval (read str)))))


 ;;; --- Snail server response handling functions

(defun julia-snail--response-base (reqid)
  (let ((request-info (gethash reqid julia-snail--requests)))
    (when request-info
      ;; tmpfile
      (when-let (tmpfile (julia-snail--request-tracker-tmpfile request-info))
        (delete-file tmpfile))
      ;; stop spinner
      (with-current-buffer (julia-snail--request-tracker-originating-buf request-info)
        (spinner-stop))
      ;; remove request ID from requests hash
      (remhash reqid julia-snail--requests))))

(defun julia-snail--response-success (reqid)
  (let ((request-info (gethash reqid julia-snail--requests)))
    (funcall (julia-snail--request-tracker-callback-success request-info)))
  (julia-snail--response-base reqid))

(defun julia-snail--response-failure (reqid error-message error-stack)
  (if (not julia-snail-show-error-window)
      (message error-message)
    (let* ((request-info (gethash reqid julia-snail--requests))
           (repl-buf (julia-snail--request-tracker-repl-buf request-info))
           (error-buffer (get-buffer-create (julia-snail--error-buffer-name repl-buf))))
      (with-current-buffer error-buffer
        (insert error-message)
        (insert "\n\n")
        (insert (s-join "\n" error-stack))
        (goto-char (point-min))
        (read-only-mode))
      (display-buffer error-buffer)
      (funcall (julia-snail--request-tracker-callback-failure request-info))))
  (julia-snail--response-base reqid))


;;; --- commands

;;;###autoload
(defun julia-snail ()
  "Start a Julia REPL and connect to it, or switch if one already exists.
The following buffer-local variables control it:
- julia-snail-repl-buffer (default: *julia*)
- julia-snail-port (default: 10011)
To create multiple REPLs, give these variables distinct values (e.g.:
*julia my-project-1* and 10012)."
  (interactive)
  (let ((source-buf (current-buffer))
        (repl-buf (get-buffer julia-snail-repl-buffer)))
    (if repl-buf
        (pop-to-buffer-same-window repl-buf)
      ;; run Julia in a vterm and load the Snail server file
      (let ((vterm-shell (format "%s -L %s" julia-snail-executable julia-snail--server-file)))
        (vterm julia-snail-repl-buffer)
        (setq julia-snail-port (buffer-local-value 'julia-snail-port source-buf))
        (julia-snail-mode)))))

(defun julia-snail-send-line ()
  "Copy the line at the current point into the REPL and run it.
This is not module-context aware."
  (interactive)
  (let ((repl-buf (get-buffer julia-snail-repl-buffer)))
    (if (null repl-buf)
        (error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer)
      (let ((line (s-trim (thing-at-point 'line t))))
        (julia-snail--send-to-repl repl-buf
          line)))))

(defun julia-snail-send-buffer ()
  "Send the current buffer's file into the Julia REPL, and include() it.
This will occur in the context of the Main module, just as it would at the REPL."
  (interactive)
  (let ((repl-buf (get-buffer julia-snail-repl-buffer))
        (filename buffer-file-name))
    (if (null repl-buf)
        (error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer)
      (julia-snail--send-to-server repl-buf
        :Main
        (format "include(\"%s\");" filename)
        :callback-success (lambda () (message "%s loaded" filename))))))

(defun julia-snail-send-region ()
  "Send the region (requires transient-mark) to the Julia REPL and evaluate it.
This occurs in the context of the current module."
  (interactive)
  (let ((repl-buf (get-buffer julia-snail-repl-buffer)))
    (if (null repl-buf)
        (error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer)
      (if (null (use-region-p))
          (error "No region selected")
        (let ((text (buffer-substring-no-properties (region-beginning) (region-end)))
              (module (julia-snail-parser-query (current-buffer) (point) :module)))
          (julia-snail--send-to-server-via-tmp-file repl-buf
            module text
            :callback-success (lambda ()
                                (message "Selected region evaluated in module %s"
                                         (julia-snail--construct-module-path module)))))))))

(defun julia-snail-send-top-level-form ()
  "Send the top-level form surrounding the point to the Julia REPL and evaluate it.
This occurs in the context of the current module."
  (interactive)
  (let ((repl-buf (get-buffer julia-snail-repl-buffer)))
    (if (null repl-buf)
        (error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer)
      (let* ((q (julia-snail-parser-query (current-buffer) (point) :top-level-block))
             (module (plist-get q :module))
             (block-description (plist-get q :block))
             (block-start (-second-item block-description))
             (block-end (-third-item block-description))
             (text (buffer-substring-no-properties block-start block-end)))
        (julia-snail--flash-region block-start block-end 0.5)
        (julia-snail--send-to-server-via-tmp-file repl-buf
          module text
          :callback-success (lambda () (message "Top-level form evaluated (%s) in module %s"
                                                (if (-fourth-item block-description)
                                                    (-fourth-item block-description)
                                                  "unknown")
                                                (julia-snail--construct-module-path module))))))))

(defun julia-snail-package-activate (dir)
  "Activate a Pkg project in the Julia REPL."
  (interactive "DProject directory: ")
  (let ((repl-buf (get-buffer julia-snail-repl-buffer))
        (expanded-dir (expand-file-name dir)))
    (if (null repl-buf)
        (error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer)
      (julia-snail--send-to-server repl-buf
        :Main
        (format "Pkg.activate(\"%s\")" expanded-dir)
        :callback-success (lambda () (message "Package activated: %s" expanded-dir))))))


;;; --- mode definition

(define-minor-mode julia-snail-mode
  "A minor mode for interactive Julia development. Should only be
turned on in REPL buffers."
  :init-value nil
  :lighter " Snail"
  :keymap (make-sparse-keymap)
  (if julia-snail-mode
      (julia-snail--enable)
    (julia-snail--disable)))

(provide 'julia-snail)
