;;; ob-scala-cli.el --- org-babel for scala evaluation in Scala-Cli. -*- lexical-binding: t; -*-

;; Author: Andrea <andrea-dev@hotmail.com>
;; URL: https://github.com/ag91/scala-cli-repl
;; Package-Requires: ((emacs "28.1") (s "1.12.0") (scala-cli-term-repl "0.0") (xterm-color "1.7"))
;; Version: 0.0
;; Keywords: tools, scala-cli, org-mode, scala, org-babel

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.


;;; Commentary:
;; org-babel for scala evaluation in `scala-cli-repl'.

;; Note: if you use :scala-version as a block param, remember to set
;; it only on the initial block otherwise it causes a reload of the
;; REPL (losing any previous state)

;;; Code:
(require 'ob)
(require 'ob-comint)
(require 'scala-cli-repl)
(require 's)
(require 'xterm-color)

(add-to-list 'org-babel-tangle-lang-exts '("scala" . "scala"))
(add-to-list 'org-src-lang-modes '("scala" . scala))

(defcustom ob-scala-cli-default-params '(:scala-version "3.3.0" :jvm 17)
  "Default parameters for scala-cli."
  :type 'plist
  :group 'org-babel)

(defcustom ob-scala-cli-prompt-str "scala>"
  "Regex for scala-cli prompt."
  :type 'string
  :group 'org-babel)

(defcustom ob-scala-cli-supported-params '(:scala-version :dep :jvm)
  "The ob blocks headers supported by this ob-scala-cli."
  :type '(repeat symbol)
  :group 'ob-babel)

(defcustom ob-scala-cli-temp-dir (file-name-as-directory (concat temporary-file-directory "ob-scala-cli"))
  "A directory for temporary files."
  :type 'string
  :group 'org-babel)

(defvar ob-scala-cli-debug-p nil
  "The variable to control the debug message.")

(defvar ob-scala-cli--last-params nil
  "Used to compare if params have changed before restarting REPL to update configuration.")

(defun ob-scala-cli--params (params)
  "Extract scala-cli command line parameters from PARAMS.

>> (ob-scala-cli--params '(:tangle no :scala-version \"3.0.0\" :jvm \"11\"))
=> (\"--scala-version\" \"3.0.0\" \"--jvm\" \"11\")"
  (flatten-list
   (mapcar
    (lambda (param)
      (when-let ((value (plist-get params param))
                 (p (s-replace ":" "--" (symbol-name param)))) ; NOTE: this means we want `ob-scala-cli--params' to match scala-cli command line params
        (cond
         ((listp value) (mapcar (lambda (d) (list p d)) value))
         ((numberp value) (list p (number-to-string value)))
         (t (list
             p
             (or (ignore-errors (symbol-name value)) value)))
         )))
    ob-scala-cli-supported-params)))

