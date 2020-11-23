;;; monkeytype.el --- Mode for speed/touch typing -*- lexical-binding: t; -*-

;; Copyright (C) 2020 Pablo Barrantes

;; Author: Pablo Barrantes <xjpablobrx@gmail.com>
;; Maintainer: Pablo Barrantes <xjpablobrx@gmail.com>
;; Version: 0.1.1
;; Keywords: games
;; URL: http://github.com/jpablobr/emacs-monkeytype
;; Package-Requires: ((emacs "25.1") (async "1.9.3"))

;;; Commentary:

;; Emacs Monkeytype is a typing game/tutor inspired by
;; monkeytype.com but for Emacs.

;; Features:

;; - Type any text you want.
;; - Practice mistyped words.
;; - Practice troubling/hard key combinations/transitions (useful when practising
;;   with different keyboard layouts).
;; - Visual representation of typed text including errors and retries/corrections.
;; - UI customisation.
;; - Auto stop after 5 seconds of no input (=C-c C-c r= [ =monkeytype-resume= ] resumes).

;;; License:

;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 2 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'async)

;;;; Customization

(defgroup monkeytype nil
  "Speed/touch typing."
  :group 'games
  :tag    "Monkeytype"
  :link   '(url-link :tag "GitHub" "https://github.com/jpablobr/emacs-monkeytype"))

(defgroup monkeytype-faces nil
  "Faces used by Monkeytype."
  :group 'monkeytype
  :group 'faces)

(defface monkeytype-face>default
  '((t (:family "Menlo" :foreground "#999999")))
  "Face for text area."
  :group 'monkeytype-faces)

(defface monkeytype-face>correct
  '((t (:foreground "#666666")))
  "Face for correctly typed char."
  :group 'monkeytype-faces)

(defface monkeytype-face>error
  '((t (
        :foreground "#cc6666"
        :underline (:color "#cc6666" :style wave))))
  "Face for wrongly typed char."
  :group 'monkeytype-faces)

(defface monkeytype-face>correction-error
  '((t (
        :inherit region
        :foreground "#ff6c6b"
        :underline (:color "#ff6c6b" :style wave))))
  "Face for wrongly typed correction."
  :group 'monkeytype-faces)

