(export #t)

(import
  :clan/poo/poo :clan/poo/mop :clan/poo/type :clan/poo/number)

(define-type ByteString Bytes)
(define-type Script ByteString)
(define-type Int Integer)
(def Set List)