(defun org-babel-execute:scala (body params)
  "Execute the scala code in BODY using PARAMS in org-babel.
This function is called by `org-babel-execute-src-block'
Argument BODY the body to evaluate.
Argument PARAMS the header arguments."
  (let* ((info (org-babel-get-src-block-info))
         (file (ob-scala-cli--mk-file info))
         (body (nth 1 info))
         (params (org-combine-plists ob-scala-cli-default-params (cl--alist-to-plist params)))
         (scala-cli-params (ob-scala-cli--params params))
         (ob-scala-cli-eval-result ""))
    (unless (and (comint-check-proc scala-cli-repl-buffer-name) (equal scala-cli-params ob-scala-cli--last-params))
      (ignore-errors
        (kill-buffer scala-cli-repl-buffer-name))
      (save-window-excursion
        (let ((scala-cli-repl-program-args scala-cli-params))
          (scala-cli-repl)))
      (setq-local ob-scala-cli--last-params scala-cli-params)
      (while (not (and (get-buffer scala-cli-repl-buffer-name)
                       (with-current-buffer scala-cli-repl-buffer-name
                         (save-excursion
                           (goto-char (point-min))
                           (search-forward ob-scala-cli-prompt-str nil t)))))
        (message "Waiting for scala-cli to start...")
        (sit-for 0.5)))

    (set-process-filter
     (get-buffer-process scala-cli-repl-buffer-name)
     (lambda (process str)
       (term-emulate-terminal process str)
       (let ((str (substring-no-properties (xterm-color-filter str)))) ; make a plain text
         (when ob-scala-cli-debug-p (print str))
         (setq ob-scala-cli-eval-result (concat ob-scala-cli-eval-result str)))))

    (with-temp-file file (insert body))
    (comint-send-string scala-cli-repl-buffer-name (format ":load %s\n" file)) ; evaluate code in REPL

    (while (not (s-ends-with? ob-scala-cli-prompt-str (s-trim-right ob-scala-cli-eval-result)))
      (sit-for 0.5))
    (sit-for 0.2)

    (when ob-scala-cli-debug-p (message "#### %s" ob-scala-cli-eval-result))
    (->> ob-scala-cli-eval-result
         (s-split (format "Loading %s..." file)) ; the first part (loading ...) is not interesting
         cdr
         (s-join "")
         (s-replace ob-scala-cli-prompt-str "") ; remove "scala>"
         (s-replace (format "%s:" file) "On line ") ; the temp file name is not interesting
         s-trim
         (replace-regexp-in-string "[\r\n]+" "\n") ; removing ^M
         )))

(defun ob-scala-cli-lsp-org ()
  "Modify src block and enable `lsp-metals' to get goodies like code completion in literate programming.

Call this on a second block if you want to reset dependencies or
Scala version, otherwise you will lose the previous session.

This works by creating a .sc file and loading the dependencies
and scala version defined by the block parameters
`scala-cli-params'. Since `lsp-org' requires a :tangle <file>
header is defined, we set it to our temporary Scala script."
  (interactive)
  (let* ((info (org-babel-get-src-block-info))
         (body (nth 1 info))
         (params (nth 2 info))
         (params (org-combine-plists ob-scala-cli-default-params (cl--alist-to-plist params)))
         (s-params (s-join " " (ob-scala-cli--params params)))
         (deps (plist-get ':dep params))
         (version (plist-get ':scala-version params))
         (file (ob-scala-cli--mk-lsp-file info))
         (dir (file-name-directory file))
         (default-directory dir)) ; to change the working directory for shell-command
    (when (with-demoted-errors "Error: %S" (require 'lsp-metals))
      (with-temp-file file
        (seq-doseq (it deps)
          (insert "//> using dep " it "\n"))
        (when version
          (insert "//> using scala " version "\n"))
        (insert body))
      (message "Configuring ob-scala-cli for lsp through scala-cli...")
      (message "cd %s; scala-cli clean .; scala-cli setup-ide . %s" dir s-params)
      (shell-command (format "%s %s setup-ide ." scala-cli-repl-program s-params))
      (message "Starting lsp-org via lsp-metals...")
      (lsp-org))))

(defun ob-scala-cli--mk-file (&optional info lsp)
  "Create a temporary file for the current source block."
  (let* ((info (or info (org-babel-get-src-block-info)))
         (params (nth 2 info))
         (temp-dir (file-name-as-directory (concat ob-scala-cli-temp-dir (ob-scala-cli--get-id))))
         (temp-dir (if lsp
                       (file-name-as-directory (concat temp-dir "lsp"))
                     temp-dir))
         (block-name (nth 4 (org-babel-get-src-block-info)))
         (lsp-name (or block-name (org-id-uuid)))
         (file-name (format "%s.sc" (if lsp lsp-name "repl")))
         (temp-file (concat temp-dir file-name)))
    (unless (file-exists-p temp-dir)
      (make-directory temp-dir 'parents))
    temp-file))

(defun ob-scala-cli--mk-lsp-file (info)
  "Create a temporary file for lsp or use the specified tangle file."
  (let* ((params (nth 2 info))
         (tangle (cdr (assoc :tangle params))))
    (if (or (not tangle) (string= tangle "no"))
        (let ((file (ob-scala-cli--mk-file info t)))
          (ob-scala-cli--set-tangle file) ; https://emacs-lsp.github.io/lsp-mode/manual-language-docs/lsp-org/
          file)
      tangle)))

(defun ob-scala-cli--set-tangle (file)
  (save-excursion
    (goto-char (org-babel-where-is-src-block-head))
    (end-of-line)
    (insert " :tangle " file)))

(defun ob-scala-cli--get-id ()
  (org-id-get (point-min)))

(provide 'ob-scala-cli)

;;; ob-scala-cli.el ends here

