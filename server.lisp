;;; Copyright 2021 Google LLC
;;;
;;; Use of this source code is governed by an MIT-style
;;; license that can be found in the LICENSE file or at
;;; https://opensource.org/licenses/MIT.

;;;; Public Interface for gRPC

(in-package #:grpc)

(cffi:defcfun ("create_new_grpc_call_details"
               create-grpc-call-details )
  :pointer)

(cffi:defcfun ("delete_grpc_call_details"
               call-details-destroy )
  :void
  (call-details :pointer))

(cffi:defcfun ("start_server" start-server )
  :pointer
  (cq :pointer)
  (server-credentials :pointer)
  (server-address :string))

(cffi:defcfun ("register_method" register-method )
  :pointer
  (server :pointer)
  (method-name :string)
  (server-address :string))

(cffi:defcfun ("grpc_run_server" run-server )
  :pointer
  (server :pointer)
  (server-credentials :pointer))

(cffi:defcfun ("lisp_grpc_server_request_call" grpc-server-request-call )
  :pointer
  (server :pointer)
  (details :pointer)
  (request-metadata :pointer)
  (cq-bound :pointer)
  (cq-notify :pointer)
  (tag :pointer))

(cffi:defcfun ("shutdown_server" shutdown-server )
  :void
  (server :pointer)
  (cq :pointer)
  (tag :pointer))

(defun start-call-on-server (server)
  "Make gRPC SERVER call and return a call struct"
  (let* ((tag (cffi:foreign-alloc :int))
         (metadata (create-new-grpc-metadata-array))
         (call-details (create-grpc-call-details))
         (c-call (grpc-server-request-call server call-details
                                           metadata
                                           grpc::*completion-queue*
                                           grpc::*completion-queue* tag))
         (method (get-call-method call-details)))
    (assert (not (cffi:null-pointer-p c-call)))
    (metadata-destroy metadata)
    (call-details-destroy call-details)
    (grpc::make-call :c-call c-call
                     :c-tag tag
                     :c-ops (cffi:null-pointer)
                     :call-details (make-call-details
                                    :method-name method)
                     :ops-plist nil)))

(defun receive-message-from-client (call)
  "Receive a message from the client for a CALL."
  (declare (type call call))
  (let* ((tag (cffi:foreign-alloc :int))
         (c-call (call-c-call call))
         (receive-op (create-new-grpc-ops 1))
         (ops-plist (prepare-ops receive-op nil :recv-message t))
         (call-code (call-start-batch c-call receive-op 1 tag)))
    (unless (eql call-code :grpc-call-ok)
      (grpc-ops-free receive-op 1)
      (cffi:foreign-free tag)
      (error 'grpc-call-error :call-error call-code))
    (when (completion-queue-pluck *completion-queue* tag)
      (cffi:foreign-free tag)
      (let* ((response-byte-buffer
               (get-grpc-op-recv-message receive-op (getf ops-plist :recv-message)))
             (message
               (unless (cffi:null-pointer-p response-byte-buffer)
                 (loop for index from 0
                         to (1- (get-grpc-byte-buffer-slice-buffer-count
                                 response-byte-buffer))
                       collecting (get-bytes-from-grpc-byte-buffer
                                   response-byte-buffer index)
                         into message
                       finally
                          (grpc-byte-buffer-destroy response-byte-buffer)
                          (return message)))))
        (grpc-ops-free receive-op 1)
        ;; TO-DO(gprasun)
        ;; Send back the GRPC-CALL-OK status from the server
        ;; as it is checked by the client in send-message and receive-mesage
        message))))

(defun send-initial-metadata (call)
  "Send the GRPC_OP_SEND_INITIAL_METADATA from the server through a CALL"
  (declare (type call call))
  (let* ((num-ops 1)
         (c-call (call-c-call call))
         (tag (cffi:foreign-alloc :int))
         (ops (create-new-grpc-ops num-ops))
         (ops-plist (prepare-ops ops nil :send-metadata t))
         (call-code (call-start-batch c-call ops num-ops tag)))
    (declare (ignore ops-plist))
    (unless (eql call-code :grpc-call-ok)
      (cffi:foreign-free tag)
      (grpc-ops-free ops num-ops)
      (error 'grpc-call-error :call-error call-code))
    (let ((cqp-p (completion-queue-pluck *completion-queue* tag)))
      (grpc-ops-free ops num-ops)
      (cffi:foreign-free tag)
      cqp-p)))

(defun server-send-message (call bytes-to-send)
  "Send the GRPC_OP_SEND_MESSAGE message encoded in BYTES-TO-SEND to the server through a CALL"
  (declare (type call call))
  (let* ((num-ops 1)
         (c-call (call-c-call call))
         (tag (cffi:foreign-alloc :int))
         (ops (create-new-grpc-ops num-ops))
         (grpc-slice
          (convert-bytes-to-grpc-byte-buffer bytes-to-send))
         (ops-plist (prepare-ops ops grpc-slice :send-message t))
         (call-code (call-start-batch c-call ops num-ops tag)))
    (declare (ignore ops-plist))
    (unless (eql call-code :grpc-call-ok)
      (cffi:foreign-free tag)
      (grpc-ops-free ops num-ops)
      (error 'grpc-call-error :call-error call-code))
    (let ((cqp-p (completion-queue-pluck *completion-queue* tag)))
      (grpc-ops-free ops num-ops)
      (cffi:foreign-free tag)
      cqp-p)))

(defun server-send-status (call)
  "Send the GRPC_OP_SEND_STATUS_FROM_SERVER from the server through a CALL"
  (declare (type call call))
  (let* ((num-ops 1)
         (c-call (call-c-call call))
         (tag (cffi:foreign-alloc :int))
         (ops (create-new-grpc-ops num-ops))
         (ops-plist (prepare-ops ops nil :server-send-status :grpc-status-ok))
         (call-code (call-start-batch c-call ops num-ops tag)))
    (declare (ignore ops-plist))
    (unless (eql call-code :grpc-call-ok)
      (cffi:foreign-free tag)
      (grpc-ops-free ops num-ops)
      (error 'grpc-call-error :call-error call-code))
    (let ((cqp-p (completion-queue-pluck *completion-queue* tag)))
      (grpc-ops-free ops num-ops)
      (cffi:foreign-free tag)
      cqp-p)))

(defun server-recv-close (call)
  "Send the GRPC_OP_RECV_STATUS_ON_CLIENT from the server through a CALL"
  (declare (type call call))
  (let* ((num-ops 1)
         (c-call (call-c-call call))
         (tag (cffi:foreign-alloc :int))
         (ops (create-new-grpc-ops num-ops))
         (ops-plist (prepare-ops ops nil :server-recv-close t))
         (call-code (call-start-batch c-call ops num-ops tag)))
    (declare (ignore ops-plist))
    (unless (eql call-code :grpc-call-ok)
      (cffi:foreign-free tag)
      (grpc-ops-free ops num-ops)
      (error 'grpc-call-error :call-error call-code))
    (let ((cqp-p (completion-queue-pluck *completion-queue* tag)))
      (grpc-ops-free ops num-ops)
      (cffi:foreign-free tag)
      cqp-p)))

(defun send-message-to-client (call bytes-to-send)
  "Send a message encoded in BYTES-TO-SEND to the server through a CALL with the
  use of four gRPC ops"
  (send-initial-metadata call)
  (server-send-message call bytes-to-send)
  (server-send-status call)
  (server-recv-close call))

(defun run-methods (methods server)
  (let* ((call (start-call-on-server server))
         (messages (receive-message-from-client call))
         (message (apply #'concatenate '(array (unsigned-byte 8) (*)) messages)))
    (unwind-protect
         (format t "~A" call)
      (let* ((method (find (call-details-method-name
                            (call-call-details call))
                           methods
                           :test #'string=
                           :key #'car))
             (response (funcall (second method) message)))
        (format t "~%~A~%" response)
        (send-message-to-client call response))
      (free-call-data call))))

(defun run-grpc-server (address methods cq &key
                                           (num-threads 1)
                                           (run-methods #'run-methods)
                                           (exit-count nil)
                                           )
  (let* ((server-creds (grpc-insecure-server-credentials-create))
         (server (start-server cq server-creds address))
         (sem (bordeaux-threads-2:make-semaphore :count num-threads))
         threads)

    (dolist (method methods)
      (format t "~s~%" (car method))
      (register-method server (car method) address))
    (run-server server server-creds)

    (unwind-protect
         (loop for run-count from 0
               while (or (not exit-count)
                         (< run-count exit-count))
               do
            (bordeaux-threads-2:wait-on-semaphore sem)
            (push
             (bordeaux-threads-2:make-thread
              (lambda ()
                (funcall run-methods methods server)
                (bordeaux-threads-2:signal-semaphore sem))
              :name (format nil "Run Method Run ~a" run-count))
             threads)))

    (dolist (thread threads)
      (bordeaux-threads-2:join-thread thread))

    (shutdown-server server cq (cffi:foreign-alloc :int))))
