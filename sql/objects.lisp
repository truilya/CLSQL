;;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; *************************************************************************
;;;;
;;;; $Id$
;;;;
;;;; The CLSQL Object Oriented Data Definitional Language (OODDL)
;;;; and Object Oriented Data Manipulation Language (OODML).
;;;;
;;;; This file is part of CLSQL.
;;;;
;;;; CLSQL users are granted the rights to distribute and use this software
;;;; as governed by the terms of the Lisp Lesser GNU Public License
;;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;; *************************************************************************

(in-package #:clsql)

(defclass standard-db-object ()
  ((view-database :initform nil :initarg :view-database :reader view-database
    :db-kind :virtual))
  (:metaclass standard-db-class)
  (:documentation "Superclass for all CLSQL View Classes."))

(defvar *db-auto-sync* nil 
  "A non-nil value means that creating View Class instances or
  setting their slots automatically creates/updates the
  corresponding records in the underlying database.")

(defvar *db-deserializing* nil)
(defvar *db-initializing* nil)

(defmethod slot-value-using-class ((class standard-db-class) instance slot-def)
  (declare (optimize (speed 3)))
  (unless *db-deserializing*
    (let* ((slot-name (%svuc-slot-name slot-def))
	   (slot-object (%svuc-slot-object slot-def class))
	   (slot-kind (view-class-slot-db-kind slot-object)))
      (when (and (eql slot-kind :join)
                 (not (slot-boundp instance slot-name)))
        (let ((*db-deserializing* t))
          (if (view-database instance)
              (setf (slot-value instance slot-name)
                    (fault-join-slot class instance slot-object))
              (setf (slot-value instance slot-name) nil))))))
  (call-next-method))

(defmethod (setf slot-value-using-class) (new-value (class standard-db-class)
					  instance slot-def)
  (declare (ignore new-value))
  (let* ((slot-name (%svuc-slot-name slot-def))
	 (slot-object (%svuc-slot-object slot-def class))
	 (slot-kind (view-class-slot-db-kind slot-object)))
    (call-next-method)
    (when (and *db-auto-sync* 
	       (not *db-initializing*)
	       (not *db-deserializing*)
	       (not (eql slot-kind :virtual)))
      (update-record-from-slot instance slot-name))))

(defmethod initialize-instance ((object standard-db-object)
					&rest all-keys &key &allow-other-keys)
  (declare (ignore all-keys))
  (let ((*db-initializing* t))
    (call-next-method)
    (when (and *db-auto-sync*
	       (not *db-deserializing*))
      (update-records-from-instance object))))

;;
;; Build the database tables required to store the given view class
;;

(defun create-view-from-class (view-class-name
                               &key (database *default-database*))
  "Creates a view in DATABASE based on VIEW-CLASS-NAME which defines
the view. The argument DATABASE has a default value of
*DEFAULT-DATABASE*."
  (let ((tclass (find-class view-class-name)))
    (if tclass
        (let ((*default-database* database))
          (%install-class tclass database))
        (error "Class ~s not found." view-class-name)))
  (values))

(defmethod %install-class ((self standard-db-class) database &aux schemadef)
  (dolist (slotdef (ordered-class-slots self))
    (let ((res (database-generate-column-definition (class-name self)
                                                    slotdef database)))
      (when res 
        (push res schemadef))))
  (unless schemadef
    (error "Class ~s has no :base slots" self))
  (create-table (sql-expression :table (view-table self)) schemadef
                :database database
                :constraints (database-pkey-constraint self database))
  (push self (database-view-classes database))
  t)

(defmethod database-pkey-constraint ((class standard-db-class) database)
  (let ((keylist (mapcar #'view-class-slot-column (keyslots-for-class class))))
    (when keylist 
      (convert-to-db-default-case
       (format nil "CONSTRAINT ~APK PRIMARY KEY~A"
	       (database-output-sql (view-table class) database)
	       (database-output-sql keylist database))
       database))))

(defmethod database-generate-column-definition (class slotdef database)
  (declare (ignore database class))
  (when (member (view-class-slot-db-kind slotdef) '(:base :key))
    (let ((cdef
           (list (sql-expression :attribute (view-class-slot-column slotdef))
                 (specified-type slotdef))))
      (setf cdef (append cdef (list (view-class-slot-db-type slotdef))))
      (let ((const (view-class-slot-db-constraints slotdef)))
        (when const 
          (setq cdef (append cdef (list const)))))
      cdef)))


;;
;; Drop the tables which store the given view class
;;

(defun drop-view-from-class (view-class-name &key (database *default-database*))
  "Deletes a view or base table from DATABASE based on VIEW-CLASS-NAME
which defines that view. The argument DATABASE has a default value of
*DEFAULT-DATABASE*."
  (let ((tclass (find-class view-class-name)))
    (if tclass
        (let ((*default-database* database))
          (%uninstall-class tclass))
        (error "Class ~s not found." view-class-name)))
  (values))

(defun %uninstall-class (self &key (database *default-database*))
  (drop-table (sql-expression :table (view-table self))
              :if-does-not-exist :ignore
              :database database)
  (setf (database-view-classes database)
        (remove self (database-view-classes database))))


;;
;; List all known view classes
;;

(defun list-classes (&key (test #'identity)
		     (root-class (find-class 'standard-db-object))
		     (database *default-database*))
  "The LIST-CLASSES function collects all the classes below
ROOT-CLASS, which defaults to standard-db-object, that are connected
to the supplied DATABASE and which satisfy the TEST function. The
default for the TEST argument is identity. By default, LIST-CLASSES
returns a list of all the classes connected to the default database,
*DEFAULT-DATABASE*."
  (flet ((find-superclass (class) 
	   (member root-class (class-precedence-list class))))
    (let ((view-classes (and database (database-view-classes database))))
      (when view-classes
	(remove-if #'(lambda (c) (or (not (funcall test c))
				     (not (find-superclass c))))
		   view-classes)))))

;;
;; Define a new view class
;;

(defmacro def-view-class (class supers slots &rest cl-options)
  "Extends the syntax of defclass to allow special slots to be mapped
onto the attributes of database views. The macro DEF-VIEW-CLASS
creates a class called CLASS which maps onto a database view. Such a
class is called a View Class. The macro DEF-VIEW-CLASS extends the
syntax of DEFCLASS to allow special base slots to be mapped onto the
attributes of database views (presently single tables). When a select
query that names a View Class is submitted, then the corresponding
database view is queried, and the slots in the resulting View Class
instances are filled with attribute values from the database. If
SUPERS is nil then STANDARD-DB-OBJECT automatically becomes the
superclass of the newly-defined View Class."
  `(progn
    (defclass ,class ,supers ,slots 
      ,@(if (find :metaclass `,cl-options :key #'car)
	    `,cl-options
	    (cons '(:metaclass clsql::standard-db-class) `,cl-options)))
    (finalize-inheritance (find-class ',class))
    (find-class ',class)))

(defun keyslots-for-class (class)
  (slot-value class 'key-slots))

(defun key-qualifier-for-instance (obj &key (database *default-database*))
  (let ((tb (view-table (class-of obj))))
    (flet ((qfk (k)
             (sql-operation '==
                            (sql-expression :attribute
                                            (view-class-slot-column k)
                                            :table tb)
                            (db-value-from-slot
                             k
                             (slot-value obj (slot-definition-name k))
                             database))))
      (let* ((keys (keyslots-for-class (class-of obj)))
	     (keyxprs (mapcar #'qfk (reverse keys))))
	(cond
          ((= (length keyxprs) 0) nil)
          ((= (length keyxprs) 1) (car keyxprs))
          ((> (length keyxprs) 1) (apply #'sql-operation 'and keyxprs)))))))

;;
;; Function used by 'generate-selection-list'
;;

(defun generate-attribute-reference (vclass slotdef)
  (cond
   ((eq (view-class-slot-db-kind slotdef) :base)
    (sql-expression :attribute (view-class-slot-column slotdef)
		    :table (view-table vclass)))
   ((eq (view-class-slot-db-kind slotdef) :key)
    (sql-expression :attribute (view-class-slot-column slotdef)
		    :table (view-table vclass)))
   (t nil)))

;;
;; Function used by 'find-all'
;;

(defun generate-selection-list (vclass)
  (let ((sels nil))
    (dolist (slotdef (ordered-class-slots vclass))
      (let ((res (generate-attribute-reference vclass slotdef)))
	(when res
          (push (cons slotdef res) sels))))
    (if sels
	sels
        (error "No slots of type :base in view-class ~A" (class-name vclass)))))



(defun generate-retrieval-joins-list (vclass retrieval-method)
  "Returns list of immediate join slots for a class."
  (let ((join-slotdefs nil))
    (dolist (slotdef (ordered-class-slots vclass) join-slotdefs)
      (when (and (eq :join (view-class-slot-db-kind slotdef))
		 (eq retrieval-method (gethash :retrieval (view-class-slot-db-info slotdef))))
	(push slotdef join-slotdefs)))))

(defun generate-immediate-joins-selection-list (vclass)
  "Returns list of immediate join slots for a class."
  (let (sels)
    (dolist (joined-slot (generate-retrieval-joins-list vclass :immediate) sels)
      (let* ((join-class-name (gethash :join-class (view-class-slot-db-info joined-slot)))
	     (join-class (when join-class-name (find-class join-class-name))))
	(dolist (slotdef (ordered-class-slots join-class))
	  (let ((res (generate-attribute-reference join-class slotdef)))
	    (when res
	      (push (cons slotdef res) sels))))))
    sels))


;; Called by 'get-slot-values-from-view'
;;

(defvar *update-context* nil)

(defmethod update-slot-from-db ((instance standard-db-object) slotdef value)
  (declare (optimize (speed 3) #+cmu (extensions:inhibit-warnings 3)))
  (let* ((slot-reader (view-class-slot-db-reader slotdef))
	 (slot-name   (slot-definition-name slotdef))
	 (slot-type   (specified-type slotdef))
	 (*update-context* (cons (type-of instance) slot-name)))
    (cond ((and value (null slot-reader))
           (setf (slot-value instance slot-name)
                 (read-sql-value value (delistify slot-type)
                                 (view-database instance))))
          ((null value)
           (update-slot-with-null instance slot-name slotdef))
          ((typep slot-reader 'string)
           (setf (slot-value instance slot-name)
                 (format nil slot-reader value)))
          ((typep slot-reader 'function)
           (setf (slot-value instance slot-name)
                 (apply slot-reader (list value))))
          (t
           (error "Slot reader is of an unusual type.")))))

(defmethod key-value-from-db (slotdef value database) 
  (declare (optimize (speed 3) #+cmu (extensions:inhibit-warnings 3)))
  (let ((slot-reader (view-class-slot-db-reader slotdef))
        (slot-type (specified-type slotdef)))
    (cond ((and value (null slot-reader))
           (read-sql-value value (delistify slot-type) database))
          ((null value)
           nil)
          ((typep slot-reader 'string)
           (format nil slot-reader value))
          ((typep slot-reader 'function)
           (apply slot-reader (list value)))
          (t
           (error "Slot reader is of an unusual type.")))))

(defun db-value-from-slot (slotdef val database)
  (let ((dbwriter (view-class-slot-db-writer slotdef))
	(dbtype (specified-type slotdef)))
    (typecase dbwriter
      (string (format nil dbwriter val))
      (function (apply dbwriter (list val)))
      (t
       (typecase dbtype
	 (cons
	  (database-output-sql-as-type (car dbtype) val database))
	 (t
	  (database-output-sql-as-type dbtype val database)))))))

(defun check-slot-type (slotdef val)
  (let* ((slot-type (specified-type slotdef))
         (basetype (if (listp slot-type) (car slot-type) slot-type)))
    (when (and slot-type val)
      (unless (typep val basetype)
        (error 'clsql-type-error
               :slotname (slot-definition-name slotdef)
               :typespec slot-type
               :value val)))))

;;
;; Called by find-all
;;

(defmethod get-slot-values-from-view (obj slotdeflist values)
    (flet ((update-slot (slot-def values)
	     (update-slot-from-db obj slot-def values)))
      (mapc #'update-slot slotdeflist values)
      obj))

(defmethod update-record-from-slot ((obj standard-db-object) slot &key
				    (database *default-database*))
  (let* ((database (or (view-database obj) database))
	 (vct (view-table (class-of obj)))
         (sd (slotdef-for-slot-with-class slot (class-of obj))))
    (check-slot-type sd (slot-value obj slot))
    (let* ((att (view-class-slot-column sd))
           (val (db-value-from-slot sd (slot-value obj slot) database)))
      (cond ((and vct sd (view-database obj))
             (update-records (sql-expression :table vct)
                             :attributes (list (sql-expression :attribute att))
                             :values (list val)
                             :where (key-qualifier-for-instance
                                     obj :database database)
                             :database database))
            ((and vct sd (not (view-database obj)))
	     (insert-records :into (sql-expression :table vct)
                             :attributes (list (sql-expression :attribute att))
                             :values (list val)
			     :database database)
	     (setf (slot-value obj 'view-database) database))
            (t
             (error "Unable to update record.")))))
  (values))

(defmethod update-record-from-slots ((obj standard-db-object) slots &key
                                     (database *default-database*))
  (let* ((database (or (view-database obj) database))
	 (vct (view-table (class-of obj)))
         (sds (slotdefs-for-slots-with-class slots (class-of obj)))
         (avps (mapcar #'(lambda (s)
                           (let ((val (slot-value
                                       obj (slot-definition-name s))))
                             (check-slot-type s val)
                             (list (sql-expression
                                    :attribute (view-class-slot-column s))
                                   (db-value-from-slot s val database))))
                       sds)))
    (cond ((and avps (view-database obj))
           (update-records (sql-expression :table vct)
                           :av-pairs avps
                           :where (key-qualifier-for-instance
                                   obj :database database)
                           :database database))
          ((and avps (not (view-database obj)))
           (insert-records :into (sql-expression :table vct)
                           :av-pairs avps
                           :database database)
           (setf (slot-value obj 'view-database) database))
          (t
           (error "Unable to update records"))))
  (values))

(defmethod update-records-from-instance ((obj standard-db-object)
                                         &key (database *default-database*))
  (let ((database (or (view-database obj) database)))
    (labels ((slot-storedp (slot)
	       (and (member (view-class-slot-db-kind slot) '(:base :key))
		    (slot-boundp obj (slot-definition-name slot))))
	     (slot-value-list (slot)
	       (let ((value (slot-value obj (slot-definition-name slot))))
		 (check-slot-type slot value)
		 (list (sql-expression :attribute (view-class-slot-column slot))
		       (db-value-from-slot slot value database)))))
      (let* ((view-class (class-of obj))
	     (view-class-table (view-table view-class))
	     (slots (remove-if-not #'slot-storedp 
				   (ordered-class-slots view-class)))
	     (record-values (mapcar #'slot-value-list slots)))
	(unless record-values
	  (error "No settable slots."))
	(if (view-database obj)
	    (update-records (sql-expression :table view-class-table)
			    :av-pairs record-values
			    :where (key-qualifier-for-instance
				    obj :database database)
			    :database database)
	    (progn
	      (insert-records :into (sql-expression :table view-class-table)
			      :av-pairs record-values
			      :database database)
	      (setf (slot-value obj 'view-database) database))))))
  (values))

(defmethod delete-instance-records ((instance standard-db-object))
  (let ((vt (sql-expression :table (view-table (class-of instance))))
	(vd (view-database instance)))
    (if vd
	(let ((qualifier (key-qualifier-for-instance instance :database vd)))
	  (delete-records :from vt :where qualifier :database vd)
	  (setf (slot-value instance 'view-database) nil))
	(error 'clsql-base::clsql-no-database-error :database nil))))

(defmethod update-instance-from-records ((instance standard-db-object)
                                         &key (database *default-database*))
  (let* ((view-class (find-class (class-name (class-of instance))))
         (view-table (sql-expression :table (view-table view-class)))
         (vd (or (view-database instance) database))
         (view-qual (key-qualifier-for-instance instance :database vd))
         (sels (generate-selection-list view-class))
         (res (apply #'select (append (mapcar #'cdr sels)
                                      (list :from  view-table
                                            :where view-qual)
				      (list :result-types nil)))))
    (when res
      (get-slot-values-from-view instance (mapcar #'car sels) (car res)))))

(defmethod update-slot-from-record ((instance standard-db-object)
                                    slot &key (database *default-database*))
  (let* ((view-class (find-class (class-name (class-of instance))))
         (view-table (sql-expression :table (view-table view-class)))
         (vd (or (view-database instance) database))
         (view-qual (key-qualifier-for-instance instance :database vd))
         (slot-def (slotdef-for-slot-with-class slot view-class))
         (att-ref (generate-attribute-reference view-class slot-def))
         (res (select att-ref :from  view-table :where view-qual
		      :result-types nil)))
    (when res 
      (get-slot-values-from-view instance (list slot-def) (car res)))))


(defmethod update-slot-with-null ((object standard-db-object)
				  slotname
				  slotdef)
  (setf (slot-value object slotname) (slot-value slotdef 'void-value)))

(defvar +no-slot-value+ '+no-slot-value+)

(defsql sql-slot-value (:symbol "slot-value") (classname slot &optional (value +no-slot-value+) (database *default-database*))
  (let* ((class (find-class classname))
	 (sld (slotdef-for-slot-with-class slot class)))
    (if sld
	(if (eq value +no-slot-value+)
	    (sql-expression :attribute (view-class-slot-column sld)
			    :table (view-table class))
            (db-value-from-slot
             sld
             value
             database))
        (error "Unknown slot ~A for class ~A" slot classname))))

(defsql sql-view-class (:symbol "view-class") (classname &optional (database *default-database*))
	(declare (ignore database))
	(let* ((class (find-class classname)))
	  (unless (view-table class)
	    (error "No view-table for class ~A"  classname))
	  (sql-expression :table (view-table class))))

(defmethod database-get-type-specifier (type args database)
  (declare (ignore type args))
  (if (clsql-base::in (database-underlying-type database)
			  :postgresql :postgresql-socket)
          "VARCHAR"
          "VARCHAR(255)"))

(defmethod database-get-type-specifier ((type (eql 'integer)) args database)
  (declare (ignore database))
  ;;"INT8")
  (if args
      (format nil "INT(~A)" (car args))
      "INT"))

(deftype bigint () 
  "An integer larger than a 32-bit integer, this width may vary by SQL implementation."
  'integer)

(defmethod database-get-type-specifier ((type (eql 'bigint)) args database)
  (declare (ignore args database))
  "BIGINT")
              
(defmethod database-get-type-specifier ((type (eql 'simple-base-string)) args
                                        database)
  (if args
      (format nil "VARCHAR(~A)" (car args))
    (if (clsql-base::in (database-underlying-type database) 
			    :postgresql :postgresql-socket)
	"VARCHAR"
      "VARCHAR(255)")))

(defmethod database-get-type-specifier ((type (eql 'simple-string)) args
                                        database)
  (if args
      (format nil "VARCHAR(~A)" (car args))
    (if (clsql-base::in (database-underlying-type database) 
			    :postgresql :postgresql-socket)
	"VARCHAR"
      "VARCHAR(255)")))

(defmethod database-get-type-specifier ((type (eql 'string)) args database)
  (if args
      (format nil "VARCHAR(~A)" (car args))
    (if (clsql-base::in (database-underlying-type database) 
			    :postgresql :postgresql-socket)
	"VARCHAR"
      "VARCHAR(255)")))

(deftype universal-time () 
  "A positive integer as returned by GET-UNIVERSAL-TIME."
  '(integer 1 *))

(defmethod database-get-type-specifier ((type (eql 'universal-time)) args database)
  (declare (ignore args database))
  "BIGINT")

(defmethod database-get-type-specifier ((type (eql 'wall-time)) args database)
  (declare (ignore args))
  (case (database-underlying-type database)
    ((:postgresql :postgresql-socket)
     "TIMESTAMP WITHOUT TIME ZONE")
    (:mysql
     "DATETIME")
    (t "TIMESTAMP")))

(defmethod database-get-type-specifier ((type (eql 'duration)) args database)
  (declare (ignore database args))
  "VARCHAR")

(defmethod database-get-type-specifier ((type (eql 'money)) args database)
  (declare (ignore database args))
  "INT8")

(deftype raw-string (&optional len)
  "A string which is not trimmed when retrieved from the database"
  `(string ,len))

(defmethod database-get-type-specifier ((type (eql 'raw-string)) args database)
  (declare (ignore database))
  (if args
      (format nil "VARCHAR(~A)" (car args))
      "VARCHAR"))

(defmethod database-get-type-specifier ((type (eql 'float)) args database)
  (declare (ignore database))
  (if args
      (format nil "FLOAT(~A)" (car args))
      "FLOAT"))

(defmethod database-get-type-specifier ((type (eql 'long-float)) args database)
  (declare (ignore database))
  (if args
      (format nil "FLOAT(~A)" (car args))
      "FLOAT"))

(defmethod database-get-type-specifier ((type (eql 'boolean)) args database)
  (declare (ignore args database))
  "BOOL")

(defmethod database-output-sql-as-type (type val database)
  (declare (ignore type database))
  val)

(defmethod database-output-sql-as-type ((type (eql 'list)) val database)
  (declare (ignore database))
  (progv '(*print-circle* *print-array*) '(t t)
    (let ((escaped (prin1-to-string val)))
      (clsql-base::substitute-char-string
       escaped #\Null " "))))

(defmethod database-output-sql-as-type ((type (eql 'symbol)) val database)
  (declare (ignore database))
  (if (keywordp val)
      (symbol-name val)
      (if val
          (concatenate 'string
                       (package-name (symbol-package val))
                       "::"
                       (symbol-name val))
          "")))

(defmethod database-output-sql-as-type ((type (eql 'keyword)) val database)
  (declare (ignore database))
  (if val
      (symbol-name val)
      ""))

(defmethod database-output-sql-as-type ((type (eql 'vector)) val database)
  (declare (ignore database))
  (progv '(*print-circle* *print-array*) '(t t)
    (prin1-to-string val)))

(defmethod database-output-sql-as-type ((type (eql 'array)) val database)
  (declare (ignore database))
  (progv '(*print-circle* *print-array*) '(t t)
    (prin1-to-string val)))

(defmethod database-output-sql-as-type ((type (eql 'boolean)) val database)
  (case (database-underlying-type database)
    (:mysql
     (if val 1 0))
    (t
     (if val "t" "f"))))

(defmethod database-output-sql-as-type ((type (eql 'string)) val database)
  (declare (ignore database))
  val)

(defmethod database-output-sql-as-type ((type (eql 'simple-string))
					val database)
  (declare (ignore database))
  val)

(defmethod database-output-sql-as-type ((type (eql 'simple-base-string))
					val database)
  (declare (ignore database))
  val)

(defmethod read-sql-value (val type database)
  (declare (ignore type database))
  (read-from-string val))

(defmethod read-sql-value (val (type (eql 'string)) database)
  (declare (ignore database))
  val)

(defmethod read-sql-value (val (type (eql 'simple-string)) database)
  (declare (ignore database))
  val)

(defmethod read-sql-value (val (type (eql 'simple-base-string)) database)
  (declare (ignore database))
  val)

(defmethod read-sql-value (val (type (eql 'raw-string)) database)
  (declare (ignore database))
  val)

(defmethod read-sql-value (val (type (eql 'keyword)) database)
  (declare (ignore database))
  (when (< 0 (length val))
    (intern (symbol-name-default-case val) 
	    (find-package '#:keyword))))

(defmethod read-sql-value (val (type (eql 'symbol)) database)
  (declare (ignore database))
  (when (< 0 (length val))
    (unless (string= val (clsql-base:symbol-name-default-case "NIL"))
      (intern (clsql-base:symbol-name-default-case val)
              (symbol-package *update-context*)))))

(defmethod read-sql-value (val (type (eql 'integer)) database)
  (declare (ignore database))
  (etypecase val
    (string
     (unless (string-equal "NIL" val)
       (parse-integer val)))
    (number val)))

(defmethod read-sql-value (val (type (eql 'bigint)) database)
  (declare (ignore database))
  (etypecase val
    (string
     (unless (string-equal "NIL" val)
       (parse-integer val)))
    (number val)))

(defmethod read-sql-value (val (type (eql 'float)) database)
  (declare (ignore database))
  ;; writing 1.0 writes 1, so we we *really* want a float, must do (float ...)
  (float (read-from-string val))) 

(defmethod read-sql-value (val (type (eql 'boolean)) database)
  (case (database-underlying-type database)
    (:mysql
     (etypecase val
       (string (if (string= "0" val) nil t))
       (integer (if (zerop val) nil t))))
    (:postgresql
     (if (eq :odbc (database-type database))
	 (if (string= "0" val) nil t)
       (equal "t" val)))
    (t
     (equal "t" val))))

(defmethod read-sql-value (val (type (eql 'univeral-time)) database)
  (declare (ignore database))
  (unless (eq 'NULL val)
    (etypecase val
      (string
       (parse-integer val))
      (number val))))

(defmethod read-sql-value (val (type (eql 'wall-time)) database)
  (declare (ignore database))
  (unless (eq 'NULL val)
    (parse-timestring val)))

(defmethod read-sql-value (val (type (eql 'duration)) database)
  (declare (ignore database))
  (unless (or (eq 'NULL val)
              (equal "NIL" val))
    (parse-timestring val)))

;; ------------------------------------------------------------
;; Logic for 'faulting in' :join slots

;; this works, but is inefficient requiring (+ 1 n-rows)
;; SQL queries
#+ignore
(defun fault-join-target-slot (class object slot-def)
  (let* ((res (fault-join-slot-raw class object slot-def))
	 (dbi (view-class-slot-db-info slot-def))
	 (target-name (gethash :target-slot dbi))
	 (target-class (find-class target-name)))
    (when res
      (mapcar (lambda (obj)
		(list 
		 (car
		  (fault-join-slot-raw 
		   target-class
		   obj
		   (find target-name (class-slots (class-of obj))
			 :key #'slot-definition-name)))
		 obj))
	      res)
      #+ignore ;; this doesn't work when attempting to call slot-value
      (mapcar (lambda (obj)
		(cons obj (slot-value obj ts))) res))))

(defun fault-join-target-slot (class object slot-def)
  (let* ((dbi (view-class-slot-db-info slot-def))
	 (ts (gethash :target-slot dbi))
	 (jc (gethash :join-class dbi))
	 (ts-view-table (view-table (find-class ts)))
	 (jc-view-table (view-table (find-class jc)))
	 (tdbi (view-class-slot-db-info 
		(find ts (class-slots (find-class jc))
		      :key #'slot-definition-name)))
	 (retrieval (gethash :retrieval tdbi))
	 (jq (join-qualifier class object slot-def))
	 (key (slot-value object (gethash :home-key dbi))))
    (when jq
      (ecase retrieval
	(:immediate
	 (let ((res
		(find-all (list ts) 
			  :inner-join (sql-expression :table jc-view-table)
			  :on (sql-operation 
			       '==
			       (sql-expression 
				:attribute (gethash :foreign-key tdbi) 
				:table ts-view-table)
			       (sql-expression 
				:attribute (gethash :home-key tdbi) 
				:table jc-view-table))
			  :where jq
			  :result-types :auto)))
	   (mapcar #'(lambda (i)
		       (let* ((instance (car i))
			      (jcc (make-instance jc :view-database (view-database instance))))
			 (setf (slot-value jcc (gethash :foreign-key dbi)) 
			       key)
			 (setf (slot-value jcc (gethash :home-key tdbi)) 
			       (slot-value instance (gethash :foreign-key tdbi)))
		      (list instance jcc)))
		   res)))
	(:deferred
	    ;; just fill in minimal slots
	    (mapcar
	     #'(lambda (k)
		 (let ((instance (make-instance ts :view-database (view-database object)))
		       (jcc (make-instance jc :view-database (view-database object)))
		       (fk (car k)))
		   (setf (slot-value instance (gethash :home-key tdbi)) fk)
		   (setf (slot-value jcc (gethash :foreign-key dbi)) 
			 key)
		   (setf (slot-value jcc (gethash :home-key tdbi)) 
			 fk)
		   (list instance jcc)))
	     (select (sql-expression :attribute (gethash :foreign-key tdbi) :table jc-view-table)
		     :from (sql-expression :table jc-view-table)
		     :where jq)))))))

(defun update-object-joins (objects &key (slots t) (force-p t)
			    class-name (max-len *default-update-objects-max-len*))
  "Updates the remote join slots, that is those slots defined without :retrieval :immediate."
  (when objects
    (unless class-name
      (class-name (class-of (first objects))))
    (let* ((class (find-class class-name))
	   (deferred-joins (generate-retrieval-joins-list class :deferred)))
      (when deferred-joins
	(warn "not yet implemented.")
	))))

  
(defun fault-join-slot-raw (class object slot-def)
  (let* ((dbi (view-class-slot-db-info slot-def))
	 (jc (gethash :join-class dbi)))
    (let ((jq (join-qualifier class object slot-def)))
      (when jq 
        (select jc :where jq :flatp t :result-types nil)))))

(defun fault-join-slot (class object slot-def)
  (let* ((dbi (view-class-slot-db-info slot-def))
	 (ts (gethash :target-slot dbi)))
    (if (and ts (gethash :set dbi))
	(fault-join-target-slot class object slot-def)
	(let ((res (fault-join-slot-raw class object slot-def)))
	  (when res
	    (cond
	      ((and ts (not (gethash :set dbi)))
	       (mapcar (lambda (obj) (slot-value obj ts)) res))
	      ((and (not ts) (not (gethash :set dbi)))
	       (car res))
	      ((and (not ts) (gethash :set dbi))
	       res)))))))

(defun join-qualifier (class object slot-def)
    (declare (ignore class))
    (let* ((dbi (view-class-slot-db-info slot-def))
	   (jc (find-class (gethash :join-class dbi)))
	   ;;(ts (gethash :target-slot dbi))
	   ;;(tsdef (if ts (slotdef-for-slot-with-class ts jc)))
	   (foreign-keys (gethash :foreign-key dbi))
	   (home-keys (gethash :home-key dbi)))
      (when (every #'(lambda (slt)
		       (and (slot-boundp object slt)
                            (not (null (slot-value object slt)))))
		   (if (listp home-keys) home-keys (list home-keys)))
	(let ((jc
               (mapcar #'(lambda (hk fk)
                           (let ((fksd (slotdef-for-slot-with-class fk jc)))
                             (sql-operation '==
                                            (typecase fk
                                              (symbol
                                               (sql-expression
                                                :attribute
                                                (view-class-slot-column fksd)
                                                :table (view-table jc)))
                                              (t fk))
                                            (typecase hk
                                              (symbol
                                               (slot-value object hk))
                                              (t
                                               hk)))))
                       (if (listp home-keys)
                           home-keys
                           (list home-keys))
                       (if (listp foreign-keys)
                           foreign-keys
                           (list foreign-keys)))))
          (when jc
            (if (> (length jc) 1)
                (apply #'sql-and jc)
                jc))))))

;; FIXME: add retrieval immediate for efficiency
;; For example, for (select 'employee-address) in test suite =>
;; select addr.*,ea_join.* FROM addr,ea_join WHERE ea_join.aaddressid=addr.addressid\g

(defun build-objects (vals sclasses immediate-join-classes sels immediate-joins database refresh flatp)
  "Used by find-all to build objects."
  (labels ((build-object (vals vclass jclasses selects immediate-selects)
	     (let* ((class-name (class-name vclass))
		    (db-vals (butlast vals (- (list-length vals)
					      (list-length selects))))
		    (join-vals (subseq vals (list-length selects)))
		    (obj (make-instance class-name :view-database database))
		    (joins (mapcar #'(lambda (c) (when c (make-instance c :view-database database)))
				   jclasses)))
	       ;;(format t "db-vals: ~S, join-values: ~S~%" db-vals join-vals)
	       ;; use refresh keyword here 
	       (setf obj (get-slot-values-from-view obj (mapcar #'car selects) 
						    db-vals))
	       (mapc #'(lambda (jc) (get-slot-values-from-view jc (mapcar #'car immediate-selects) join-vals))
		     joins)
	       (mapc
		#'(lambda (jc) (let ((slot (find (class-name (class-of jc)) (class-slots vclass) 
						 :key #'(lambda (slot) (when (and (eq :join (view-class-slot-db-kind slot))
										  (eq (slot-definition-name slot)
										      (gethash :join-class (view-class-slot-db-info slot))))
									 (slot-definition-name slot))))))
				 (when slot
				   (setf (slot-value obj (slot-definition-name slot)) jc))))
			  
		joins)
	       (when refresh (instance-refreshed obj))
	       obj)))
    (let ((objects (mapcar #'(lambda (sclass jclass sel immediate-join) 
			       (prog1 (build-object vals sclass jclass sel immediate-join)
				 (setf vals (nthcdr (+ (list-length sel) (list-length immediate-join))
						    vals))))
			   sclasses immediate-join-classes sels immediate-joins)))
      (if (and flatp (= (length sclasses) 1))
	  (car objects)
	  objects))))

(defun find-all (view-classes 
		 &rest args
		 &key all set-operation distinct from where group-by having 
		      order-by order-by-descending offset limit refresh
		      flatp result-types inner-join on 
		      (database *default-database*))
  "Called by SELECT to generate object query results when the
  View Classes VIEW-CLASSES are passed as arguments to SELECT."
  (declare (ignore all set-operation group-by having offset limit inner-join on)
           (optimize (debug 3) (speed 1)))
  (labels ((ref-equal (ref1 ref2)
	     (equal (sql ref1)
		    (sql ref2)))
	   (table-sql-expr (table)
	     (sql-expression :table (view-table table)))
	   (tables-equal (table-a table-b)
	     (when (and table-a table-b)
	       (string= (string (slot-value table-a 'name))
			(string (slot-value table-b 'name))))))
    (remf args :from)
    (remf args :where)
    (remf args :flatp)
    (remf args :additional-fields)
    (remf args :result-types)
    (let* ((*db-deserializing* t)
	   (sclasses (mapcar #'find-class view-classes))
	   (immediate-join-slots (mapcar #'(lambda (c) (generate-retrieval-joins-list c :immediate)) sclasses))
	   (immediate-join-classes (mapcar #'(lambda (jcs)
					       (mapcar #'(lambda (slotdef)
							   (find-class (gethash :join-class (view-class-slot-db-info slotdef))))
						       jcs))
					   immediate-join-slots))
	   (immediate-join-sels (mapcar #'generate-immediate-joins-selection-list sclasses))
	   (sels (mapcar #'generate-selection-list sclasses))
	   (fullsels (apply #'append (mapcar #'append sels immediate-join-sels)))
	   (sel-tables (collect-table-refs where))
	   (tables (remove-if #'null
			      (remove-duplicates (append (mapcar #'table-sql-expr sclasses)
							 (mapcar #'(lambda (jcs)
								     (mapcan #'(lambda (jc)
										 (when jc (table-sql-expr jc)))
									     jcs))
								 immediate-join-classes)
							 sel-tables)
						 :test #'tables-equal)))
	   (res nil))
      (dolist (ob (listify order-by))
	(when (and ob (not (member ob (mapcar #'cdr fullsels)
				   :test #'ref-equal)))
	  (setq fullsels 
		  (append fullsels (mapcar #'(lambda (att) (cons nil att))
					   (listify ob))))))
      (dolist (ob (listify order-by-descending))
	(when (and ob (not (member ob (mapcar #'cdr fullsels)
				   :test #'ref-equal)))
	  (setq fullsels 
		(append fullsels (mapcar #'(lambda (att) (cons nil att))
					 (listify ob))))))
      (dolist (ob (listify distinct))
	(when (and (typep ob 'sql-ident) 
		   (not (member ob (mapcar #'cdr fullsels) 
				:test #'ref-equal)))
	  (setq fullsels 
	      (append fullsels (mapcar #'(lambda (att) (cons nil att))
				       (listify ob))))))
      (mapcar #'(lambda (vclass jclasses jslots)
		  (when jclasses
		    (mapcar
		     #'(lambda (jclass jslot)
			 (let ((dbi (view-class-slot-db-info jslot)))
			   (setq where
				 (append
				  (list (sql-operation '==
						      (sql-expression
						       :attribute (gethash :foreign-key dbi)
						       :table (view-table jclass))
						      (sql-expression
						       :attribute (gethash :home-key dbi)
						       :table (view-table vclass))))
				  (when where (listify where))))))
		     jclasses jslots)))
	      sclasses immediate-join-classes immediate-join-slots)
      (setq res 
	    (apply #'select 
		   (append (mapcar #'cdr fullsels)
			   (cons :from 
				 (list (append (when from (listify from)) 
					       (listify tables)))) 
			 (list :result-types result-types)
			 (when where (list :where where))
			 args)))
      (mapcar #'(lambda (r)
		  (build-objects r sclasses immediate-join-classes sels immediate-join-sels database refresh flatp))
	    res))))

(defmethod instance-refreshed ((instance standard-db-object)))

(defun select (&rest select-all-args) 
   "The function SELECT selects data from DATABASE, which has a
default value of *DEFAULT-DATABASE*, given the constraints
specified by the rest of the ARGS. It returns a list of objects
as specified by SELECTIONS. By default, the objects will each be
represented as lists of attribute values. The argument SELECTIONS
consists either of database identifiers, type-modified database
identifiers or literal strings. A type-modifed database
identifier is an expression such as [foo :string] which means
that the values in column foo are returned as Lisp strings.  The
FLATP argument, which has a default value of nil, specifies if
full bracketed results should be returned for each matched
entry. If FLATP is nil, the results are returned as a list of
lists. If FLATP is t, the results are returned as elements of a
list, only if there is only one result per row. The arguments
ALL, SET-OPERATION, DISTINCT, FROM, WHERE, GROUP-BY, HAVING and
ORDER-by have the same function as the equivalent SQL expression.
The SELECT function is common across both the functional and
object-oriented SQL interfaces. If selections refers to View
Classes then the select operation becomes object-oriented. This
means that SELECT returns a list of View Class instances, and
SLOT-VALUE becomes a valid SQL operator for use within the where
clause. In the View Class case, a second equivalent select call
will return the same View Class instance objects. If REFRESH is
true, then existing instances are updated if necessary, and in
this case you might need to extend the hook INSTANCE-REFRESHED.
The default value of REFRESH is nil. SQL expressions used in the
SELECT function are specified using the square bracket syntax,
once this syntax has been enabled using
ENABLE-SQL-READER-SYNTAX."

  (flet ((select-objects (target-args)
           (and target-args
                (every #'(lambda (arg)
                           (and (symbolp arg)
                                (find-class arg nil)))
                       target-args))))
    (multiple-value-bind (target-args qualifier-args)
        (query-get-selections select-all-args)
      (if (select-objects target-args)
	  (apply #'find-all target-args qualifier-args)
	(let* ((expr (apply #'make-query select-all-args))
	       (specified-types
		(mapcar #'(lambda (attrib)
			    (if (typep attrib 'sql-ident-attribute)
				(let ((type (slot-value attrib 'type)))
				  (if type
				      type
				    t))
			      t))
			(slot-value expr 'selections))))
	  (destructuring-bind (&key (flatp nil)
				    (result-types :auto)
				    (field-names t) 
				    (database *default-database*)
			       &allow-other-keys)
	      qualifier-args
	    (query expr :flatp flatp 
		   :result-types 
		   ;; specifying a type for an attribute overrides result-types
		   (if (some #'(lambda (x) (not (eq t x))) specified-types) 
		       specified-types
		     result-types)
		   :field-names field-names
		   :database database)))))))

