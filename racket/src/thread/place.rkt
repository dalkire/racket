#lang racket/base
(require (only-in '#%unsafe unsafe-abort-current-continuation/no-wind)
         "place-local.rkt"
         "check.rkt"
         "host.rkt"
         "schedule.rkt"
         "atomic.rkt"
         "thread.rkt"
         "thread-group.rkt"
         (submod "thread.rkt" for-place)
         "custodian.rkt"
         (submod "custodian.rkt" scheduling)
         "plumber.rkt"
         "exit.rkt"
         "sync.rkt"
         "semaphore.rkt"
         "evt.rkt"
         "sandman.rkt"
         "place-message.rkt")

(provide dynamic-place
         place?
         place-break
         place-kill
         place-wait
         place-dead-evt

         place-channel
         place-channel? 
         place-channel-get
         place-channel-put

         set-make-place-ports+fds!
         place-pumper-threads
         unsafe-add-post-custodian-shutdown)

;; ----------------------------------------

(struct place (parent
               lock
               activity-canary           ; box for quick check before taking lock
               pch                       ; channel to new place
               [result #:mutable]        ; byte or #f, where #f means "not done"
               [queued-result #:mutable] ; non-#f triggers a place exit
               custodian
               [post-shutdown #:mutable] ; list of callbacks
               [pumpers #:mutable]       ; vector of up to three pumper threads
               [pending-break #:mutable] ; #f, 'break, 'hangup, or 'terminate
               done-waiting              ; hash table of places to ping when this one ends
               [wakeup-handle #:mutable]
               [dequeue-semas #:mutable]) ; semaphores reflecting place-channel waits to recheck
  #:property prop:evt (struct-field-index pch)
  #:property prop:place-message (lambda (self) (lambda () (lambda () (place-pch self)))))

(define (make-place lock cust
                    #:parent [parent #f]
                    #:place-channel [pch #f])
  (place parent
         lock
         (box #f)             ; activity canary
         pch
         #f                   ; result
         #f                   ; queued-result
         cust
         '()                  ; post-shutdown
         #f                   ; pumper-threads
         #f                   ; pending-break
         (make-hasheq)        ; done-waiting
         #f                   ; wakeup-handle
         '()))                ; dequeue-semas

(define-place-local current-place (make-place (host:make-mutex)
                                              (current-custodian)))

(define/who (dynamic-place path sym in out err)
  (define orig-cust (create-custodian))
  (define lock (host:make-mutex))
  (define started (host:make-condition))
  (define-values (place-pch child-pch) (place-channel))
  (define new-place (make-place lock orig-cust
                                #:parent current-place
                                #:place-channel place-pch))
  (define done-waiting (place-done-waiting new-place))
  (define orig-plumber (make-plumber))
  (define (default-exit v)
    (plumber-flush-all orig-plumber)
    (atomically
     (host:mutex-acquire lock)
     (set-place-queued-result! new-place (if (byte? v) v 0))
     (place-has-activity! new-place)
     (host:mutex-release lock))
    ;; Switch to scheduler, so it can exit:
    (engine-block))
  ;; Atomic mode to create ports and deliver them to the new place
  (start-atomic)
  (define-values (parent-in parent-out parent-err child-in-fd child-out-fd child-err-fd)
    (make-place-ports+fds in out err))
  (host:mutex-acquire lock)
  ;; Start the new place
  (host:fork-place
   (lambda ()
     (call-in-another-main-thread
      orig-cust
      (lambda ()
        (set! current-place new-place)
        (current-thread-group root-thread-group)
        (current-custodian orig-cust)
        (current-plumber orig-plumber)
        (exit-handler default-exit)
        (current-pseudo-random-generator (make-pseudo-random-generator))
        (current-evt-pseudo-random-generator (make-pseudo-random-generator))
        (define finish
          (host:start-place child-pch path sym
                            child-in-fd child-out-fd child-err-fd
                            orig-cust orig-plumber))
        (call-with-continuation-prompt
         (lambda ()
           (host:mutex-acquire lock)
           (set-place-wakeup-handle! new-place (sandman-get-wakeup-handle))
           (host:condition-signal started) ; place is sufficiently started
           (host:mutex-release lock)
           (finish))
         (default-continuation-prompt-tag)
         (lambda (thunk)
           ;; Thread ended with escape => exit with status 1
           (call-with-continuation-prompt thunk)
           (default-exit 1)))
        (default-exit 0))))
   (lambda (result)
     ;; Place is done, so save the result and alert anyone waiting on
     ;; the place
     (do-custodian-shutdown-all orig-cust)
     (host:mutex-acquire lock)
     (set-place-result! new-place result)
     (host:mutex-release lock)
     (for ([pl (in-hash-keys done-waiting)])
       (wakeup-waiting pl))
     (hash-clear! done-waiting)))
  ;; Wait for the place to start, then return the place object
  (host:condition-wait started lock)
  (host:mutex-release lock)
  (end-atomic)
  (values new-place parent-in parent-out parent-err))

(define/who (place-break p [kind #f])
  (check who place? p)
  (unless (or (not kind) (eq? kind 'hangup) (eq? kind 'terminate))
    (raise-argument-error who "(or/c #f 'hangup 'terminate)" kind))
  (atomically
   (host:mutex-acquire (place-lock p))
   (define pending-break (place-pending-break p))
   (when (or (not pending-break)
             (break>? (or kind 'break) pending-break))
     (set-place-pending-break! p (or kind 'break))
     (place-has-activity! p)
     (sandman-wakeup (place-wakeup-handle p)))
   (host:mutex-release (place-lock p))))

(define (place-has-activity! p)
  (box-cas! (place-activity-canary p) #f #t)
  (void))

(void
 (set-check-place-activity!
  ;; Called in atomic mode by scheduler
  (lambda ()
    (define p current-place)
    (unless (box-cas! (place-activity-canary p) #f #f)
      (box-cas! (place-activity-canary p) #t #f)
      (host:mutex-acquire (place-lock p))
      (define queued-result (place-queued-result p))
      (define break (place-pending-break p))
      (define dequeue-semas (place-dequeue-semas p))
      (when break
        (set-place-pending-break! p #f))
      (when (pair? dequeue-semas)
        (set-place-dequeue-semas! p null))
      (host:mutex-release (place-lock p))
      (when queued-result
        (force-exit queued-result))
      (for ([s (in-list dequeue-semas)])
        (thread-did-work!)
        (semaphore-post-all/atomic s))
      (when break
        (thread-did-work!)
        (do-break-thread root-thread break #f))))))

(define/who (place-kill p)
  (check who place? p)
  (atomically
   (host:mutex-acquire (place-lock p))
   (unless (or (place-result p)
               (place-queued-result p))
     (set-place-queued-result! p 1)
     (place-has-activity! p))
   (host:mutex-release (place-lock p)))
  (place-wait p)
  (void))

(define/who (place-wait p)
  (check who place? p)
  (define result (sync (place-done-evt p #t)))
  (define vec (place-pumpers p))
  (when vec
    (for ([s (in-vector vec)])
      (when (thread? s) (thread-wait s)))
    (set-place-pumpers! p #f))
  result)

(struct place-done-evt (p get-result?)
  #:property prop:evt (poller (lambda (self poll-ctx)
                                (assert-atomic-mode)
                                (ensure-wakeup-handle!)
                                (define p (place-done-evt-p self))
                                (host:mutex-acquire (place-lock p))
                                (define result (place-result p))
                                (unless result
                                  (hash-set! (place-done-waiting p) current-place #t))
                                (host:mutex-release (place-lock p))
                                (if result
                                    (if (place-done-evt-get-result? self)
                                        (values (list result) #f)
                                        (values (list self) #f))
                                    (values #f self))))
  #:reflection-name 'place-dead-evt)

(define/who (place-dead-evt p)
  (check who place? p)
  (place-done-evt p #f))

;; ----------------------------------------

(struct message-queue (lock
                       [q #:mutable]
                       [rev-q #:mutable]
                       key-box              ; holds write key when non-empty
                       [waiters #:mutable]) ; hash of waiting place -> semaphore
  #:authentic)

(define (make-message-queue)
  (message-queue (host:make-mutex)
                 '()
                 '()
                 (box #f)
                 #hash()))

(define (enqueue! mq msg wk)
  (define lock (message-queue-lock mq))
  (atomically
   (host:mutex-acquire lock)
   (set-message-queue-rev-q! mq (cons msg (message-queue-rev-q mq)))
   (define waiters (message-queue-waiters mq))
   (set-message-queue-waiters! mq '#hash())
   (set-box! (message-queue-key-box mq) wk)
   (host:mutex-release lock)
   (for ([(pl s) (in-hash waiters)])
     (host:mutex-acquire (place-lock pl))
     (set-place-dequeue-semas! pl (cons s (place-dequeue-semas pl)))
     (place-has-activity! pl)
     (host:mutex-release (place-lock pl))
     (wakeup-waiting pl))))

;; in atomic mode
;; Either calls `success-k` or calls `fail-k` with
;; a semaphore to be posted when the queue receives
;; a message. Note that if the message queue becomes
;; inaccessible (so no writers), then the semaphores
;; become inaccessible.
(define (dequeue! mq success-k fail-k)
  (ensure-wakeup-handle!)
  (define lock (message-queue-lock mq))
  (host:mutex-acquire lock)
  (when (and (null? (message-queue-q mq))
             (not (null? (message-queue-rev-q mq))))
    (set-message-queue-q! mq (reverse (message-queue-rev-q mq)))
    (set-message-queue-rev-q! mq null))
  (define q (message-queue-q mq))
  (cond
    [(null? q)
     (define waiters (message-queue-waiters mq))
     (cond
       [(hash-ref waiters current-place #f)
        => (lambda (s)
             (host:mutex-release lock)
             (fail-k s))]
       [else
        (define s (make-semaphore))
        (set-message-queue-waiters! mq (hash-set waiters current-place s))
        (host:mutex-release lock)
        (fail-k s)])]
    [else
     (define new-q (cdr q))
     (set-message-queue-q! mq new-q)
     (when (null? new-q)
       (set-box! (message-queue-key-box mq) #f))
     (host:mutex-release lock)
     (success-k (car q))]))

;; ----------------------------------------

(struct pchannel (in-mq-e     ; ephemeron of writer key and message-queue
                  out-mq-e    ; ephemeron of reader key and message-queue
                  reader-key 
                  writer-key
                  in-key-box) ; causes in-mq-e to be retained when non-empty
  #:reflection-name 'place-channel
  #:property prop:evt (poller (lambda (self poll-ctx)
                                (define in-mq (ephemeron-value (pchannel-in-mq-e self)))
                                (if in-mq
                                    (dequeue! in-mq
                                              (lambda (v)
                                                (values #f
                                                        (wrap-evt
                                                         always-evt
                                                         (lambda (a)
                                                           ;; Convert when out of atomic region
                                                           (un-message-ize v)))))
                                              (lambda (sema)
                                                (values #f (replace-evt sema (lambda (s) self)))))
                                    (values #f never-evt))))
  #:property prop:place-message (lambda (self) (lambda () (lambda () self))))

(define (place-channel? v)
  (or (pchannel? v)
      (place? v)))

(define (unwrap-place-channel in-pch)
  (if (place? in-pch)
      (place-pch in-pch)
      in-pch))

(define (place-channel)
  (define mq1 (make-message-queue))
  (define mq2 (make-message-queue))
  (define rk1 (gensym 'read))
  (define wk1 (gensym 'write))
  (define rk2 (gensym 'read))
  (define wk2 (gensym 'write))
  (values (pchannel (make-ephemeron wk1 mq1) (make-ephemeron rk2 mq2) rk1 wk2 (message-queue-key-box mq1))
          (pchannel (make-ephemeron wk2 mq2) (make-ephemeron rk1 mq1) rk2 wk1 (message-queue-key-box mq2))))

(define/who (place-channel-get in-pch)
  (check who place-channel? in-pch)
  (define pch (unwrap-place-channel in-pch))
  (define in-mq (ephemeron-value (pchannel-in-mq-e pch)))
  (if in-mq
      (begin
        (start-atomic)
        (dequeue! in-mq
                  (lambda (v)
                    (end-atomic)
                    (un-message-ize v))
                  (lambda (sema)
                    (end-atomic)
                    (semaphore-wait sema)
                    (place-channel-get pch))))
      (sync never-evt)))

(define/who (place-channel-put in-pch in-v)
  (check who place-channel? in-pch)
  (define v
    (if (place-message-allowed-direct? in-v)
        in-v
        (message-ize
         in-v
         (lambda ()
           (raise-argument-error who "place-message-allowed?" in-v)))))
  (define pch (unwrap-place-channel in-pch))
  (define out-mq (ephemeron-value (pchannel-out-mq-e pch)))
  (when out-mq
    (enqueue! out-mq v (pchannel-writer-key pch))))

;; ----------------------------------------

;; in atomic mode
(define (ensure-wakeup-handle!)
  (unless (place-wakeup-handle current-place)
    (set-place-wakeup-handle! current-place (sandman-get-wakeup-handle))))

;; in atomic mode
(define (wakeup-waiting k)
  (host:mutex-acquire (place-lock k))
  (unless (place-result k)
    (sandman-wakeup (place-wakeup-handle k)))
  (host:mutex-release (place-lock k)))

;; ----------------------------------------

(define make-place-ports+fds
  ;; To be replaced by the "io" layer:
  (lambda (in out err)
    (values #f #f #f in out err)))

(define (set-make-place-ports+fds! proc)
  (set! make-place-ports+fds proc))

(define (place-pumper-threads p vec)
  (set-place-pumpers! p vec))

(define (unsafe-add-post-custodian-shutdown proc)
  (when (place-parent current-place)
    (atomically
     (set-place-post-shutdown! current-place
                               (cons proc
                                     (place-post-shutdown current-place))))))