(defface monkeytype-face>correction-correct
  '((t (:inherit region :foreground "#b9ca4a")))
  "Face for correctly typed correction."
  :group 'monkeytype-faces)

(defface monkeytype-face>header-1
  '((t (:foreground "#c5c8c6" :height 1.1)))
  "Runs performance header 1"
  :group 'monkeytype-faces)

(defface monkeytype-face>header-2
  '((t (:foreground "#B7950B")))
  "Runs performance header 2"
  :group 'monkeytype-faces)

(defface monkeytype-face>header-3
  '((t (:foreground "#969896" :height 0.7)))
  "Runs performance header 3"
  :group 'monkeytype-faces)

;;;; Configurable settings:

(defcustom monkeytype-treat-newline-as-space t
  "Allow continuing to the next line by pressing space."
  :type 'boolean
  :group 'monkeytype)

(defcustom monkeytype-insert-log nil
  "Show log in results section."
  :type 'boolean
  :group 'monkeytype)

(defcustom monkeytype-minimum-transitions 50
  "Minimum amount of transitions to practice."
  :type 'integer
  :group 'monkeytype)

(defcustom monkeytype-mode-line '(:eval (monkeytype--mode-line>text))
  "Monkeytype mode line."
  :group 'monkeytype
  :type 'sexp
  :risky t)

(defcustom monkeytype-mode-line>interval-update 1
  "Number of keystrokes after each mode-line update.

Reducing the frequency of the updates helps reduce lagging on longer text or
when typing too fast."
  :type 'integer
  :group 'monkeytype)

(defcustom monkeytype-word-divisor 5.0
  "5 is the most common number for these calculations.
Proper word count doesn't work as well since words have different number
of characters. This also makes calculations easier and more accurate."
  :type 'integer
  :group 'monkeytype)

(defcustom monkeytype-auto-fill t
  "Toggle auto fill to the defaults `fill-column' setting."
  :type 'boolean
  :group 'monkeytype)

(defcustom monkeytype-downcase-mistype t
  "Toggle downcasing of mistyped words."
  :type 'boolean
  :group 'monkeytype)

(defcustom monkeytype-directory "~/.monkeytype/"
  "Monkeytype directory."
  :type 'string
  :group 'monkeytype)

;;;; Setup:

(defvar monkeytype--typing-buffer nil)

(defvar monkeytype--current-entry '())
(make-variable-buffer-local 'monkeytype--current-entry)
(defvar monkeytype--finished nil)
(make-variable-buffer-local 'monkeytype--finished)
(defvar monkeytype--start-time nil)
(make-variable-buffer-local 'monkeytype--start-time)
(defvar monkeytype--source-text "")
(defvar monkeytype--entries-counter 0)
(make-variable-buffer-local 'monkeytype--entries-counter)
(defvar monkeytype--input-counter 0)
(make-variable-buffer-local 'monkeytype--input-counter)
(defvar monkeytype--error-counter 0)
(make-variable-buffer-local 'monkeytype--error-counter)
(defvar monkeytype--correction-counter 0)
(make-variable-buffer-local 'monkeytype--correction-counter)
(defvar monkeytype--error-list '())
(make-variable-buffer-local 'monkeytype--error-list)
(defvar monkeytype--source-text-length 0)
(make-variable-buffer-local 'monkeytype--source-text-length)
(defvar monkeytype--remaining-counter 0)
(make-variable-buffer-local 'monkeytype--remaining-counter)
(defvar monkeytype--progress nil)
(make-variable-buffer-local 'monkeytype--progress)
(defvar monkeytype--buffer-name "*Monkeytype*")
(make-variable-buffer-local 'monkeytype--buffer-name)
(defvar monkeytype--change>ignored-change-counter 0)
(make-variable-buffer-local 'monkeytype--change>ignored-change-counter)
(defvar monkeytype--run-list '())
(make-variable-buffer-local 'monkeytype--run-list)
(defvar monkeytype--current-run-list '())
(make-variable-buffer-local 'monkeytype--current-run-list)
(defvar monkeytype--current-run-start-datetime nil)
(make-variable-buffer-local 'monkeytype--current-run-start-datetime)
(defvar monkeytype--mistyped-words-list '())
(make-variable-buffer-local 'monkeytype--mistyped-words-list)
(defvar monkeytype--chars-to-words-list '())
(make-variable-buffer-local 'monkeytype--chars-to-words-list)
(defvar monkeytype--hard-transition-list '())
(make-variable-buffer-local 'monkeytype--hard-transition-list)
(defvar monkeytype--chars-list '())
(make-variable-buffer-local 'monkeytype--chars-list)
(defvar monkeytype--words-list '())
(make-variable-buffer-local 'monkeytype--words-list)
(defvar monkeytype--previous-last-entry-index nil)
(make-variable-buffer-local 'monkeytype--previous-last-entry-index)
(defvar monkeytype--previous-run-last-entry nil)
(make-variable-buffer-local 'monkeytype--previous-run-last-entry)
(defvar monkeytype--previous-run '())
(make-variable-buffer-local 'monkeytype--previous-run)
(defvar monkeytype--paused nil)
(make-variable-buffer-local 'monkeytype--paused)
(defvar monkeytype--mode-line>current-entry '())
(make-variable-buffer-local 'monkeytype--mode-line>current-entry)
(defvar monkeytype--mode-line>previous-run '())
(make-variable-buffer-local 'monkeytype--mode-line>previous-run)
(defvar monkeytype--mode-line>previous-run-last-entry nil)
(make-variable-buffer-local 'monkeytype--mode-line>previous-run-last-entry)

(defun monkeytype--run-with-local-idle-timer (secs repeat function &rest args)
  "Like `run-with-idle-timer', but always run in `current-buffer'.
Cancels itself, if this buffer is killed or after 5 SECS.
REPEAT FUNCTION ARGS."
  (let* ((fns (make-symbol "local-idle-timer"))
         (timer (apply 'run-with-idle-timer secs repeat fns args))
         (fn `(lambda (&rest args)
                (if (or
                     monkeytype--paused
                     monkeytype--finished
                     (not (buffer-live-p ,(current-buffer))))
                    (cancel-timer ,timer)
                  (with-current-buffer ,(current-buffer)
                    (apply (function ,function) args))))))
    (fset fns fn)
    fn))

(defun monkeytype--setup (text)
  "Set up a new buffer for the typing exercise on TEXT."
  (with-temp-buffer
    (insert text)

    (when monkeytype-auto-fill
      (fill-region (point-min) (point-max)))

    (delete-trailing-whitespace)
    (setq text (buffer-string)))

  (setq monkeytype--typing-buffer (generate-new-buffer monkeytype--buffer-name))
  (let* ((len (length text)))
    (set-buffer monkeytype--typing-buffer)
    (setq monkeytype--source-text text)
    (setq monkeytype--source-text-length (length text))
    (setq monkeytype--remaining-counter (length text))
    (setq monkeytype--progress (make-string len 0))
    (erase-buffer)
    (insert monkeytype--source-text)
    (set-buffer-modified-p nil)
    (switch-to-buffer monkeytype--typing-buffer)
    (goto-char 0)
    (face-remap-add-relative 'default 'monkeytype-face>default)
    (monkeytype--add-hooks)
    (monkeytype-mode)
    (monkeytype--mode-line>report-status)
    (message "Monkeytype: Timer will start when you type the first character.")))

;;;; Change:

(defun monkeytype--change (start end change-length)
  "START END CHANGE-LENGTH."

  ;; HACK: This usually happens when text has been skipped without being typed.
  ;; Text skipps need to be handled properly
  (if (< (- end 2) (length monkeytype--source-text))
      (progn
        (let* ((source-start (1- start))
               (source-end (1- end))
               (entry (substring-no-properties (buffer-substring start end)))
               (source (substring monkeytype--source-text source-start source-end))
               (deleted-text (substring monkeytype--source-text source-start (+ source-start change-length)))
               (update (lambda ()
                         (monkeytype--change>handle-del source-start end deleted-text)
                         (monkeytype--change>diff source entry start end)
                         (when (monkeytype--change>add-to-entriesp entry change-length)
                           (monkeytype--change>add-to-entries source-start entry source)))))
          (funcall update)
          (goto-char end)
          (monkeytype--change>update-mode-line)
          (when (= monkeytype--remaining-counter 0) (monkeytype--handle-complete))))
    (monkeytype--handle-complete)))

(defun monkeytype--change>update-mode-line ()
  "Update mode-line."
  (if monkeytype-mode-line>interval-update
      (let* ((entry (elt monkeytype--current-run-list 0))
             (char-index (if entry (gethash "source-index" entry) 0)))
        (if (and
             (> char-index monkeytype-mode-line>interval-update)
             (= (mod char-index monkeytype-mode-line>interval-update) 0))
            (monkeytype--mode-line>report-status)))))

(defun monkeytype--change>handle-del (source-start end deleted-text)
  "Keep track of statistics when deletion occurs between SOURCE-START and END DELETED-TEXT."
  (delete-region (1+ source-start) end)
  (let* ((entry-state (aref monkeytype--progress source-start)))
    (cond ((= entry-state 1)
           (cl-decf monkeytype--entries-counter)
           (cl-incf monkeytype--remaining-counter))
          ((= entry-state 2)
           (cl-decf monkeytype--entries-counter)
           (cl-incf monkeytype--remaining-counter)
           (cl-decf monkeytype--error-counter)
           (cl-incf monkeytype--correction-counter)))
    (store-substring monkeytype--progress source-start 0)
    (insert deleted-text)))

(defun monkeytype--change>diff (source entry start end)
  "Update stats and buffer contents with result of changed text.
SOURCE ENTRY START END."
  (when (/= start end)
    (let* ((correct (monkeytype--check-same source entry))
          (progress-index (1- start))
          (face-for-entry (monkeytype--typed-text>entry-face correct)))
      (if correct
        (store-substring monkeytype--progress progress-index 1)
        (progn
          (cl-incf monkeytype--error-counter)
          (store-substring monkeytype--progress progress-index 2)))
      (cl-incf monkeytype--entries-counter)
      (cl-decf monkeytype--remaining-counter)

      (if (fboundp 'add-face-text-property)
          (add-face-text-property start (1+ start) face-for-entry)
        (add-text-properties start (1+ start) `(face ,@face-for-entry))))))

(defun monkeytype--change>add-to-entriesp (entry change-length)
  "Add ENTRY CHANGE-LENGTH.

HACK: Properly fix BUG where \"f\" character produces a delete and re-enter
event. ATM this only ignores those events since at least the stats do not get
affected. Only set monkeytype--ignored-change-counter when the
`last-input-event' is a character(e.i., integerp not M-backspace)."
  (cond
   ((= 0 (length entry))
    (when (integerp last-input-event)
      (setq monkeytype--change>ignored-change-counter change-length))
    nil)
   ((> monkeytype--change>ignored-change-counter 0) ;; Number of changes to be ignored.
    (cl-decf monkeytype--change>ignored-change-counter)
    nil)
   (t t)))

(defun monkeytype--change>add-to-entries (source-start change-typed change-source)
  "Add entry to current-run-list keeping track of SOURCE-START CHANGE-TYPED and CHANGE-SOURCE."
  (cl-incf monkeytype--input-counter)
  (let ((entry (make-hash-table :test 'equal)))
    (puthash "input-index" monkeytype--input-counter entry)
    (puthash "typed-entry" change-typed entry)
    (puthash "source-entry" change-source entry)
    (puthash "source-index" (1+ source-start) entry)
    (puthash "error-count" monkeytype--error-counter entry)
    (puthash "correction-count" monkeytype--correction-counter entry)
    (puthash "state" (aref monkeytype--progress source-start) entry)
    (puthash "elapsed-seconds" (monkeytype--elapsed-seconds) entry)
    (puthash "formatted-seconds" (format-seconds "%.2h:%z%.2m:%.2s" (monkeytype--elapsed-seconds)) entry)
    (add-to-list 'monkeytype--current-run-list entry)))

(defun monkeytype--change>timer-init ()
  "Start the timer."
  (when (not monkeytype--start-time)
    (setq monkeytype--current-run-start-datetime (format-time-string "%a-%d-%b-%Y %H:%M:%S"))
    (setq monkeytype--start-time (float-time))
    (monkeytype--run-with-local-idle-timer 5 nil 'monkeytype-pause)))

(defun monkeytype--pause-run ()
  "Pause run and optionally PRINT-RESULTS."
  (setq monkeytype--start-time nil)
  (remove-hook 'after-change-functions 'monkeytype--change)
  (remove-hook 'first-change-hook 'monkeytype--change>timer-init)
  (monkeytype--add-to-run-list)
  (read-only-mode))

(defun monkeytype--handle-complete ()
  "Remove typing hooks from the buffer and print statistics."
  (setq monkeytype--finished t)

  (unless monkeytype--paused (monkeytype--pause-run))

  (set-buffer-modified-p nil)
  (setq buffer-read-only nil)
  (monkeytype--print-results)

  (monkeytype--mode-line>report-status)
  (monkeytype-mode)
  (read-only-mode))

(defun monkeytype--add-to-run-list ()
  "Add run to run-list."
  (let* ((run (make-hash-table :test 'equal)))
    (puthash "started-at" monkeytype--current-run-start-datetime run)
    (puthash "finished-at" (format-time-string "%a-%d-%b-%Y %H:%M:%S") run)
    (puthash "entries" (vconcat monkeytype--current-run-list) run)
    (add-to-list 'monkeytype--run-list run)))

;;;; Utils:

(defun monkeytype--nshuffle (sequence)
  "Shuffle given SEQUENCE.

URL `https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle'"
  (cl-loop for i from (length sequence) downto 2
        do (cl-rotatef (elt sequence (random i))
                    (elt sequence (1- i))))
  sequence)

(defun monkeytype--index-words ()
  "Index words."
  (let* ((words (split-string monkeytype--source-text "[ \n]"))
         (index 1))
    (dolist (word words)
      (add-to-list 'monkeytype--words-list `(,index . ,word))
      (setq index (+ index 1)))))

(defun monkeytype--index-chars-to-words ()
  "Associate by index cars to words."
  (let* ((chars (mapcar 'char-to-string monkeytype--source-text))
         (word-index 1)
         (char-index 1))
    (dolist (char chars)
      (if (string-match "[ \n\t]" char)
          (progn
            (setq word-index (+ word-index 1))
            (setq char-index (+ char-index 1)))
        (progn
          (let* ((word  (assoc word-index monkeytype--words-list))
                 (word (cdr word)))
            (add-to-list 'monkeytype--chars-to-words-list `(,char-index . ,word))
            (setq char-index (+ char-index 1))))))))

(defun monkeytype--index-chars (run)
  "RUN Index chars."
  (unless monkeytype--previous-last-entry-index
    (setq monkeytype--previous-last-entry-index 0))

  (let* ((first-entry-index monkeytype--previous-last-entry-index)
         (last-entry (elt (gethash "entries" run) 0))
         (source-text (substring
                       monkeytype--source-text
                       first-entry-index
                       (gethash "source-index" last-entry)))
         (chars (mapcar 'char-to-string source-text))
         (chars-list '())
         (index first-entry-index))
    (dolist (char chars)
      (setq index (+ 1 index))
      (cl-pushnew `(,index . ,char) chars-list))
    (setq monkeytype--chars-list (reverse chars-list))
    (setq monkeytype--previous-last-entry-index
          (gethash "source-index" (elt (gethash "entries" run) 0)))))

(defun monkeytype--add-hooks ()
  "Add hooks."
  (make-local-variable 'after-change-functions)
  (make-local-variable 'first-change-hook)
  (add-hook 'after-change-functions 'monkeytype--change nil t)
  (add-hook 'first-change-hook 'monkeytype--change>timer-init nil t))

(defun monkeytype--print-results ()
  "Print all results."
  (erase-buffer)

  (when (> (length monkeytype--run-list) 1)
    (insert (concat
             (propertize
              (format "%s" "Overall Results:\n")
              'face
              'monkeytype-face>header-1)
             (propertize
              (format "(Tally of %d runs)\n\n" (length monkeytype--run-list))
              'face
              'monkeytype-face>header-3)
             (monkeytype--final-performance-results)
             (propertize
              "\n\nBreakdown by Runs:\n\n"
              'face
              'monkeytype-face>header-1))))

  (let ((run-index 1))
    (dolist (run (reverse monkeytype--run-list))
      (insert (concat
               (propertize
                (format "--(%d)-%s--:\n" run-index (gethash "started-at" run))
                'face
                'monkeytype-face>header-2)
               (monkeytype--typed-text run)
               (monkeytype--run-performance-results (gethash "entries" run))
               "\n\n"))

      (setq run-index (+ run-index 1))

      (when monkeytype-insert-log
        (async-start
         `(lambda () ,(monkeytype--log run) 1)
         (lambda (result)
           (message "Monkeytype: Log generated successfully. (%s)" result))))))

  (goto-char (point-min)))

(defun monkeytype--elapsed-seconds ()
  "Return float with the total time since start."
  (let ((end-time (float-time)))
    (if monkeytype--start-time
        (- end-time monkeytype--start-time)
      0)))

(defun monkeytype--check-same (source typed)
  "Return non-nil if both POS (SOURCE and TYPED) are white space or the same."
  (if monkeytype-treat-newline-as-space
      (or (string= source typed)
          (and
           (= (char-syntax (aref source 0)) ?\s)
           (= (char-syntax (aref typed 0)) ?\s)))
    (string= source typed)))

(defun monkeytype--seconds-to-minutes (seconds)
  "Return minutes in float for SECONDS."
  (/ seconds 60.0))

;;;; Equations:

(defun monkeytype--words (chars)
  "Divide all CHARS by divisor."
  (/ chars monkeytype-word-divisor))

(defun monkeytype--gross-wpm (words minutes)
  "Divides WORDS by MINUTES."
  (/ words minutes))

(defun monkeytype--gross-cpm (chars minutes)
  "Divides CHARS by MINUTES."
  (/ chars minutes))

(defun monkeytype--net-wpm (words uncorrected-errors minutes)
  "Net WPM is the gross WPM minus the UNCORRECTED-ERRORS by MINUTES.
All WORDS count."
  (let ((net-wpm (- (monkeytype--gross-wpm words minutes)
                    (/ uncorrected-errors minutes))))
    (if (> 0 net-wpm) 0 net-wpm)))

(defun monkeytype--net-cpm (chars uncorrected-errors minutes)
  "Net CPM is the gross CPM minus the UNCORRECTED-ERRORS by MINUTES.
All CHARS count."
  (let ((net-cpm (- (monkeytype--gross-cpm chars minutes)
                    (/ uncorrected-errors minutes))))
    (if (> 0 net-cpm) 0 net-cpm)))

(defun monkeytype--accuracy (chars correct-chars corrections)
  "Accuracy is all CORRECT-CHARS minus CORRECTIONS divided by all CHARS."
  (when (> chars 0)
    (let* ((a-chars (- correct-chars corrections))
           (a-chars (if (> a-chars 0) a-chars 0))
           (accuracy (* (/ a-chars (float chars)) 100.00)))
      accuracy)))

;;;; Performance results

(defun monkeytype--run-net-wpm-format (words uncorrected-errors minutes seconds)
  "Net WPM performance result for total WORDS.

Gross-WPM - (UNCORRECTED-ERRORS / MINUTES).
Also shows SECONDS right next to WPM."
  (concat
   (propertize
    (format
     "%.2f/%s"
     (monkeytype--net-wpm words uncorrected-errors minutes)
     (format-seconds "%.2h:%z%.2m:%.2s" seconds))
    'face
    'monkeytype-face>header-2)
   (propertize
    (format "[%.2f - (" (monkeytype--gross-wpm words minutes))
    'face
    'monkeytype-face>header-3)
   (propertize
    (format "%d" uncorrected-errors)
    'face
    `(:foreground ,(if (= uncorrected-errors 0)
                       "#98be65"
                     "#cc6666") :height 0.7))
   (propertize
    (concat
     (format " / %.2f)]\n" minutes)
     "WPM = Gross-WPM - (uncorrected-errors / minutes)")
    'face
    'monkeytype-face>header-3)))

(defun monkeytype--run-gross-wpm-format (words minutes)
  "Gross WPM performance result.

Gross-WPM = WORDS / MINUTES."
  (concat
   (propertize
    (format "%.2f" (monkeytype--gross-wpm words minutes))
    'face
    'monkeytype-face>header-2)
   (propertize
    "["
    'face
    'monkeytype-face>header-3)
   (propertize
    (format "%.2f" words)
    'face
    '(:foreground "#98be65" :height 0.7))
   (propertize
    (format " / %.2f]" minutes)
    'face
    'monkeytype-face>header-3)
   (propertize
    "\nGross-WPM = words / minutes"
    'face
    'monkeytype-face>header-3)))

(defun monkeytype--run-accuracy-format (chars correct-chars corrections)
  "CHARS CORRECT-CHARS CORRECTIONS."
  (concat
   (propertize
    (format "%.2f%%" (monkeytype--accuracy chars correct-chars corrections))
    'face
    'monkeytype-face>header-2)
   (propertize
    (format "[((%.2f - " correct-chars)
    'face
    'monkeytype-face>header-3)
   (propertize
    (format "%d" corrections)
    'face
    `(:foreground ,(if (= corrections 0)
                       "#98be65"
                     "#cc6666") :height 0.7))
   (propertize
    (format ") / %.2f) * 100]" chars)
    'face
    'monkeytype-face>header-3)
   (propertize
    "\nAccuracy = ((correct-chars - corrections) / total-chars) * 100"
    'face
    'monkeytype-face>header-3)))

(defun monkeytype--build-performance-results (words errors minutes seconds entries corrections)
  "Build results text.
WORDS ERRORS MINUTES SECONDS ENTRIES CORRECTIONS."
  (concat
   (monkeytype--run-net-wpm-format words errors minutes seconds)
   "\n\n"
   (monkeytype--run-accuracy-format entries (- entries errors) corrections)
   "\n\n"
   (monkeytype--run-gross-wpm-format words minutes)))

(defun monkeytype--run-performance-results (run)
  "Performance results for RUN."
  (let* ((last-entry (elt run 0))
         (elapsed-seconds (gethash "elapsed-seconds" last-entry))
         (elapsed-minutes (monkeytype--seconds-to-minutes elapsed-seconds))
         (entries (if monkeytype--previous-run-last-entry
                      (-
                       (gethash "input-index" last-entry)
                       (gethash "input-index" monkeytype--previous-run-last-entry))
                    (gethash "input-index" last-entry)))
         (errors (if monkeytype--previous-run-last-entry
                     (-
                      (gethash "error-count" last-entry)
                      (gethash "error-count" monkeytype--previous-run-last-entry))
                   (gethash "error-count" last-entry)))
         (corrections (if monkeytype--previous-run-last-entry
                          (-
                           (gethash "correction-count" last-entry)
                           (gethash "correction-count" monkeytype--previous-run-last-entry))
                        (gethash "correction-count" last-entry)))
         (words (monkeytype--words entries)))
    (setq monkeytype--previous-run-last-entry (elt run 0))
    (monkeytype--build-performance-results
     words errors elapsed-minutes elapsed-seconds entries corrections)))

(defun monkeytype--final-performance-results ()
  "Final Performance results for all run(s).
Total time is the sum of all the last entries' elapsed-seconds from all runs."
  (let* ((runs-last-entry (mapcar (lambda (x) (elt (gethash "entries" x) 0)) monkeytype--run-list))
         (last-entry (elt runs-last-entry 0))
         (total-elapsed-seconds (apply '+  (mapcar (lambda (x) (gethash "elapsed-seconds" x)) runs-last-entry)))
         (elapsed-minutes (monkeytype--seconds-to-minutes total-elapsed-seconds))
         (entries (gethash "input-index" last-entry))
         (errors (gethash "error-count" last-entry))
         (corrections (gethash "correction-count" last-entry))
         (words (monkeytype--words entries)))
    (monkeytype--build-performance-results
     words errors elapsed-minutes total-elapsed-seconds entries corrections)))

;;;; typed text

(defun monkeytype--typed-text>entry-face (correctp &optional correctionp)
  "Return the face for the CORRECTP and/or CORRECTIONP entry."
  (let* ((entry-face (if correctionp
                         (if correctp
                             'monkeytype-face>correction-correct
                           'monkeytype-face>correction-error)
                       (if correctp
                           'monkeytype-face>correct
                         'monkeytype-face>error))))
    entry-face))

(defun monkeytype--typed-text>newline (source typed)
  "Newline substitutions depending on SOURCE and TYPED char."
  (if (string= "\n" source)
      (if (or
           (string= " " typed)
           (string= source typed))
          "↵\n"
        (concat typed "↵\n"))
    typed))

(defun monkeytype--typed-text>whitespace (source typed)
  "Whitespace substitutions depending on SOURCE and TYPED char."
  (if (and
       (string= " " typed)
       (not (string= typed source)))
      "·"
    typed))

(defun monkeytype--typed-text>skipped-text (settled-index)
  "Handle skipped text before the typed char at SETTLED-INDEX."
  (let* ((source-index (car (car monkeytype--chars-list)))
         (source-entry (cdr (car monkeytype--chars-list)))
         (skipped-length (if source-index
                             (- settled-index source-index)
                           0)))
    (if (or
         (string-match "[ \n\t]" source-entry)
         (= skipped-length 0))
        (progn
          (pop monkeytype--chars-list)
          "")
      (progn
        (cl-loop repeat (+ skipped-length 1) do
                 (pop monkeytype--chars-list))
        (substring
         monkeytype--source-text
         (- source-index 1)
         (- settled-index 1))))))

(defun monkeytype--typed-text>add-to-mistyped-list (char)
  "Find associated word for CHAR and add it to mistyped list."
  (let* ((index (gethash "source-index" char))
         (word (cdr (assoc index monkeytype--chars-to-words-list)))
         (word (when word (string-trim word)))
         (word (when word (replace-regexp-in-string "[;.\":,()-?]" "" word))))
    (when word
      (cl-pushnew word monkeytype--mistyped-words-list))))

(defun monkeytype--typed-text>concat-corrections (corrections settled propertized-settled)
  "Concat propertized CORRECTIONS to PROPERTIZED-SETTLED char.

Also add correction in SETTLED to mistyped-words-list."
  (monkeytype--typed-text>add-to-mistyped-list settled)

  (format
   "%s%s"
   propertized-settled
   (mapconcat
    (lambda (correction)
      (let* ((correction-char (gethash "typed-entry" correction))
             (state (gethash "state" correction))
             (correction-face (monkeytype--typed-text>entry-face (= state 1) t)))
        (propertize (format "%s" correction-char) 'face correction-face)))
    corrections
    "")))

(defun monkeytype--typed-text>collect-errors (settled)
  "Add the SETTLED char's associated word and transition to their respective lists."
  (unless (= (gethash "state" settled) 1)
    (unless (string-match "[ \n\t]" (gethash "source-entry" settled))
      (let* ((char-index (gethash "source-index" settled))
             (hard-transitionp (> char-index 2))
             (hard-transition  (when hard-transitionp
                                 (substring monkeytype--source-text (- char-index 2) char-index)))
             (hard-transitionp (and
                                hard-transitionp
                                (not (string-match "[ \n\t]" hard-transition)))))

        (when hard-transitionp
          (cl-pushnew hard-transition monkeytype--hard-transition-list))
        (monkeytype--typed-text>add-to-mistyped-list settled)))))

(defun monkeytype--typed-text>to-string (entries)
  "Format typed ENTRIES and return a string."
  (mapconcat
   (lambda (entries-for-source)
     (let* ((tries (cdr entries-for-source))
            (correctionsp (> (length tries) 1))
            (settled (if correctionsp
                         (car (last tries))
                       (car tries)))
            (source-entry (gethash "source-entry" settled))
            (typed-entry (monkeytype--typed-text>newline
                          source-entry
                          (gethash "typed-entry" settled)))
            (typed-entry (monkeytype--typed-text>whitespace
                          source-entry
                          typed-entry))
            (settled-correctp (= (gethash "state" settled) 1))
            (settled-index (gethash "source-index" settled))
            (skipped-text  (monkeytype--typed-text>skipped-text settled-index))
            (propertized-settled (concat
                                  skipped-text
                                  (propertize
                                   (format "%s" typed-entry)
                                   'face
                                   (monkeytype--typed-text>entry-face settled-correctp))))
            (corrections (when correctionsp (butlast tries))))
       (if correctionsp
           (monkeytype--typed-text>concat-corrections corrections settled propertized-settled)
         (monkeytype--typed-text>collect-errors settled)
         (format "%s" propertized-settled))))
   entries
   ""))

(defun monkeytype--typed-text (run)
  "Typed text for RUN."
  (monkeytype--index-chars run)
  (monkeytype--index-words)
  (monkeytype--index-chars-to-words)
  (format
   "\n%s\n\n"
   (monkeytype--typed-text>to-string
    (seq-group-by
     (lambda (entry) (gethash "source-index" entry))
     (reverse (gethash "entries" run))))))

;;;; Log:

(defun monkeytype--log (run)
  "Log for the RUN."
  (insert "Log:")
  (insert (monkeytype--log>header))
  (dotimes (i (length (gethash "entries" run)))
    (let* ((entries  (reverse (gethash "entries" run)))
           (entry (elt entries i)))
      (insert (monkeytype--log>entry entry))))
  (insert "\n\n"))

(defun monkeytype--log>header ()
  "Log header."
  (let ((log-header
         '(" I/S Idx "
           " S/T Chr "
           " N/WPM   "
           " N/CPM   "
           " G/WPM   "
           " G/CPM   "
           " Acc %   "
           " Time    "
           " Mends   "
           " Errs    ")))
    (format "\n|%s|" (mapconcat 'identity log-header "|"))))

(defun monkeytype--log>entry (entry)
  "Format ENTRY."
  (let* ((source-index (gethash "source-index" entry))
         (typed-entry (gethash "typed-entry" entry))
         (source-entry (gethash "source-entry" entry))
         (typed-entry (if (string= typed-entry "\n") "↵" typed-entry))
         (source-entry (if (string= source-entry "\n") "↵" source-entry))
         (error-count (gethash "error-count" entry))
         (correction-count (gethash "correction-count" entry))
         (input-index (gethash "input-index" entry))
         (state (gethash "state" entry))
         (elapsed-seconds (gethash "elapsed-seconds" entry))
         (elapsed-minutes (monkeytype--seconds-to-minutes elapsed-seconds))
         (typed-entry-face (monkeytype--typed-text>entry-face (= state 1)))
         (propertized-typed-entry (propertize (format "%S" typed-entry) 'face typed-entry-face)))
    (format "\n|%9s|%9s|%9d|%9d|%9d|%9d|%9.2f|%9s|%9d|%9d|"
            (format "%s %s" input-index source-index)
            (format "%S %s" source-entry propertized-typed-entry)
            (monkeytype--net-wpm (monkeytype--words input-index) error-count elapsed-minutes)
            (monkeytype--net-cpm input-index error-count elapsed-minutes)
            (monkeytype--gross-wpm (monkeytype--words input-index) elapsed-minutes)
            (monkeytype--gross-cpm input-index elapsed-minutes)
            (monkeytype--accuracy input-index (- input-index error-count) correction-count)
            (format-seconds "%.2h:%z%.2m:%.2s" elapsed-seconds)
            correction-count
            (+ error-count correction-count))))

;;;; Autoloads:

;;;###autoload
(defun monkeytype-region (start end)
  "Type marked region form START to END.
\\[monkeytype-region]"
  (interactive "r")
  (monkeytype--setup (buffer-substring-no-properties start end)))

;;;###autoload
(defun monkeytype-repeat ()
  "Repeat run.

\\[monkeytype-repeat]"
  (interactive)
  (monkeytype--setup monkeytype--source-text))

;;;###autoload
(defun monkeytype-dummy-text ()
  "Dummy text.

\\[monkeytype-dummy-text]"
  (interactive)
  (let* ((text
          (concat
           "\"I have had a dream past the wit of man to say what dream it was,\n"
           "says Bottom.\"")))
    (monkeytype--setup text)))

;;;###autoload
(defun monkeytype-fortune ()
  "Type fortune.

\\[monkeytype-fortune]"
  (interactive)
  (fortune)
  (monkeytype-buffer))

;;;###autoload
(defun monkeytype-buffer ()
  "Type entire current buffet.

\\[monkeytype-buffer]"
  (interactive)
  (monkeytype--setup (buffer-substring-no-properties (point-min) (point-max))))

;;;###autoload
(defun monkeytype-pause ()
  "Pause run.

\\[monkeytype-pause]"
  (interactive)
  (setq monkeytype--paused t)
  (when monkeytype--start-time (monkeytype--pause-run))
  (setq monkeytype--current-run-list '())
  (when (not monkeytype--finished)
    (message "Monkeytype: Paused ([C-c C-c r] to resume.)")))

;;;###autoload
(defun monkeytype-stop ()
  "Finish run.

\\[monkeytype-stop]"
  (interactive)
  (monkeytype--handle-complete))

;;;###autoload
(defun monkeytype-resume ()
  "Resume run.

\\[monkeytype-resume]"
  (interactive)
  (when (not monkeytype--finished)
    (progn
      (setq monkeytype--paused nil)
      (switch-to-buffer monkeytype--typing-buffer)
      (set-buffer-modified-p nil)
      (monkeytype--add-hooks)
      (monkeytype-mode)
      (setq buffer-read-only nil)
      (monkeytype--mode-line>report-status)
      (message "Monkeytype: Timer will start when you type the first character."))))

;;;###autoload
(defun monkeytype-mistyped-words ()
  "Practice mistyped words.

\\[monkeytype-mistyped-words]"
  (interactive)
  (if (> (length monkeytype--mistyped-words-list) 0)
      (monkeytype--setup
       (mapconcat
        (lambda (word) (if monkeytype-downcase-mistype (downcase word) word))
        (monkeytype--nshuffle monkeytype--mistyped-words-list)  " "))
    (message "Monkeytype: No errors. ([C-c C-c t] to repeat.)")))

;;;###autoload
(defun monkeytype-hard-transitions ()
  "Practice hard key combinations/transitions.

\\[monkeytype-hard-transitions]"
  (interactive)
  (if (> (length monkeytype--hard-transition-list) 0)
      (let* ((transitions-count (length monkeytype--hard-transition-list))
             (append-times (/ monkeytype-minimum-transitions transitions-count))
             (final-list '()))
        (cl-loop repeat append-times do
                 (setq final-list (append final-list monkeytype--hard-transition-list)))
        (monkeytype--setup (mapconcat 'identity (monkeytype--nshuffle final-list) " ")))
    (message "Monkeytype: No errors. ([C-c C-c t] to repeat.)")))

;;;; Saving

(defun monkeytype--save>file-path (type)
  "Build path for the TYPE of file to be saved."
  (unless (file-exists-p monkeytype-directory)
    (make-directory monkeytype-directory))

  (concat
   monkeytype-directory
   (format "%s/" type)
   (format "%s" (downcase (format-time-string "%a-%d-%b-%Y-%H-%M-%S")))
   ".txt"))

;;;###autoload
(defun monkeytype-save-mistyped-words ()
  "Save mistyped words.

\\[monkeytype-save-mistyped-words]"
  (interactive)
  (let ((path (monkeytype--save>file-path "words"))
        (words (mapconcat 'identity monkeytype--mistyped-words-list " ")))
    (with-temp-file path (insert words))
    (message "Monkeytype: Words saved successfully to file: %s" path)))

;;;###autoload
(defun monkeytype-save-hard-transitions ()
  "Save hard transitions.

\\[monkeytype-save-hard-transition]"
  (interactive)
  (let ((path (monkeytype--save>file-path "transitions"))
        (transitions (mapconcat 'identity monkeytype--hard-transition-list " ")))
    (with-temp-file path (insert transitions))
    (message "Monkeytype: Transitions saved successfully to file: %s" path)))

;;; Mode-line

(defun monkeytype--mode-line>report-status ()
  "Take care of mode-line updating."
  (setq monkeytype--mode-line>current-entry (elt monkeytype--current-run-list 0))
  (setq monkeytype--mode-line>previous-run (elt monkeytype--run-list 0))

  (when monkeytype--mode-line>previous-run
    (setq monkeytype--mode-line>previous-run-last-entry
          (elt (gethash "entries" monkeytype--mode-line>previous-run) 0)))

  (when (or (not monkeytype--mode-line>current-entry) monkeytype--finished)
    (setq monkeytype--mode-line>current-entry (make-hash-table :test 'equal)))
  (force-mode-line-update))

(defun monkeytype--mode-line>text ()
  "Show status in mode line."
  (let* ((elapsed-seconds (gethash "elapsed-seconds" monkeytype--mode-line>current-entry 0))
         (elapsed-minutes (monkeytype--seconds-to-minutes elapsed-seconds))
         (previous-last-entry (when monkeytype--mode-line>previous-run
                                monkeytype--mode-line>previous-run-last-entry))
         (previous-run-entryp (and
                               monkeytype--mode-line>previous-run
                               (> (gethash "input-index" monkeytype--mode-line>current-entry 0) 0)))
         (entries (if previous-run-entryp
                      (-
                       (gethash "input-index" monkeytype--mode-line>current-entry)
                       (gethash "input-index" previous-last-entry))
                    (gethash "input-index" monkeytype--mode-line>current-entry 0)))
         (errors (if previous-run-entryp
                     (-
                      (gethash "error-count" monkeytype--mode-line>current-entry)
                      (gethash "error-count" previous-last-entry))
                   (gethash "error-count" monkeytype--mode-line>current-entry 0)))
         (corrections (if previous-run-entryp
                          (-
                           (gethash "correction-count" monkeytype--mode-line>current-entry)
                           (gethash "correction-count" previous-last-entry))
                        (gethash "correction-count" monkeytype--mode-line>current-entry 0)))

         (words (monkeytype--words entries))
         (net-wpm (if (> words 1)
                      (monkeytype--net-wpm words errors elapsed-minutes)
                    0))
         (gross-wpm (if (> words 1)
                        (monkeytype--gross-wpm words elapsed-minutes)
                      0))
         (accuracy (if (> words 1)
                       (monkeytype--accuracy entries (- entries errors) corrections)
                     0))
         (elapsed-time (format "%s" (format-seconds "%.2h:%z%.2m:%.2s" elapsed-seconds)))
         (green '(:foreground "#98be65"))
         (normal '(:foreground "#c5c8c6"))
         (orange '(:foreground "#B7950B"))
         (red '(:foreground "#ff6c6b")))

    (concat
     (propertize "MT[" 'face normal)
     (propertize (format "%d" net-wpm) 'face green)
     (propertize "/" 'face normal)
     (propertize (format "%d" gross-wpm) 'face normal)
     (propertize " " 'face normal)
     (propertize (format "%d " accuracy) 'face normal)
     (propertize elapsed-time 'face orange)
     (propertize (format " (%d/" words) 'face normal)
     (propertize (format "%d" corrections) 'face (if (> corrections 0) red green))
     (propertize "/" 'face normal)
     (propertize (format "%d" errors) 'face (if (> errors 0) red green))
     (propertize ")]" 'face normal))))

;;;###autoload
(define-minor-mode monkeytype-mode
  "Monkeytype mode is a minor mode for speed/touch typing"
  :lighter monkeytype-mode-line
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c p") 'monkeytype-pause)
            (define-key map (kbd "C-c C-c r") 'monkeytype-resume)
            (define-key map (kbd "C-c C-c s") 'monkeytype-stop)
            (define-key map (kbd "C-c C-c t") 'monkeytype-repeat)
            (define-key map (kbd "C-c C-c f") 'monkeytype-fortune)
            (define-key map (kbd "C-c C-c m") 'monkeytype-mistyped-words)
            (define-key map (kbd "C-c C-c h") 'monkeytype-hard-transitions)
            (define-key map (kbd "C-c C-c a") 'monkeytype-save-mistyped-words)
            (define-key map (kbd "C-c C-c o") 'monkeytype-save-hard-transitions)
            map))

(provide 'monkeytype)

;;; monkeytype.el ends here
