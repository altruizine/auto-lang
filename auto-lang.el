;;; auto-lang.el --- Guess language of current buffer

;; Copyright (C) 2000, 2001 Colin Marquardt

;; Author: Colin Marquardt <colin@marquardt-home.de>
;; Keywords: convenience, ispell, flyspell

;;; This file is NOT part of GNU Emacs or XEmacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; $Id: auto-lang.el,v 1.85 2002/09/18 07:13:49 cmarqu Exp $

;;; Commentary:
;;
;; auto-lang is an Emacs package which tries to find the language of
;; the current buffer and set ispell-dictionary according to that.  It
;; may be useful for writing texts, especially in with conjunction with
;; flyspell mode.  It can also differentiate between different encodings
;; for the same language.

;;; Documentation:
;;
;; In your ~/.emacs, add the lines
;;   (setq load-path (cons (expand-file-name "~/path/to/lisp/file/") load-path))
;;   (require 'auto-lang)
;;
;; Then enable whatever you like in the following:
;;
;;; Automatically enable auto-lang for Gnus:
;; (add-hook 'message-setup-hook
;;           '(lambda ()
;;              (auto-lang-minor-mode t)))
;;
;;; Automatically enable auto-lang for VM:
;; (add-hook 'mail-setup-hook
;;           '(lambda ()
;;              (auto-lang-minor-mode t)))
;;
;;; Automatically enable auto-lang for all text based modes:
;; (add-hook 'text-mode-hook
;;           '(lambda ()
;;              (auto-lang-minor-mode t)))
;;
;; You can also toggle the mode manually with
;;   M-x auto-lang-minor-mode

;;; Thanks to:
;;
;; Jean-Philippe Theberge
;;   for unknowingly giving me the idea to this
;;
;; Reto Zimmermann
;;   for VHDL-Mode and the help with this, and everything
;;
;; Jorge Godoy
;;   for useful suggestions
;;
;; Henrik Hansen
;;   for suggestions and stopwords
;;
;; Victor Cortijo
;;   for Spanish stopwords
;;
;; Colin Walters
;;   for Emacs Lisp help
;;
;; Eric M. Ludlam
;;   for Emacs Lisp help and the cool semantic package
;;
;; Benjamin Drieu
;;   who wrote a guess-lang.el independently of me, with some
;;   interesting ideas (incidentally, this package was also called
;;   guess-lang before I learned about his code). Benjamin's package
;;   is a port from a C program by Pascal Courtois. I stole some
;;   words from them, especially the full Italian word list.
;;
;; Jesper Harder and Eli Zaretskii
;;   for help with multibyte/unibyte issues
;;
;; Kai Großjohann
;;   for Emacs Lisp help
;;
;; Stefan Monnier
;;   for Emacs Lisp help

;; Jean-Philippe Theberge's code is also used in diction.el by
;; Sven Utcke

;;; Code:

(defconst auto-lang-version "0.02 beta"
  "This is the auto-lang version number.")

