;;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; *************************************************************************
;;;; FILE IDENTIFICATION
;;;;
;;;; Name:          classes.cl
;;;; Purpose:       Classes for High-level SQL interface
;;;; Programmers:   Kevin M. Rosenberg based on
;;;;                 Original code by Pierre R. Mai 
;;;; Date Started:  Feb 2002
;;;;
;;;; $Id: classes.cl,v 1.1 2002/03/29 08:13:02 kevin Exp $
;;;;
;;;; This file, part of CLSQL, is Copyright (c) 2002 by Kevin M. Rosenberg
;;;; and Copyright (c) 1999-2001 by Pierre R. Mai
;;;;
;;;; CLSQL users are granted the rights to distribute and use this software
;;;; as governed by the terms of the Lisp Lesser GNU Public License
;;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;; *************************************************************************

(declaim (optimize (debug 3) (speed 3) (safety 1) (compilation-speed 0)))
(in-package :clsql-sys)


(defclass database ()
  ((name :initarg :name :reader database-name))
  (:documentation
   "This class is the supertype of all databases handled by CLSQL."))

(defmethod print-object ((object database) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (write-string (if (slot-boundp object 'name)
		      (database-name object)
		      "<unbound>")
		  stream)))


(defclass closed-database ()
  ((name :initarg :name :reader database-name))
  (:documentation
   "This class represents all databases after they are closed via
`disconnect'."))

(defmethod print-object ((object closed-database) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (write-string (if (slot-boundp object 'name)
		      (database-name object)
		      "<unbound>")
		  stream)))