;; stolen from Vinicius Jose Latorre's ascii.el:
;; XEmacs needs the overlay emulation package.
(eval-and-compile
  (when (let (case-fold-search)
          (string-match "XEmacs\\|Lucid\\|Epoch" emacs-version))
    ;; from vhdl-mode.el:
    (unless (fboundp 'regexp-opt)
      (message "Please install the `xemacs-devel' package to get a faster regexp-opt.")
      (defun regexp-opt (strings &optional paren)
        (let ((open (if paren "\\(" "")) (close (if paren "\\)" "")))
          (concat open (mapconcat 'regexp-quote strings "\\|") close)))))
  ;; from Vinicius Jose Latorre's ps-print.el (functions are missing in XEmacs):
  (unless (fboundp 'string-as-unibyte)
    (defun string-as-unibyte (arg) arg))
  (unless (fboundp 'string-as-multibyte)
    (defun string-as-multibyte (arg) arg)))

;; temp fix for GNU Emacs (my 20.4.1 only has 780 by default):
(if (< max-specpdl-size 3000)
    (setq max-specpdl-size 3000))

; ------------------------------------------------------------------------

(defgroup auto-lang nil
  "*Guessing the language of a buffer."
  :tag "auto-lang"
  :prefix "al-"
  :group 'applications
  :group 'i18n
  :group 'convenience)

(defcustom al-mode-abbrev-string " AL"
  "*String to display in the modeline when auto-lang mode is active.
String should begin with a space.  If it is the empty string, no
indication is printed at all.

The modeline indicator is constructed as follows:
   <mode-abbreviation>:<language>/<mode operation>

If the language can be determined with enough confidence
and has an available dictionary, it is shown as-is.

If the language can be determined with enough confidence
but has no available dictionary, it is put in curly brackets.

If the language cannot be determined with enough confidence,
it is put in square brackets.

After the slash,
`i' is shown when ispell is used,
`f' is shown when flyspell is used.
`p' is shown when auto-lang operates in paragraph mode,
`b' denotes buffer mode."
  :type 'string
  :group 'auto-lang)

(defvar al-mode-line-string 'al-mode-abbrev-string
  "Holds the modeline as constructed by `al-make-mode-line'.")
(make-variable-buffer-local 'al-mode-line-string)
(put 'al-mode-line-string 'permanent-local nil) ;; from whitespace.el

(defcustom al-necessary-conf-diff 2
  "*Confidence factor needed between two languages.
The factor the confidence of the winner base language needs to differ
from the confidence of the second base language to be selected."
  :type 'integer
  :group 'auto-lang)

(defcustom al-min-matches 2
  "*How many words have to match for a language to be considered a winner."
  :type 'integer
  :group 'auto-lang)

(defcustom al-check-buffer-initially nil
  "*Whether to start checking the whole buffer if auto-lang is switched on.
This is potentially very annoying with large buffers."
  :type 'boolean
  :group 'auto-lang)

(defcustom al-buffer-limit 1000
  "*Check only defined number of characters.
Do not check the whole buffer but only the defined number of characters
around point if set."
  :type '(choice :tag "Limit to chars around point"
                (const :tag "None" nil)
                (integer :tag "Number"))
  :group 'auto-lang)

(defcustom al-check-visible-area-only t
  "*Check only the currently visible area.
Whether to check only the currently visible area if
other options would extend checking beyond."
  :type 'boolean
  :group 'auto-lang)

(defcustom al-check-paragraph t
  "*Whether to check only the current paragraph instead of the whole buffer."
  :type 'boolean
  :group 'auto-lang)

(defcustom al-use-goodies 'flyspell
  "*Whether to use packages that make working with auto-lang nicer.
Choice `ispell' selects the `ispell-local-dictionary'
   according to the guessed language.
Choice `flyspell' does on-the-fly spell checking in addition.
   Requires ispell."
  :type '(choice :tag "Use additional packages "
                (const :tag "None" nil)
                (const :tag "ispell" ispell)
                (const :tag "flyspell" flyspell))
;  :set (lambda (variable value) ;; !!! variable+value not really used
;         (unless (eq al-use-goodies 'flyspell) ;; switch flyspell off if not wanted
;             (al-flyspell-off)))
  :group 'auto-lang)

(defcustom al-check-paragraph t
  "*Whether to check only the current paragraph instead of the whole buffer."
  :type 'boolean
  :group 'auto-lang)

(defcustom al-highlight-winner-lang nil
  "*Whether to highlight the words used for determining the winner language."
  :type 'boolean
  :group 'auto-lang)

; ------------------------------------------------------------------------

; Minor mode
(defvar auto-lang-minor-mode nil
  "Non-nil if auto-lang minor mode is enabled.")

;; Variable indicating that auto-lang minor mode is active.
(make-variable-buffer-local 'auto-lang-minor-mode)

; !!! set to 1 or 0 in release versions: (maybe use auto-lang-version for determining that...)
(defvar al-verbosity 0
 "Verbosity of auto-lang.  0 = no messages, 3 = chatty.
Shows the level of a message in front of it (`L3: [...]').")

;; idea from Simon Josefsson's nnimap.el:
(defvar al-debug nil
  "Name of buffer to record debugging info.
For example: (setq al-debug \"*al-debug*\")")

(defvar al-current-winner-lang nil
 "Dictionary which was selected last time the check was run.  Buffer-local.")
(make-variable-buffer-local 'al-current-winner-lang)

(defvar al-current-winner-lang-dict-avail nil
 "Whether the current winner language has a dictionary available.  Buffer-local.")
(make-variable-buffer-local 'al-current-winner-lang-dict-avail)

(defun al-flyspell-off ()
  "Switch flyspell minor mode off, deleting overlays."
  (unless (not (fboundp 'flyspell-mode)) ; flyspell needs to be available
    (flyspell-mode -1)
    (flyspell-delete-all-overlays)))

(defun al-flyspell-off-and-self-insert ()
  "Switch flyspell minor mode off, deleting overlays.  Run original command."
  (interactive)
  (setq al-current-winner-lang "default")
  (if (or (eq al-use-goodies 'ispell)
          (eq al-use-goodies 'flyspell))
      (setq ispell-local-dictionary "default"))
  (setq al-has-confidence nil)
  (al-make-modeline nil)
  (al-flyspell-off)
  (if (>= al-verbosity 3)
      (message "L3: Deleting flyspell overlays and setting language to default with no confidence."))
  ;; now delegate to the command normally called for the key
  ;; "let*" makes sure that auto-lang-minor-mode is bound nil before
  ;; the call to `key-binding' is made
  ;; [after a suggestion by Stefan Monnier]
;;  (message "auto-lang-minor-mode: %s" auto-lang-minor-mode)
  (let* ((auto-lang-minor-mode nil)
;;         (temp (message "auto-lang-minor-mode: %s" auto-lang-minor-mode))
         (kb (key-binding (this-command-keys))))
    (when kb (command-execute kb))))

;; (setq Y 2)
;; (let ((Y 1)
;;       (Z Y))
;;   (list Y Z))
;;
;; (setq Y 2)
;; (let* ((Y 1)
;;        (Z Y))
;;   (list Y Z))

;; from whitespace.el:
(defun al-set-modeline ()
  "Force the mode line update for different flavors of Emacs."
  (if (fboundp 'redraw-modeline)
      (redraw-modeline)                 ; XEmacs
    (force-mode-line-update)))          ; Emacs

(if (not (assoc 'auto-lang-minor-mode minor-mode-alist))
    (setq minor-mode-alist (cons '(auto-lang-minor-mode al-mode-line-string)
                                 minor-mode-alist)))

(defvar al-minor-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map " " 'al-running-lang) ; space
    ;; !!! all this should be nicer:
    (define-key map [prior] 'al-flyspell-off-and-self-insert) ; PageUp
    (define-key map [next]  'al-flyspell-off-and-self-insert) ; PageDn
    (define-key map [(control end)]  'al-flyspell-off-and-self-insert) ; end-of-buffer
    (define-key map [(control home)] 'al-flyspell-off-and-self-insert) ; beginning-of-buffer
;;  (define-key map "\r" 'al-running-lang) ; return
    map)
  "Keymap used for auto-lang minor mode.")

(or (not (boundp 'minor-mode-map-alist))
    (assoc 'auto-lang-minor-mode minor-mode-map-alist)
    (setq minor-mode-map-alist
          (cons (cons 'auto-lang-minor-mode al-minor-keymap)
                minor-mode-map-alist)))

(defun auto-lang-minor-mode (&optional arg)
  "Toggle auto-lang minor mode.
With prefix ARG, turn auto-lang minor mode on iff arg is positive."
  (interactive "P")
  (if (eq al-use-goodies 'ispell)
      (require 'ispell))
  (if (eq al-use-goodies 'flyspell)
      (progn
        ;; flyspell needs overlay mode but doesn't require it itself.
        ;; XEmacs want to see the require though:
        (and (let (case-fold-search)
               (string-match "XEmacs\\|Lucid\\|Epoch" emacs-version))
             (not (require 'overlay))
             (error "`auto-lang' requires the `overlay' package"))
        (require 'flyspell)))
  (setq auto-lang-minor-mode
        (not (or (and (null arg) auto-lang-minor-mode)
                 (<= (prefix-numeric-value arg) 0))))
  (al-set-modeline) ; update modeline
  ;; switch on/off flyspell:
  (if auto-lang-minor-mode
      (if (eq al-use-goodies 'flyspell)
          (if al-check-buffer-initially
              (if (fboundp 'flyspell-region)
                  (al-mute-message
                   (flyspell-region (window-start) (window-end)))))
        (al-flyspell-off))))

; stolen from the original count-matches from replace.el
(defun al-count-matches (regexp)
  "Return number of matches for REGEXP following point."
  (let ((count 0) opoint)
    (save-excursion
     (while (and (not (eobp))
                 (progn (setq opoint (point))
                        (re-search-forward regexp nil t)))
       (if (= opoint (point))
           (forward-char 1)
         (setq count (1+ count))))
     (number-to-string count))))

(defun al-guess-buffer-language ()
  "Give back the word count for each defined language.
Buffer should be narrowed if wanted."
  (save-excursion
    (goto-char (point-min))
    ;; Use dictionary names for the language.
    (let* ((countL (mapcar
                    (lambda (x)
                      (cons (cons (string-to-number
                                   (al-count-matches (nth 1 x)))
                                  (nth 0 x)) (nth 2 x))
                      ) al-lang-dict-list)
                   ))
      countL)))

; confidence-interval=(+-)1,96*(sigma/sqrt(count))
; [sigma=2.5, count=50 --> 0,6929]
; sigma = standard deviation
; number = 1.96 (95% confidence)
;
(defun al-calc-confidence-interval (number sigma count)
  "Calculate confidence-interval from NUMBER, SIGMA and COUNT."
  (save-excursion
    (if (> count 0) ; take care of divide by 0 error
        (* number (/ sigma (sqrt count)))
      0)))

(defun al-check-peak (needed-factor winner second)
  "Check for enough confidence difference.
Check that there is enough confidence difference (NEEDED-FACTOR)
between first (WINNER) and second (SECOND) language in list."
  (if (string-equal (cdr winner) (cdr second))
      ;; same base language
      (< needed-factor (/ (car winner) (car second)))))

(defun al-limit-buffer-maybe ()
  "Narrow buffer to limit as set in `al-buffer-limit' if defined."
  (if al-buffer-limit
      (narrow-to-region (save-excursion (backward-char al-buffer-limit)
                                        (forward-word 1) (point)) ;; make sure we check word boundaries
                        (save-excursion (forward-char al-buffer-limit)
                                        (backward-word 1) (point)))))

(defun al-narrow-to-paragraph ()
  "Narrow to paragraph (or its visible portion).
This also works with the first par in Gnus."
  (if al-check-visible-area-only
      ;; narrow if backward-sentence < window-start
      ;;        or forward-paragraph > window-end
      (narrow-to-region (max (window-start) (save-excursion (backward-sentence) (point)))
                        (min (window-end)   (save-excursion (forward-paragraph) (point))))
    (narrow-to-region (save-excursion (backward-sentence) (point))
                      (save-excursion (forward-paragraph) (point)))))

; ripped off Kai Grossjohann's message-x.el and modified a bit:
(defun al-in-message-header-p ()
  "Returns t iff point is in the header section."
  (save-excursion
    (let ((p (point)))
      (goto-char (point-min))
      (and (re-search-forward (concat "^"
                                      (regexp-quote mail-header-separator)
                                      "$") (1- (point-max)) t)
           (progn (beginning-of-line) t)
           (< p (point))))))
;;; maybe doing it like this is nicer (from Per Abrahamsen):
;; (defun message-do-auto-fill ()
;;   "Like `do-auto-fill', but don't fill in message header."
;;   (debug)
;;   (when (> (point) (save-excursion (rfc822-goto-eoh)))
;;     (do-auto-fill)))


(defun al-make-modeline (lang)
  "Generate and set the new modeline part for auto-lang.
If the language can be determined with enough confidence
but has no available dictionary, LANG is put in curly brackets.
If the language cannot be determined with enough confidence,
LANG is put in square brackets.
After the slash,
`i' is shown when ispell is used,
`f' is shown when flyspell is used.
`p' is shown when auto-lang operates in paragraph mode,
`b' denotes buffer mode."
  (if (not (string-equal al-mode-abbrev-string "")) ; unless user wants no modeline...
      (if al-has-confidence
          (if al-current-winner-lang-dict-avail
              (setq al-mode-line-string (concat al-mode-abbrev-string ":" lang "/"
                                                (if (eq al-use-goodies 'flyspell)
                                                    "f"
                                                  (if (eq al-use-goodies 'ispell)
                                                      "i"))
                                                (if al-check-paragraph "p" "b")))
            ;; enough confidence, but no dictionary available:
            (setq al-mode-line-string (concat al-mode-abbrev-string ":{" lang "}" "/"
                                              (if (eq al-use-goodies 'flyspell)
                                                  "f"
                                                (if (eq al-use-goodies 'ispell)
                                                    "i"))
                                              (if al-check-paragraph "p" "b"))))
        ;; no confidence:
        (if lang
            (setq al-mode-line-string (concat al-mode-abbrev-string ":[" lang "]" "/"
                                              (if (eq al-use-goodies 'flyspell)
                                                  "f"
                                                (if (eq al-use-goodies 'ispell)
                                                    "i"))
                                              (if al-check-paragraph "p" "b")))
          ;; lang == nil
          (setq al-mode-line-string (concat al-mode-abbrev-string "/"
                                            (if (eq al-use-goodies 'flyspell)
                                                "f"
                                              (if (eq al-use-goodies 'ispell)
                                                  "i"))
                                            (if al-check-paragraph "p" "b")))))
    (setq al-mode-line-string ""))
  (al-set-modeline))

(defun al-enough-confidence (winner-lang)
  "This function is called with the winner language (WINNER-LANG) as a parameter."
  (if (or (eq al-use-goodies 'ispell)
          (eq al-use-goodies 'flyspell))
      (if (not (assoc winner-lang ispell-dictionary-alist))
          ;; do it only the first time a new dictionary is used:
          (if (string-equal al-current-winner-lang winner-lang)
              (if (>= al-verbosity 1)
                  (message "L1: Already using this winner-lang/dictionary: %s/%s"
                           winner-lang al-current-winner-lang))
            ;; have two messages, one for use with flyspell and one without:
            (message
             "No dictionary available for language %s. Please customize `al-lang-dict-list'. Switching off flyspell if used."
             winner-lang)
            (setq al-current-winner-lang winner-lang)
            (setq al-current-winner-lang-dict-avail nil)
            (if (eq al-use-goodies 'flyspell)
                (al-flyspell-off)))
        (setq al-current-winner-lang-dict-avail t)
        (setq al-current-winner-lang winner-lang)
        (setq ispell-local-dictionary winner-lang)
        (if (>= al-verbosity 3)
            (message "L3: Setting ispell-local-dictionary to %s" winner-lang))))
  (setq al-has-confidence t)
  (al-make-modeline winner-lang))

(defun al-not-enough-confidence (winner-lang)
  "Called when there is not enough confidence.
This function is called when there is not enough confidence to pick
one language as winner.  WINNER-LANG is used to give feedback about
the most likely winner."
  (if (>= al-verbosity 2)
      (message "L2: Not enough confidence. Switching off flyspell-mode. winner-lang: %s"
               winner-lang))
  (setq al-current-winner-lang "default")
  (if (or (eq al-use-goodies 'ispell)
          (eq al-use-goodies 'flyspell))
      (setq ispell-local-dictionary "default")) ;; (ispell-change-dictionary "default")
  (setq al-has-confidence nil)
  (al-make-modeline winner-lang)
  (if (eq al-use-goodies 'flyspell)
      (al-flyspell-off)))

;; stolen from XEmacs' simple.el, modified to work with GNU Emacs
;; (count-words-buffer is in XEmacs but not in GNU Emacs)
(defun al-count-words-region (start end)
  "Print the number of words in region between START and END in the current buffer."
  (save-excursion
    (set-buffer (current-buffer))
    (let ((words 1))
      (goto-char start)
      (while (< (point) end)
        (when (forward-word 1)
          (setq words (+ 1 words))))
      ;;  (incf words))) ;; incf is only XEmacs...
      words)))

;; from httpd.el by Eric Marsden:
(defmacro al-mute-message (&rest forms)
  "Redefine message to be silent.
I don't know what FORMS does."
  `(let ((old-message (symbol-function 'message)))
    (fset 'message (lambda (fmt &rest args) nil))
    (unwind-protect
        (progn ,@forms)
      (fset 'message old-message))))

(defvar al-flyspell-current-dict nil)

(defun al-do-flyspell-maybe ()
  "Run flyspell if it makes sense.
Run flyspell in the buffer or narrowed region if enough confidence
and not in message header."
  (when (fboundp 'flyspell-mode)
    (if (and al-has-confidence al-current-winner-lang-dict-avail)
	;; flyspell should be on with current dict.  reset it if it isn't.
	(when (or (not flyspell-mode)
		  (not (equal al-flyspell-current-dict 
			      ispell-local-dictionary)))
	  (setq al-flyspell-current-dict ispell-local-dictionary)
	  (al-flyspell-off)
	  (let ((flyspell-issue-welcome-flag nil))
	    (flyspell-mode 1)
	    (lexical-let ((min (point-min))
			  (max (point-max)))
	      (run-with-idle-timer 0 nil (lambda ()
					   (al-mute-message
					    (flyspell-region min max)))))))
      ;; flyspell should be off.
      (when flyspell-mode
	(al-flyspell-off)))))

(defun al-check-base-diff (first-list second-list)
  "Check if the confidences of FIRST-LIST and SECOND-LIST differ enough."
  (if (> (nth 2 first-list)  0) ; first language has a confidence > 0
      (if (> (nth 2 second-list) 0) ; second language has a confidence > 0
          ;; first argument to al-check-peak: confident if winner-conf = ARG * second-conf:
          (if (< al-necessary-conf-diff (/ (nth 2 first-list) (nth 2 second-list)))
              (car first-list) ; return the base language
            nil) ; return nil
        (if (>= al-verbosity 1)
            (message "L1: Second has language has a confidence of 0, returning winner."))
        (car first-list)) ; return the first language if the second has a confidence of 0
    nil)) ; return nil if even the first language does not match

(defun al-sort-base-langs (in-list)
  "Give back the two winners of base language.
IN-LIST is e.g.:
\(\(english english 0.1632993161855452\)
 \(english american 0.1632993161855452\)
 \(english british 0.1632993161855452\)
 \(german deutsch 0.0\)
 ...\)"
  (let (out-list)
    ;; compare the first two base languages:
    (while (string-equal (car (car in-list)) (car (car (cdr in-list))))
      ;; cut off until the base languages differ:
      (setq in-list (cdr in-list)))
    ;; run check if the different base languages have enough difference in confidence value:
    (al-check-base-diff (car in-list) (car (cdr in-list)))))

(defun al-lang-conf (list)
  "Check the confidence for the languages in LIST and take actions based on that criteria."
  ;; !!! document `list'
  ;; !!! make all this let's, pull out the re-used values and name them
  (setq result-list-long nil)
  (while list
    (setq result-lang (cdr (car list)))
    ;; !!! what is result-langf?
    (setq result-langf (cdr (car (car list))))
    ;; what is a good value for the first argument of al-calc-confidence-interval (1.96)?
    (setq result-conf (al-calc-confidence-interval ;; args: number sigma count
                       ;; !!! make this a constant to speed up things a bit:
                       (/ (sqrt 2) 10) ; gives confidence of 1 if all match
                       (car (car (car list)))
                       (al-count-words-region (point-min) (point-max))))
    (unless (>= (car (car (car list))) al-min-matches)
      (setq result-conf 0))
    (setq result-list (list result-lang result-langf result-conf))
    (setq result-list-long (cons result-list result-list-long))
    ;; make list shorter:
    (setq list (cdr list)))
    (setq result-list-long
          (sort result-list-long (function (lambda (a b) (> (nth 2 a) (nth 2 b))))))
    (if (al-sort-base-langs result-list-long) ; if not nil (== enough confidence)
	(progn
;;	  (al-find-encoding (nth 1 (car result-list-long)))
	  (al-enough-confidence (nth 1 (car result-list-long))))
      (if (> (nth 2 (car result-list-long)) 0 )
          (al-not-enough-confidence (nth 1 (car result-list-long)))
        (al-not-enough-confidence "default"))))

(defun al-find-encoding ()
  "Find out the used encoding in the buffer."
  (interactive) ; !!!
  (setq umlaut-8bit-regexp "ä\\|ö\\|ü\\|ß\\|Ä\\|Ö\\|Ü")
  ;; maybe take out "ss" here: finds stuff like "Virusscanner"
  (setq umlaut-7bit-regexp "ae\\|oe\\|ue\\|ss\\|Ae\\|Oe\\|Ue\\|AE\\|OE\\|Ue\\|SS")
  ;; in TeX mode, sentence quoting is *not* done like "a test sentence",
  ;; but in a normal ASCII text it could:
  (if (or (string-equal major-mode "TeX-mode")
	  (string-equal major-mode "LaTeX-mode")
	  (string-equal major-mode "tex-mode")
	  (string-equal major-mode "latex-mode"))
      (progn
	(message "TeX mode!") (sit-for 1)
	(setq umlaut-tex-regexp "\"a\\|\"o\\|\"u\\|\"s\\|\"A\\|\"O\\|\"U"))
    (message "Non-TeX mode!") (sit-for 1)
    ;; !!! tweak that: don't count if at beginning of word if not in a TeX mode
    (setq umlaut-tex-regexp "\\b\\(\"a\\|\"o\\|\"u\\|\"s\\|\"A\\|\"O\\|\"U\\)"))
  (save-excursion
    (goto-char (point-min))
    (message "German umlauts: %s 8bit encoding, %s in 7bit encoding, %s in TeX encoding."
	     (al-count-matches umlaut-8bit-regexp)
	     (al-count-matches umlaut-7bit-regexp)
	     (al-count-matches umlaut-tex-regexp))
    (al-highlight-regexp-region (point-min) (point-max)
				(eval umlaut-8bit-regexp) 'al-8bit-face)
    (al-highlight-regexp-region (point-min) (point-max)
				(eval umlaut-7bit-regexp) 'al-7bit-face)
    (al-highlight-regexp-region (point-min) (point-max)
				(eval umlaut-tex-regexp) 'al-common-face)
  ))
;; for testing, correct highlighting marked:
;; dass fuer f"ur für daf"ur "Uhr" "Ueber" "aendern" "anderen" "bl"attern"
;; --^^--^^---^^---^-----^^---------^^------^^--------------------^^------

(defun al-message-narrow-to-body ()
  "Narrow to the body of a message while composing it in Gnus."
  (narrow-to-region
   (progn
     (goto-char (point-min))
     (or (search-forward mail-header-separator nil t)
         (point-max)))
   (point-max)))

(defun al-running-lang (char)
  "The main auto-lang function.
Insert the character CHAR typed (should be bound to SPC), narrow according
to customization/mode and run `al-lang-conf'."
  (interactive "p")
  (self-insert-command char)
  (if (string-equal major-mode "message-mode")
      (if (al-in-message-header-p)
          (progn
            (if (>= al-verbosity 3)
                (message "L3: Gnus article creation, in header."))
            (if (eq al-use-goodies 'flyspell)
                (al-flyspell-off))
            (setq al-mode-line-string (concat al-mode-abbrev-string
                                              (if al-check-paragraph "/p" "/b")))
            (al-set-modeline))
        (if (>= al-verbosity 3)
            (message "L3: Gnus article creation, in body."))
        (save-window-excursion
          (if al-check-paragraph ; paragraph mode in Gnus
              (save-excursion
                (save-restriction
                  ;; ;; make sure only the current paragraph gets flyspelled
                  ;; ;; (and other pars have their overlays removed):
                  ;; (if (eq al-use-goodies 'flyspell)
                  ;;     (al-flyspell-off))
                  (al-narrow-to-paragraph)
                  (al-lang-conf (al-guess-buffer-language))
                  (if (eq al-use-goodies 'flyspell)
                      (al-do-flyspell-maybe))
                  (if al-highlight-winner-lang
                      (al-highlight-winner-lang))))
            (save-excursion ; buffer mode in Gnus
              (save-restriction
                (al-message-narrow-to-body)
                (al-lang-conf (al-guess-buffer-language))
                (if (eq al-use-goodies 'flyspell)
                    (al-do-flyspell-maybe))
                (if al-highlight-winner-lang
                    (al-highlight-winner-lang)))))))
    (save-window-excursion
      (if al-check-paragraph
          (save-restriction ; paragraph mode
            (al-narrow-to-paragraph)
            (al-lang-conf (al-guess-buffer-language))
            (if (eq al-use-goodies 'flyspell)
                (al-do-flyspell-maybe))
            (if al-highlight-winner-lang
                (al-highlight-winner-lang)))
        (save-excursion ; buffer mode
          (save-restriction
            (al-limit-buffer-maybe)
            (al-lang-conf (al-guess-buffer-language))
            (if (eq al-use-goodies 'flyspell)
                (al-do-flyspell-maybe))
            (if al-highlight-winner-lang
                (al-highlight-winner-lang))))))))

(when al-debug
  (require 'trace)
  (buffer-disable-undo (get-buffer-create al-debug))
  (mapcar (lambda (f) (trace-function-background f al-debug))
          ;; add functions to trace here:
          '(
            al-lang-conf
            al-check-peak
            al-check-base-diff
            al-sort-base-langs
            al-not-enough-confidence
            al-enough-confidence
            )))

;; ==============================================================================
;; * The variables containing the language stopwords
;; ==============================================================================

(defgroup auto-lang-wordlists nil
  "Lists of stopwords for the supported languages."
  :group 'auto-lang
  :prefix "al-")

;; Benjamin Drieu's list of american words:
; -
; a
; all
; an
; and
; are
; as
; at
; be
; but
; by
; for
; from
; has
; have
; he
; his
; i
; in
; is
; it
; not
; of
; on
; one
; or
; people
; q
; s
; that
; the
; there
; they
; this
; to
; was
; we
; what
; which
; who
; will
; with
; would
; you
;

;;; some more stopwords:
;; a
;; about
;; above
;; according
;; across
;; actual
;; added
;; after
;; against
;; ahead
;; all
;; almost
;; alone
;; along
;; also
;; among
;; amongst
;; an
;; and
;; and-or
;; and/or
;; anon
;; another
;; any
;; are
;; arising
;; around
;; as
;; at
;; awared
;; away
;; be
;; because
;; become
;; becomes
;; been
;; before
;; behind
;; being
;; below
;; best
;; better
;; between
;; beyond
;; birthday
;; both
;; but
;; by
;; can
;; certain
;; come
;; comes
;; coming
;; completely
;; concerning
;; consider
;; considered
;; considering
;; consisting
;; de
;; department
;; der
;; despite
;; discussion
;; do
;; does
;; doesnt
;; doing
;; down
;; dr
;; du
;; due
;; during
;; each
;; either
;; especially
;; et
;; few
;; for
;; forward
;; from
;; further
;; get
;; give
;; given
;; giving
;; has
;; have
;; having
;; his
;; honor
;; how
;; in
;; inside
;; instead
;; into
;; is
;; it
;; items
;; its
;; just
;; let
;; lets
;; little
;; look
;; looks
;; made
;; make
;; makes
;; making
;; many
;; meet
;; meets
;; more
;; most
;; much
;; must
;; my
;; near
;; nearly
;; next
;; not
;; now
;; of
;; off
;; on
;; only
;; onto
;; or
;; other
;; our
;; out
;; outside
;; over
;; overall
;; per
;; possibly
;; pt
;; put
;; really
;; regarding
;; reprinted
;; same
;; seen
;; several
;; should
;; shown
;; since
;; so-called
;; some
;; spp
;; studies
;; study
;; such
;; take
;; taken
;; takes
;; taking
;; than
;; that
;; the
;; their
;; them
;; then
;; there
;; therefrom
;; these
;; they
;; this
;; those
;; through
;; throughout
;; to
;; together
;; toward
;; towards
;; under
;; undergoing
;; up
;; upon
;; upward
;; various
;; versus
;; very
;; via
;; vol
;; vols
;; vs
;; was
;; way
;; ways
;; we
;; were
;; what
;; whats
;; when
;; where
;; which
;; while
;; whither
;; who
;; whom
;; whos
;; whose
;; why
;; with
;; within
;; without
;; yet
;; you
;; your


(defcustom al-english-common-words
  '(
    "and"
    "are"
    "at"
    "be"
    "been"
    "but"
    "by"
    "for"
    "have"
    "he"
    "is"
    "it"
    "me"
    "my"
    "not"
    "of"
    "or"
    "she"
    "some"
    "that"
    "than"
    "the"
    "this"
    "to"
    "us"
    "we"
    "with"
    "you"
    "your"
    "yours")
  "List of English stopwords which only require 7-bit encoding and are common in both British and American english.
British and American are differentiated by matching word endings."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-english-common-regexp
  (concat "\\<\\("
          (regexp-opt
           (append
            al-english-common-words
            nil)) "\\)\\>")
  "Regular Expression to identify english words common in both British
and American english.")

;; \w word-syntax character.
;; \B=not beginning or end of word.
;; "or" can also occur in things like "minor", don't check for it.
(defvar al-american-regexp
  (concat "\\<\\("
          (regexp-opt
           (append
            al-english-common-words
            nil)) "\\)\\>\\|\\w\\w\\(yze\\|yzed\\|ized\\)\\>")
  "Regular Expression to identify english words in American spelling.")

;; \w word-syntax character.
;; Need two of them b/c otherwise "your" would match the \\B regexp
;; and wrongly find a 'british' word.
;; "demise" would match "ise", don't check for it.
;; "promised" would match "ised", don't check for it.
(defvar al-british-regexp
  (concat "\\<\\("
          (regexp-opt
           (append
            al-english-common-words
            nil)) "\\)\\>\\|\\w\\w\\(yse\\|ysed\\|our\\)\\>")
  "Regular Expression to identify english words in British spelling.")

; ------------------------------------------------------------------------------

;; Benjamin Drieu's list of German words:
; aber
; als
; an
; auch
; auf
; aus
; ber
; da
; das
; dem
; den
; der
; des
; die
; ein
; eine
; einen
; er
; es
; fin
; haben
; hat
; hatte
; ihr
; im
; in
; ist
; man
; mit
; nach
; nicht
; noch
; nur
; r
; sich
; sie
; sind
; so
; um
; und
; von
; war
; wie
; zu

(defcustom al-german-common-words
   '(
     "ab"
     "aber"
     "als"
     "andere"
     "anderem"
     "anderen"
     "andererseits"
     "anderes"
     "anders"
     "auf"
     "aufweisen"
     "aufweisende"
     "aufweisenden"
     "aus"
     "bei"
     "beide"
     "beidem"
     "beiden"
     "beides"
     "beim"
     "beispielsweise"
     "bereits"
     "bestimmt"
     "bestimmte"
     "bestimmtem"
     "bestimmten"
     "bestimmter"
     "bestimmtes"
     "bevor"
     "bis"
     "bisher"
     "bzw"
     "da"
     "dabei"
     "dadurch"
     "dagegen"
     "daher"
     "damit"
     "danach"
     "dann"
     "daran"
     "darauf"
     "daraus"
     "darin"
     "darunter"
     "das"
     "davon"
     "dazu"
     "dem"
     "demselben"
     "den"
     "denen"
     "denselben"
     "der"
     "derart"
     "deren"
     "derer"
     "derselben"
     "des"
     "desselben"
     "dessen"
     "diese"
     "diesem"
     "diesen"
     "dieser"
     "dieses"
     "doch"
     "dort"
     "du"
     "durch"
     "eben"
     "ebenfalls"
     "ein"
     "eine"
     "einem"
     "einen"
     "einer"
     "einerseits"
     "eines"
     "einzeln"
     "einzelne"
     "einzelnem"
     "einzelnen"
     "einzelner"
     "einzelnes"
     "entsprechend"
     "entsprechende"
     "entsprechendem"
     "entsprechenden"
     "entsprechender"
     "entsprechendes"
     "entweder"
     "er"
     "erst"
;     "es" ;; french?
     "etwa"
     "etwas"
     "falls"
     "ganz"
     "gegebenenfalls"
     "gegen"
     "gekennzeichnet"
     "gemeinsam"
     "genau"
     "ggf" ;???
     "haben"
     "hat"
     "hinter"
     "ich"
     "ihre"
     "ihrem"
     "ihren"
     "ihrer"
     "ihres"
     "im"
     "immer"
     "indem"
     "infolge"
     "insbesondere"
     "insgesamt"
     "ist"
;     "je" ;; french?
     "jede"
     "jedem"
     "jeden"
     "jeder"
     "jedes"
     "jedoch"
     "kann"
     "kein"
     "keine"
     "keinem"
     "keinen"
     "keiner"
     "keines"
     "mal"
     "mehr"
     "mehrere"
     "mehreren"
     "mehrerer"
     "mit"
     "mittels"
     "nach"
     "nacheinander"
     "neben"
     "nicht"
     "noch"
     "nur"
     "ob"
     "oberhalb"
     "oder"
     "ohne"
     "sehr"
     "selbst"
     "sich"
     "sie"
     "sind"
     ;; "so" ;; also in English
     "sobald"
     "sofern"
     "sofort"
     "solange"
     "somit"
     "sondern"
     "sowie"
     "sowohl"
     "statt"
     "teils"
     "teilweise"
     "um"
     "und"
     "unter"
     "unterhalb"
     "usw"
     "vom"
     "von"
     "vor"
     "vorher"
     "warum"
     "wegen"
     "weil"
     "weiter"
     "weiterhin"
     "weitgehend"
     "welche"
     "welchem"
     "welchen"
     "welcher"
     "welches"
     "wenigstens"
     "wenn"
     "werden"
     "wie"
     "wieder"
     "wird"
     "wo"
     "wobei"
     "wodurch"
     "worauf"
     "worden"
     "worin"
     "wurde"
     "zu"
     "zueinander"
     "zugleich"
     "zum"
     "zumindest"
     "zur"
     "zusammen"
     "zwar"
     "zwecks"
     "zwischen")
  "List of German stopwords which only require 7-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)
; !!! Too many words(?) !!!

(defcustom al-german-8bit-words
  '(
    "bezüglich"
    "dafür"
    "daß" ;; why doesn't GNU Emacs like that? [bug in Emacs20]
    "für"
    "gegenüber"
    "gemäß"
    "schließlich"
    "sodaß"
    "über"
    "während"
    "würde"
    "zunächst"
    "zusätzlich")
  "List of German stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-german-8bit-as-ascii-words
   '(
     "bezueglich"
     "dafuer"
     ;; "dass" ;; in New German this is a normal word...
     "fuer"
     "gegenueber"
     "gemaess"
     "schliesslich"
     "sodass"
     "ueber"
     "waehrend"
     "wuerde"
     "zunaechst"
     "zusaetzlich")
  "List of German stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-german-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-german-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify German words which only require 7-bit encoding.")

(defvar al-german-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-german-common-words
                       al-german-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify German words which cannot be encoded in 7 bits,
in 8-bit encoding.")

(defvar al-german-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-german-common-words
                     al-german-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify German words which cannot be encoded in 7 bits,
expressed in ASCII.")

; ------------------------------------------------------------------------------

;; Benjamin Drieu's list of french words:
; a
; au
; aux
; avec
; ce
; cette
; dans
; de
; des
; du
; e
; en
; est
; et
; il
; ils
; je
; la
; le
; les
; mais
; me
; ne
; nous
; on
; ont
; ou
; par
; pas
; plus
; pour
; que
; qui
; s
; se
; son
; sont
; sur
; un
; une
;

(defcustom al-french-common-words
   '(
     "et"
     "ou"
     "les"
;     "des" ;; also German
     "que")
  "List of French stopwords which only require 7-bit encoding.")

(defcustom al-french-8bit-words
  '(
    )
  "List of French stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-french-8bit-as-ascii-words
   '(
     )
  "List of French stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-french-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-french-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify French words which only require 7-bit encoding.")

(defvar al-french-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-french-common-words
                       al-french-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify French words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-french-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-french-common-words
                     al-french-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify French words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

;; Benjamin Drieu's list of Spanish words:
; a
; al
; an
; ante
; ayer
; cayetano
; como
; con
; cuando
; de
; del
; desde
; dos
; el
; en
; entre
; era
; es
; fiz
; fue
; ha
; la
; las
; le
; lo
; los
; me
; muy
; n
; no
; o
; os
; para
; pero
; phoenix
; por
; que
; s
; se
; ser
; sin
; sobre
; su
; sus
; todo
; un
; una
; y
; ya

;; most of the spanish words given to me by Victor Cortijo, thanks
(defcustom al-spanish-common-words
   '(
;;     "de" ;; also french (in names)
     "del"
     "el"
     "este"
     "esta"
     "esto"
     "gracias"
     "hola"
;     "la" ;; also french/italian?
     "las"
     "lo"
     "los"
     "saludo"
     ;; "un" ;; also italian
     ;; "una" ;; also italian
     ;; "uno" ;; also italian
     "que"
     "y")
  "List of Spanish stopwords which only require pure ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-spanish-8bit-words
  '(
    )
  "List of Spanish stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-spanish-8bit-as-ascii-words
   '(
     )
  "List of Spanish stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-spanish-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-spanish-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Spanish words which only require 7-bit encoding.")

(defvar al-spanish-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-spanish-common-words
                       al-spanish-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Spanish words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-spanish-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-spanish-common-words
                     al-spanish-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Spanish words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

; !!! what are the differences between Portugese and Brazilian? !!!
(defcustom al-portugese/brazilian-common-words
  '(
    "o"
    "uma"
    "os"
;     "e" ;; finds stuff like "e-mail"...
;     "para" ;; spanish too!
;     "ola" ;; spanish too (means "wave")
    "oi"
    "prezado"
    "obrigado"
    "Sds" ; saudações abbreviated
    )
  "List of Portugese/Brazilian stopwords which only require 7-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-portugese/brazilian-8bit-words
  '(
    "não"
    "olá" ;; this is portuguese only, not spanish. Good.
    "saudações"
    )
  "List of Portugese/Brazilian stopwords which cannot be encoded in
7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)
; !!! what ISO map is this?

(defcustom al-portugese/brazilian-8bit-as-ascii-words
  '(
    "nao"
;     "ola" ;; spanish too (means "wave")
    "saudacoes"
    )
  "List of Portugese/Brazilian stopwords which cannot be encoded in
7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-portugese/brazilian-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-portugese/brazilian-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Portugese/Brazilian words which only require 7-bit encoding.")

(defvar al-portugese/brazilian-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-portugese/brazilian-common-words
                       al-portugese/brazilian-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Portugese/Brazilian words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-portugese/brazilian-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-portugese/brazilian-common-words
                     al-portugese/brazilian-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Portugese/Brazilian words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

;; submitted by Henrik Hansen <hh(at)mailserver.dk>
;; got more from guess-lang.el (Ole Laursen submitted them to Benjamin)
(defcustom al-danish-common-words
  '(
    "af"
    "at"
    "blev"
    "brugt"
    "da"
;;    "de" ;; French (names)
;;    "den" ;; German
;;    "der" ;; German
;;    "det" ;; Swedish too
    "efter"
    "eller"
;;    "en" ;; Swedish too
    "er"
    "et"
;;    "for" ;; English
    "fordi"
    "fra"
    "fundes"
    "han"
    "hans"
    "har"
    "havde"
    "hjemme"
    "hvis"
    "hvor"
;;    "i"
    "ikke"
    "jeg"
    "kan"
    "kanon"
    "med"
    "men"
    "og"
;;    "om" ;; Swedish too
    "sejt"
    "sig"
    "skam"
    "som"
    "starter"
    "til"
    "var"
    "vi"
    "vil"
    "virkeligt"
    "virker"
    )
  "List of Danish stopwords which only require 7-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-danish-8bit-words
  '(
    "når"
    "nævnte"
    "også"
    "på"
    "så"
    )
  "List of Danish stopwords which cannot be encoded in
7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)
; !!! what ISO map is this?

(defcustom al-danish-8bit-as-ascii-words
  '(
    ;; !!! is the representation as ASCII correct?
    "nar"
    "naevnte"
    "ogsa"
    "pa"
    "sa"
    )
  "List of Danish stopwords which cannot be encoded in
7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-danish-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-danish-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Danish words which only require 7-bit encoding.")

(defvar al-danish-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-danish-common-words
                       al-danish-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Danish words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-danish-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-danish-common-words
                     al-danish-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Danish words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

;; submitted by Henrik Hansen <hh(at)mailserver.dk>
(defcustom al-latvian-common-words
  '(
    "sveiks"
    "ata"
    "ka"
    "iet"
    "kauns"
;;   "tu" ;; this is probably French too
;;   "es" ;; this is probably French too
    "vini"
    "turies"
    "mineji"
    )
  "List of Latvian stopwords which only require 7-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-latvian-8bit-words
  '(
    )
  "List of Latvian stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-latvian-8bit-as-ascii-words
   '(
     )
  "List of Latvian stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-latvian-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-latvian-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Latvian words which only require 7-bit encoding.")

(defvar al-latvian-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-latvian-common-words
                       al-latvian-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Latvian words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-latvian-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-latvian-common-words
                     al-latvian-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Latvian words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

;; submitted by Henrik Hansen <hh(at)mailserver.dk>
;; Here are some russian:
;;
;; privet
;; poka
;; kak
;; dela
;; oni
;; derzis
;; do vstreci
;; kruto

; ------------------------------------------------------------------------------

;; words from Benjamin Drieu's guess-lang.el:
(defcustom al-italian-common-words
   '(
     ;; "a" ;; english
     "ai"
     "al"
     "alla"
     ;; "alle" ;; german
     "anche"
     "anni"
     "che"
     "ci"
     ;; "come" ;; english
     "con"
     ;; "da" ;; e.g. german
     "dal"
     "dei"
     "del"
     "della"
     "delle"
     "di"
     "dopo"
     "due"
     ;; "e" ;; would catch e-mail
     "gli"
     "ha"
     "hanno"
     ;; "i" ;; english
     "il"
     ;; "in" ;; e.g. english, german
     "la"
     "le"
     ;; "lo" ;; also spanish
     "loro"
     "ma"
     "nel"
     "nella"
     ;; "non" ;; common prefix
     "o"
     "oggi"
     ;; "per" ;; common
     "quando"
     "questo"
     "se"
     "si"
     ;; "solo" ;; common
     "sono"
     "stato"
     "su"
     "sul"
     "sulla"
     "tra"
     "tutti"
     ;; "un" ;; spanish
     ;; "una" ;; spanish
     )
  "List of Italian stopwords which only require pure ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-italian-8bit-words
  '(
    )
  "List of Italian stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-italian-8bit-as-ascii-words
   '(
     )
  "List of Italian stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-italian-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-italian-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Italian words which only require 7-bit encoding.")

(defvar al-italian-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-italian-common-words
                       al-italian-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Italian words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-italian-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-italian-common-words
                     al-italian-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Italian words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

;; words from Benjamin Drieu's guess-lang.el:
(defcustom al-polish-common-words
   '(
     "ale"
     "bardzo"
     "bo"
     "byc"
     "czy"
     "dla"
     "jak"
     "jego"
     "jest"
     "jeszcze"
     "juz"
     "ma"
     "moze"
     "na"
     "od"
     "oraz"
     "po"
     "przez"
     "przy"
     "sa"
     "tak"
     "tego"
     "tylko"
     "tym"
     "w"
     "z"
     "za"
     "ze"
     "ze"
;;     "a"
;;     "i"
;;     "ten" ;; English
;;     "co" ;; matches co-operation
;;     "do" ;; English
;;     "ich" ;; German
;;     "nie" ;; German
;;     "o" ;; matches O'Brien
;;     "sie" ;; German
;;     "to" ;; English
     )
  "List of Polish stopwords which only require pure ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-polish-8bit-words
  '(
    "które"
    )
  "List of Polish stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-polish-8bit-as-ascii-words
   '(
    "ktore"
     )
  "List of Polish stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-polish-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-polish-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Polish words which only require 7-bit encoding.")

(defvar al-polish-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-polish-common-words
                       al-polish-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Polish words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-polish-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-polish-common-words
                     al-polish-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Polish words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

;; words from Benjamin Drieu's guess-lang.el:
(defcustom al-swedish-common-words
   '(
     "att"
     "av"
;;     "de" ;; French (names)
;;     "den" ;; German
;;     "det" ;; Danish too
     "efter"
     "eller"
;;     "en" ;; Danish too
     "ett"
     "han"
     "har"
     "hon"
;;     "i"
     "inte"
     "jag"
     "kan"
     "man"
     "med"
     "men"
     "nu"
     "och"
;;     "om" ;; Danish too
     "sig"
     "sin"
     "som"
     "till"
;;     "under" ;; English
     "var"
     "vi"
     "vid"
     )
   "List of Swedish stopwords which only require pure ASCII."
   :type '(repeat
	   (string :tag "stopword"))
   :group 'auto-lang-wordlists)

(defcustom al-swedish-8bit-words
  '(
     "där"
     "från"
     "för"
     "när"
     "också"
     "på"
     "säger"
     "så"
     "är"
     "år"
    )
  "List of Swedish stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-swedish-8bit-as-ascii-words
   '(
     ;; !!! is the representation as ASCII correct?
     "daer"
     "fran"
     "foer"
     "naer"
     "ocksa"
     "pa"
     "saeger"
     "sa"
     "aer"
     "ar"
     )
  "List of Swedish stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-swedish-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-swedish-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Swedish words which only require 7-bit encoding.")

(defvar al-swedish-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-swedish-common-words
                       al-swedish-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Swedish words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-swedish-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-swedish-common-words
                     al-swedish-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Swedish words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

(defcustom al-language-common-words
   '(
     )
   "List of Language stopwords which only require pure ASCII."
   :type '(repeat
	   (string :tag "stopword"))
   :group 'auto-lang-wordlists)

(defcustom al-language-8bit-words
  '(
    )
  "List of Language stopwords which cannot be encoded in 7 bits, in 8-bit encoding."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defcustom al-language-8bit-as-ascii-words
   '(
     ;; !!! is the representation as ASCII correct?
     )
  "List of Language stopwords which cannot be encoded in 7 bits, expressed in ASCII."
  :type '(repeat
          (string :tag "stopword"))
  :group 'auto-lang-wordlists)

(defvar al-language-common-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-language-common-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Language words which only require 7-bit encoding.")

(defvar al-language-common-8bit-regexp
  (concat "\\<\\(" (string-as-multibyte
                    (regexp-opt
                     (mapcar 'string-as-unibyte
                      (append
                       al-language-common-words
                       al-language-8bit-words
                       nil)))) "\\)\\>")
  "Regular Expression to identify Language words which cannot be
encoded in 7 bits, in 8-bit encoding.")

(defvar al-language-common-8bit-as-ascii-regexp
  (concat "\\<\\(" (regexp-opt
                    (append
                     al-language-common-words
                     al-language-8bit-as-ascii-words
                     nil)) "\\)\\>")
  "Regular Expression to identify Language words which cannot be
encoded in 7 bits, expressed in ASCII.")

; ------------------------------------------------------------------------------

(defcustom al-lang-dict-list
  `( ; look for backquote in the manual
;;;
;;;  ("dict-lang"  ,stopword-regexp                           "base-lang" "disp-lang" )
;;;  --------------------------------------------------------------------------------
     ("francais7"  ,al-french-common-8bit-as-ascii-regexp     "french"    "francais7" )
     ("francais8"  ,al-french-common-8bit-regexp              "french"    "francais8" )
     ("francais"   ,al-french-common-regexp                   "french"    "francais"  )
     ("spanish7"   ,al-spanish-common-8bit-as-ascii-regexp    "spanish"   "spanish7"  )
     ("spanish8"   ,al-spanish-common-8bit-regexp             "spanish"   "spanish8"  )
     ("spanish"    ,al-spanish-common-regexp                  "spanish"   "spanish"   )
     ("italian7"   ,al-italian-common-8bit-as-ascii-regexp    "italian"   "italian7"  )
     ("italian8"   ,al-italian-common-8bit-regexp             "italian"   "italian8"  )
     ("italian"    ,al-italian-common-regexp                  "italian"   "italian"   )
     ("portugese7" ,al-portugese/brazilian-common-8bit-as-ascii-regexp "portugese" "portugese7")
     ("portugese8" ,al-portugese/brazilian-common-8bit-regexp "portugese" "portugese8")
     ("portugese"  ,al-portugese/brazilian-common-regexp      "portugese" "portugese" )
     ("dansk7"     ,al-danish-common-8bit-as-ascii-regexp     "danish"    "dansk7"    )
     ("dansk8"     ,al-danish-common-8bit-regexp              "danish"    "dansk8"    )
     ("dansk"      ,al-danish-common-regexp                   "danish"    "dansk"     )
     ("swedish7"   ,al-swedish-common-8bit-as-ascii-regexp    "swedish"   "swedish7"  )
     ("swedish8"   ,al-swedish-common-8bit-regexp             "swedish"   "swedish8"  )
     ("swedish"    ,al-swedish-common-regexp                  "swedish"   "swedish"   )
     ("polish7"    ,al-polish-common-8bit-as-ascii-regexp     "polish"    "polish7"   )
     ("polish8"    ,al-polish-common-8bit-regexp              "polish"    "polish8"   )
     ("polish"     ,al-polish-common-regexp                   "polish"    "polish"    )
     ("latvian7"   ,al-latvian-common-8bit-as-ascii-regexp    "latvian"   "latvian7"  )
     ("latvian8"   ,al-latvian-common-8bit-regexp             "latvian"   "latvian8"  )
     ("latvian"    ,al-latvian-common-regexp                  "latvian"   "latvian"   )
     ("deutsch7"   ,al-german-common-8bit-as-ascii-regexp     "german"    "deutsch7"  )
     ("deutsch8"   ,al-german-common-8bit-regexp              "german"    "deutsch8"  )
     ("deutsch"    ,al-german-common-regexp                   "german"    "deutsch"   )
     ("british"    ,al-british-regexp                         "english"   "british"   )
     ("american"   ,al-american-regexp                        "english"   "american"  )
     ("english"    ,al-english-common-regexp                  "english"   "english"   )
    )
  "List of lists for mapping ispell's dictionary name, a stopword
Regular expression, a base language and display-name.

Order is important for the languages which have alternative spellings
or encodings. The derivate of the base language without any further
restriction must be the last one since this is chosen if all match
with the same confidence.

The first element of each list is the ispell dictionary name, then
comes the stopword Regular expression, the base language and finally a display
name, also used internally."
  :type '(repeat
          (list :tag "Languages" :indent 2
                (string :tag "ispell dictionary ")
                (regexp :tag "Language regexp   ")
                (string :tag "Base language     ")
                (string :tag "Display language  ")))
  :group 'auto-lang)

;; thrown together from pieces of Drew Adams' cool highlight package:
(defun al-highlight-regexp-region (start end regexp face)
  "Highlight regular expression REGEXP with FACE in region
from START to END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward regexp end t)
      (let ((inhibit-read-only t)
            (modified-p (buffer-modified-p)))
        (put-text-property (match-beginning 0) (match-end 0) 'face face)
        (set-buffer-modified-p modified-p))
      ;; Prevent `lazy-lock-mode' from unhighlighting.
      (when (and (fboundp 'lazy-lock-after-fontify-buffer) lazy-lock-mode)
        (lazy-lock-after-fontify-buffer)))))

(defface al-common-face
  '((((class color) (background light))
     (:foreground "blue" :background "LightGray"))
    (((class color) (background dark))
     (:foreground "blue" :background "LightGray"))
    (t ()))
  "Face for common words used in auto-lang."
  :group 'auto-lang-language-faces
  :group 'font-lock-highlighting-faces)

(defface al-8bit-face
  '((((class color) (background light))
     (:foreground "cornflower blue" :background "LightGray"))
    (((class color) (background dark))
     (:foreground "cornflower blue" :background "LightGray"))
    (t ()))
  "Face for words which require 8-bit encoding used in auto-lang."
  :group 'auto-lang-language-faces
  :group 'font-lock-highlighting-faces)

(defface al-7bit-face
  '((((class color) (background light))
     (:foreground "blue4" :background "LightGray"))
    (((class color) (background dark))
     (:foreground "blue4" :background "LightGray"))
    (t ()))
  "Face for 8-bit words expressed in 7-bit encoding used in auto-lang."
  :group 'auto-lang-language-faces
  :group 'font-lock-highlighting-faces)

(defgroup auto-lang-language-faces nil
  "Faces for highlighting."
  :group 'auto-lang
  :prefix "al-")

(custom-add-to-group
 'auto-lang-language-faces 'al-common-face 'custom-face)
(custom-add-to-group
 'auto-lang-language-faces 'al-8bit-face   'custom-face)
(custom-add-to-group
 'auto-lang-language-faces 'al-7bit-face   'custom-face)

(defun al-make-regexp (lang enc)
  "Create a (possibly undefined) language regexp from LANG and ENC."
  (intern (concat "al-" lang "-" (symbol-name enc) "-regexp")))

;;; !!! doesn't work yet, just for testing:
(defun al-highlight-winner-lang ()
  "Highlight words of al-current-winner-language in several encodings."
  (interactive)
  ;; only when there is something to highlight:
  (when (and al-current-winner-lang
            (not (string-equal al-current-winner-lang "default")))
    ;; !!! remove previous regexp's?
    (let ((regexp-common-8bit
           (al-make-regexp al-current-winner-lang 'common-8bit))
          (regexp-common-8bit-as-ascii
           (al-make-regexp al-current-winner-lang 'common-8bit-as-ascii))
          (regexp-common
           (al-make-regexp al-current-winner-lang 'common)))
      ;; check for undefined regexp's:
      (message "regexp-common-8bit: %s" regexp-common-8bit)
      (if (boundp regexp-common-8bit)
          (progn
            (message "  is bound")
            (al-highlight-regexp-region (point-min) (point-max)
                                        (eval regexp-common-8bit) 'al-8bit-face))
        (message "  is not bound"))

      (message "regexp-common-8bit-as-ascii: %s" regexp-common-8bit-as-ascii)
      (if (boundp regexp-common-8bit-as-ascii)
          (progn
            (message "  is bound")
            (al-highlight-regexp-region (point-min) (point-max)
                                        (eval regexp-common-8bit-as-ascii) 'al-7bit-face))
        (message "  is not bound"))

      (message "regexp-common: %s" regexp-common)
      (if (boundp regexp-common)
          (progn
            (message "  is bound")
            (al-highlight-regexp-region (point-min) (point-max)
                                        (eval regexp-common) 'al-common-face))
        (message "  is not bound")))))

;;; overlay-spread and -removal example, by Sam Padgett:
;; (defun my-mark-eob ()
;;   (let ((existing-overlays (overlays-in (point-max) (point-max)))
;; 	(eob-mark (make-overlay (point-max) (point-max) nil t t))
;; 	(eob-text "~~~"))
;;     ;; Delete any previous EOB markers.  Necessary so that they don't
;;     ;; accumulate on calls to revert-buffer.
;;     (dolist (next-overlay existing-overlays)
;;       (if (overlay-get next-overlay 'eob-overlay)
;; 	  (delete-overlay next-overlay)))
;;     ;; Add a new EOB marker.
;;     (put-text-property 0 (length eob-text)
;; 		       'face '(foreground-color . "slate gray") eob-text)
;;     (overlay-put eob-mark 'eob-overlay t)
;;     (overlay-put eob-mark 'after-string eob-text)))
;; (add-hook 'find-file-hooks 'my-mark-eob)


;;                                'al-8bit-face)
;;    (al-highlight-regexp-region (point-min) (point-max)
;;                                (eval (al-make-regexp al-current-winner-lang
;;                                                      'common-8bit-as-ascii))
;;                                'al-7bit-face)
;;    (al-highlight-regexp-region (point-min) (point-max)
;;                              (eval (al-make-regexp al-current-winner-lang
;;                                                    'common))
;;                              'al-common-face)))

;; (setq al-highlight-winner-lang t)
;; the and the   esto esta
;; (setq al-current-winner-lang "default")
;; (setq al-current-winner-lang "spanish")
;; (setq al-current-winner-lang "english")
;; (al-highlight-winner-lang)


;;(al-make-regexp "ger" 'common)
;5(al-highlight-regexp-region (point-min) (point-max)
;5                              (eval (al-make-regexp "english" 'common))
;5;                           al-english-common-regexp
;5;                           'al-common-face)
;5                              'al-7bit-face)


;; ==============================================================================

(provide 'auto-lang)

;; ==============================================================================

; Ideas/TODO:

; ! Have commands "auto-lang-guess-language-buffer" and
;   "auto-lang-guess-language-paragraph" that do what the name says.

; ! Use (executable-find "ispell") to see if ispell (or aspell) are
;   present on the system at all. Ideally, this would be in ispell.el.

; ! Check out the de, en, fr stopword lists at http://www.loria.fr/~bonhomme/sw/.

; ! Do independent statistics, where stopwords would select the
;   language and the number of "a versus ae versus ä (versus a",
;   versus \"a, versus...)  would select the encoding, and both
;   together would select the dictionary... (suggestion by Sven Utcke)

; ! auto-lang.el could be used to e.g. insert \selectlanguage commands
;   into LaTeX buffers.

; ! In buffer mode, it makes no sense to switch off flyspell and un-set
;   ispell-dictionary for the far-moving keys like (ctrl home) etc.

; ! In buffer mode in message-mode, skip quoted parts for determining
;   the language (ispell.el has functions for this).
;   (feature request by Sven Utcke)

; ! Make sure read-only buffers are handled gracefully.

; ! Let the user choose which languages she wants to test against. Not
;   everybody writes in all the supported languages... (idea from
;   Benjamin Drieu's guess-lang.el)

; ! If there are a lot of spelling errors, do not declare a winner
;   even though the normal calculation is fine. (Only do this if
;   ispell is available.)

; ! If one produces spaces on a line with no words, auto-lang should
;   pick up the next paragraph for checking.

; ! Thing to customize: sometimes, one word is not enough in a buffer
;   with many words. Have a minimum number of necessary matches, or
;   number of matches against buffer/paragraph word count.

; ! make most functions non-interactive

; ! add more documentation to functions and variables (and general
;   usage)

; ! make many setq's to let's

; * debug aid: temporarily spread an overlay over the paragraph that
;   is checked.

; * If there are two (or maybe three) consecutive SPC keystrokes,
;   switch off the language checking. User probably wants to indent
;   something.

; * Make a script which extracts all words of a language from a text
;   (.po-files would probably be good) and extract the most used
;   words (stopwords). (Check out textstats.el and concordance.el
;   from http://members.a1.net/t.link/filestats.html)

; * have a minimum buffer size before beginning to check language

; * if there are a lot of spelling errors (in German for instance),
;   check if they would not occur if you use another character
;   encoding for that language

; * Offer to set local variables at end of file when buffer is
;   associated to a file.

; * Check out
;   http://www.linuxcare.it/developers/davidw/files/two-mode-mode.el
;   "switches the entire buffer mode based on where your cursor is"

; * (setq ispell-extra-args (list "-w" "àâçèéêëïôùûüÀÂÇÈÊÉÏÔÙÛÜ"))

; * check if flyspell is byte-compiled (with byte-code-function-p or
;   compiled-function-p)

; * catch mouse movements (see GNU Emacs' which-function and
;   semantic-imenu's advice to that)

; * If a buffer/paragraph only contains e.g. "fuer für", then
;   'deutsch8' is selected unanimously. It should be '[deutsch]' however
;   (undecided), or maybe 'deutsch' (thus marking both entries
;   as wrong -- the writer has probably mixed these writings up
;   and wants to decide on only one).

; ------------------------------------------------------------------------

; ALREADY IMPLEMENTED:

; * make deutsch8 and deutsch7 etc. [DONE]

; * Use regexp-opt to build the regexp from a list of words. [DONE]

; * alist which consists of real language name, ispell dictionary
;   name and name symbol to be shown in the status line [DONE]

; * have everything customizable (via custom) (halfway DONE)

; * check for existance of an available dictionary for the selected
;   language (maybe check even physically with "locate"), offer to
;   customize the language-->dictionary relation if needed [DONE]

; * Have an easy to access function that jumps to a match for a
;   certain language.
;   Maybe this could even highlight matches, ideally in different
;   colors for each language. [DONE]

; ! fix "Arithmetic error!" when there is no empty line after the
;   first line [DONE]

; ! update modeline after customization of al-mode-line-string [DONE]

; ! if al-mode-line-string is "", then make sure that nothing
;   is printed at all [DONE]

; ! make ispell-dictionary buffer-local (is this possible?)
;   [DONE, use ispell-local-dictionary]

; ! make sure it works even without flyspell [DONE, works w/o ispell too]

; * if a variable (e.g. al-trace-buffer) is non-nil, write out
;   debugging information to this buffer [DONE]

; * More debugging functions. Use e.g. trace. [DONE]

; * use flyspell-region to check smaller regions if the buffer is
;   too large (custom variable for max-buffer-size)        [DONE]

; * have a variable al-version [DONE (auto-lang-version)]

; * <Cursor-up> etc. should switch off flyspell in a sensible way. [DONE]

; * make use of ispell and flyspell completely optional, even if
;   they are installed [DONE]

; * check if maybe regexp-opt-charset is important for regexp-opt
;   here [DONE, but different fix]

; When checking for confidence differences between the base
; languages, I probably should check the *best* confidence for a
; certain base language against the next base language (which is the
; best of *this* base language if sorted). Right now, just the two
; base languages adjacent to each other are compared.
;
; Example:
;
; (("german" "deutsch8" 0.3015113445777636)
; ("german" "deutsch" 0.2713602101199872)
; ("english" "english" 0.1206045378311054)
; ("english" "american" 0.1206045378311054)
; ("english" "british" 0.1206045378311054)
; ("portugese" "portugese8" 0.0)
; ("portugese" "portugese7" 0.0)
; ("spanish" "spanish" 0.0)
; ("french" "francais" 0.0))
;
; Here we should check the confidence of deutsch8 against english
; and not deutsch since the extra words of deutsch8 make it even
; more clear what the right language is. OTOH, deutsch will never
; have a higher confidence value than deutsch8, it will at most be
; the same and be selected because of the order of definitions
; in al-guess-buffer-language.
; In the current implementation, I would check deutsch and english
; since these two are neigbours.
; [IMPLEMENTED AS DESCRIBED ABOVE.]

; ! do not switch on flyspell if a language dictionary is not available [DONE]

; ------------------------------------------------------------------------

; > BTW, how do I read in a file with a word on each line and convert it
; > to a list? (Reason: I want to export my word lists for auto-lang.el
; > to external files.)
;
; How about that:
;
; (set-buffer (find-file-noselect file-name nil t))
; (while (looking-at "\\(\\w+\\)[ \n]*")
;   (setq word-list (cons (match-string 1) word-list))
;   (goto-char (match-end 1)))
; (kill-buffer (current-buffer))

; ------------------------------------------------------------------------

; Suggestions by Jorge Godoy <godoy(at)conectiva.com>:
;
; 1. Ignore quoted text while checking for the idiom (we work in a
;    multinational company and it's common to forward text mixed in
;    English, Spanish and Portuguese)
; 2. Ignore attachments (other than the first one)
; 3. Make it easily adaptable, I mean, easy to change words, remove
;    some, add others, etc. If they are out of the Lisp code it would be
;    much better. You might even create a directory with these word
;    definitions and to add a new language it would be as simple as
;    adding a new file to it.
; 4. Document it all. If you can use SGML (preferably DocBook) I can
;    help you. DocBook can create texinfo files, so you would be loved
;    by us, and by everybody who wants a PostScript, a PDF, a HTML, a
;    plain ASCII, etc. version of your document.
; 5. Make a script which reads some files and count the occorence of
;    each word and write it and the number of times it occurs on a
;    separate file. It would help people to send some words to you (they
;    won't have to worry with how many times they happen and how common
;    they are since the program count these words to them). You could
;    ask the full file or just the first 50 lines (from where you'd
;    choose the desired 10-20 words).

;;; auto-lang.el ends here

