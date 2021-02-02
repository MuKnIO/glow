(export #t)

(import
  :gerbil/gambit/bits :gerbil/gambit/bytes :gerbil/gambit/threads
  :std/iter :std/misc/hash :std/sugar :std/misc/number :std/misc/list :std/sort :std/srfi/1
  :clan/base :clan/exception :clan/io :clan/json :clan/number :clan/path-config :clan/ports :clan/syntax
  :clan/poo/poo :clan/poo/io :clan/poo/debug :clan/debug :clan/crypto/random
  :clan/persist/content-addressing
  :mukn/ethereum/hex :mukn/ethereum/ethereum :mukn/ethereum/network-config :mukn/ethereum/json-rpc
  :mukn/ethereum/transaction :mukn/ethereum/tx-tracker :mukn/ethereum/watch :mukn/ethereum/assets
  :mukn/ethereum/contract-runtime :mukn/ethereum/contract-config :mukn/ethereum/assembly :mukn/ethereum/types
  ./program ./block-ctx ./consensus-code-generator
  ../compiler/method-resolve/method-resolve
  ../compiler/project/runtime-2)

;; NB: Whichever function exports data end-users / imports from them should make sure to put in a Json array (Scheme list) prepend by the name of the type. And/or we may have a {"": "InteractionAgreement" ...} field with this asciibetically always-first name. Maybe such function belongs to gerbil-poo, too.

(define-type Tokens (MonomorphicPoo Nat))

(define-type AgreementOptions
  (Record
   blockchain: [String] ;; e.g. "Cardano KEVM Testnet", as per ethereum_networks.json
   escrowAmount: [(Maybe Tokens) default: (void)] ;; not meaningful for all contracts
   timeoutInBlocks: [Nat]
   maxInitialBlock: [Nat]))

(define-type InteractionAgreement
  (.+
   (Record
    glow-version: [String] ;; e.g. "Glow v0.0-560-gda782c9 on Gerbil-ethereum v0.0-83-g6568bc6" ;; TODO: have a function to compute that from versioning.ss
    interaction: [String] ;; e.g. "mukn/glow/examples/buy_sig#payForSignature", fully qualified Gerbil symbol
    participants: [(MonomorphicPoo Address)] ;; e.g. {Buyer: alice Seller: bob}
    parameters: [Json] ;; This Json object to be decoded according to a type descriptor from the interaction (dependent types yay!)
    reference: [(MonomorphicPoo Json)] ;; Arbitrary reference objects from each participant, with some conventional size limits on the Json string.
    options: [AgreementOptions] ;; See above
    code-digest: [Digest]))) ;; Make it the digest of Glow source code (in the future, including all Glow libraries transitively used)

(define-type AgreementHandshake
  (Record
   agreement: [InteractionAgreement]
   contract-config: [ContractConfig]
   published-data: [Bytes])) ;; Variables published by the first active participant inside the first code block.
;; timer-start = (.@ agreement-handshake agreement options maxInitialBlock)

(define-type IOContext
  (instance Class
    slots: (.o send-handshake: (.o type: (Fun Unit <- AgreementHandshake))
               receive-handshake: (.o type: (Fun AgreementHandshake <-)))))

(def (delete-agreement-handshake)
  (def file (special-file:handshake))
  (displayln "Deleting any old agreement handshake file " file " ...")
  (ignore-errors (delete-file file)))

(def (special-file:handshake) (run-path "agreement-handshake.json"))

;; TODO: make an alternate version of io-context that
;;       displays at the terminal for the user to copy/paste and send to
;;       other participants through an outside channel
(.def io-context:special-file
  setup: delete-agreement-handshake
  teardown: delete-agreement-handshake
  send-handshake:
  (λ (handshake)
    (def file (special-file:handshake))
    (displayln "Writing agreement handshake to file " file " ...")
    (write-file-json (special-file:handshake) (json<- AgreementHandshake handshake)))
  receive-handshake:
  (λ ()
    (def file (special-file:handshake))
    (displayln "Waiting for agreement handshake file " file " ...")
    (until (file-exists? file)
      (displayln "still waiting for file " file " ...")
      (thread-sleep! 1))
    (<-json AgreementHandshake (read-file-json file))))

;; PARTICIPANT RUNTIME

;; TODO: derive the contract from the agreement,
;;       check that the code-digest in the agreement matches
(defclass Runtime
  (role ;; : Symbol
   agreement ;; : InteractionAgreement
   contract-config ;; : ContractConfig
   status ;; (Enum running completed aborted stopped)
   processed-events ;; : (List LogObjects) ;; ???
   unprocessed-events ;; : (List LogObjects) ;; ???
   current-code-block-label ;; : Symbol
   current-label ;; : Symbol
   environment ;; : (Table (Or DependentPair Any) <- Symbol) ;; TODO: have it always typed???
   block-ctx ;; : BlockCtx ;; byte buffer?
   timer-start ;; : Block
   io-context ; : IOContext
   program ;; : Program ;; from program.ss
   consensus-code-generator) ;; ConsensusCodeGenerator
  constructor: :init!
  transparent: #t)

(defmethod {:init! Runtime}
  (λ (self
      role: role
      agreement: agreement
      io-context: (io-context io-context:special-file)
      program: program)
    (set! (@ self role) role)
    (set! (@ self agreement) agreement)
    ;; TODO: extract initial code block label from contract compiler output
    (set! (@ self current-code-block-label) (@ program initial-code-block-label))
    (set! (@ self current-label) (@ program initial-label))

    (set! (@ self contract-config) #f)
    (set! (@ self status) 'running) ;; (Enum running stopped completed aborted)
    (set! (@ self processed-events) '())
    (set! (@ self unprocessed-events) '())
    (set! (@ self environment) (make-hash-table))
    (set! (@ self block-ctx) #f)
    (set! (@ self io-context) io-context)
    (set! (@ self program) program)
    (set! (@ self consensus-code-generator)
      (.call ConsensusCodeGenerator .make program (.@ agreement options timeoutInBlocks)))
    (.call ConsensusCodeGenerator .generate (@ self consensus-code-generator))
    {initialize-environment self}))

;; <- Runtime
(defmethod {execute Runtime}
  (λ (self)
    (with-logged-exceptions ()
      (def ccbl (@ self current-code-block-label))
      (displayln "executing code block: " ccbl)

      (if {is-active-participant? self}
        {publish self}
        {receive self})
      (set! (@ self block-ctx) #f)

      (match (code-block-exit {get-current-code-block self})
        (#f
          (void)) ; contract finished
        (exit
          (set! (@ self current-code-block-label) exit)
          {execute self})))))

;; Bool <- Runtime
(defmethod {is-active-participant? Runtime}
  (λ (self)
    (def current-code-block {get-current-code-block self})
    (equal? (@ self role) (code-block-participant current-code-block))))

;; TODO: everything about this function, from the timer-start and/or wherever we left off
;; to timeout or (indefinite future if no timeout???)
;; : LogObject <- Runtime Address Block
(defmethod {watch Runtime}
  ;; TODO: consult unprocessed log objects first, if none is available, then use getLogs
  ;; TODO: be able to split getLogs into smaller requests if it a bigger request times out.
  ;; TODO: (optional) push all the previously processed log objects to the processed list after processing
  (λ (self contract-address from-block)
    (let/cc return
      (def callback (λ (log) (return log))) ;; TODO: handle multiple log entries!!!
      (def to-block (+ from-block (.@ (@ self agreement) options timeoutInBlocks)))
      (watch-contract callback contract-address from-block to-block))))

(def (run-passive-code-block/contract self role contract-config)
  (displayln role ": Watching for new transaction ...")
  ;; TODO: `from` should be calculated using the deadline and not necessarily the previous tx,
  ;; since it may or not be setting the deadline
  (display-poo-ln role ": contract-config=" ContractConfig contract-config)
  (def from
    (if (@ self timer-start)
      (+ (@ self timer-start) 1)
      (.@ contract-config creation-block)))
  (displayln role ": watching from block " from)
  (def new-log-object {watch self (.@ contract-config contract-address) from})
  ;; TODO: handle the case when there is no log objects
  (display-poo-ln role ": New TX: " (Maybe LogObject) new-log-object)
  (def log-data (.@ new-log-object data))
  (set! (@ self timer-start) (.@ new-log-object blockNumber))
  ;; TODO: process the data in the same method?
  (set! (@ self block-ctx) (.call PassiveBlockCtx .make log-data))
  (interpret-current-code-block self))

(def (interpret-current-code-block self)
  (let (code-block {get-current-code-block self})
    (for ((statement (code-block-statements code-block)))
      {interpret-participant-statement self statement})))

(def (run-passive-code-block/handshake self role)
  (nest
   (begin (displayln role ": Reading contract handshake ..."))
   (let (agreement-handshake {read-handshake self}))
   (begin
     (displayln role ": Verifying contract config ...")
     (force-current-outputs))
   (with-slots (agreement contract-config published-data) agreement-handshake)
   (let (block-ctx (@ self block-ctx)))
   (begin
     (set! (@ self block-ctx) (.call PassiveBlockCtx .make published-data))
     ;; TODO: Execute contract until first change participant.
     ;; Check that the agreement part matches
     (unless (equal? (json<- InteractionAgreement (@ self agreement))
                     (json<- InteractionAgreement agreement))
       (DDT agreements-mismatch:
            InteractionAgreement (@ self agreement)
            InteractionAgreement agreement)
       (error "agreements don't match" (@ self agreement) agreement))
     (set! (@ self timer-start) (.@ agreement options maxInitialBlock))
     (interpret-current-code-block self))
   (let (create-pretx {prepare-create-contract-transaction self})
     (verify-contract-config contract-config create-pretx)
     (set! (@ self contract-config) contract-config))))

;; TODO: rename to RunPassiveCodeBlock or something
;; <- Runtime
(defmethod {receive Runtime}
  (λ (self)
    (def role (@ self role))
    (def contract-config (@ self contract-config))
    (when (eq? (@ self status) 'running)
      (if contract-config
        (run-passive-code-block/contract self role contract-config)
        (run-passive-code-block/handshake self role)))))

;; : AgreementHandshake <- Runtime
(defmethod {read-handshake Runtime}
  (λ (self)
    (def io-context (@ self io-context))
    (.call io-context receive-handshake)))

;; <- Runtime
(defmethod {publish Runtime}
  (λ (self)
    (def role (@ self role))
    (def contract-config (@ self contract-config))
    (set! (@ self block-ctx) (.call ActiveBlockCtx .make))
    (when contract-config
      {publish-frame-data self})
    (interpret-current-code-block self)
    (when (eq? (@ self status) 'running)
      (if (not contract-config)
        (let ()
          (displayln role ": deploying contract ...")
          {deploy-contract self}
          (def contract-config (@ self contract-config))
          (def agreement (@ self agreement))
          (def published-data (get-output-u8vector (.@ (@ self block-ctx) outbox)))
          (def handshake (.new AgreementHandshake agreement contract-config published-data))
          (display-poo-ln role ": Handshake: " AgreementHandshake handshake)
          {send-contract-handshake self handshake})
        (let ()
          ;; TODO: Verify asset transfers using previous transaction and balances
          ;; recorded in Message's asset-transfer table during interpretation. Probably
          ;; requires getting TransactionInfo using the TransactionReceipt.
          (displayln role ": publishing message ...")
          (def contract-address (.@ contract-config contract-address))
          (def message-pretx {prepare-call-function-transaction self contract-address})
          (def new-tx-receipt (post-transaction message-pretx))
          (display-poo-ln role ": Tx Receipt: " TransactionReceipt new-tx-receipt)
          (set! (@ self timer-start) (.@ new-tx-receipt blockNumber)))))))

;; Sexp <- State
(def (sexp<-state state) (map (match <> ([t . v] (sexp<- t v))) state))

;; TODO: include type output, too, looked up in type table.
;; <- Runtime Symbol Value
(defmethod {add-to-environment Runtime}
  (λ (self name value)
    (hash-put! (@ self environment) name value)))

;; PreTransaction <- Runtime Block
(defmethod {prepare-create-contract-transaction Runtime}
  (λ (self)
    (def sender-address {get-active-participant self})
    (def code-block {get-current-code-block self})
    (def next (code-block-exit code-block))
    (def participant (code-block-participant code-block))
    (def initial-state
      {create-frame-variables
        self
        (.@ (@ self agreement) options maxInitialBlock)
        next
        participant})
    (def initial-state-digest
      (digest-product-f initial-state))
    (def contract-bytes
      (stateful-contract-init initial-state-digest (.@ (@ self consensus-code-generator) bytes)))
    (create-contract sender-address contract-bytes
      value: (.@ (@ self block-ctx) deposits))))

;; PreTransaction <- Runtime Block
(defmethod {deploy-contract Runtime}
  (λ (self)
    (def role (@ self role))
    (def timer-start (.@ (@ self agreement) options maxInitialBlock))
    (def pretx {prepare-create-contract-transaction self})
    (display-poo-ln role ": Deploying contract... "
                    "timer-start: " timer-start)
    (def receipt (post-transaction pretx))
    (def contract-config (contract-config<-creation-receipt receipt))
    (display-poo-ln role ": Contract config: " ContractConfig contract-config)
    (verify-contract-config contract-config pretx)
    (set! (@ self contract-config) contract-config)))

(defmethod {send-contract-handshake Runtime}
  (λ (self handshake)
    (def io-context (@ self io-context))
    (.call io-context send-handshake handshake)))

(defmethod {publish-frame-data Runtime}
  (λ (self)
    (def out (.@ (@ self block-ctx) outbox))
    (def frame-variables
      {create-frame-variables
        self
        (@ self timer-start)
        (@ self current-code-block-label)
        (@ self role)})
    (def frame-variable-bytes (marshal-product-f frame-variables))
    (def frame-length (bytes-length frame-variable-bytes))
    (marshal UInt16 frame-length out)
    (marshal-product-to frame-variables out)))

;; See gerbil-ethereum/contract-runtime.ss for spec.
;; PreTransaction <- Runtime Message.Outbox Block Address
(defmethod {prepare-call-function-transaction Runtime}
  (λ (self contract-address)
    (def out (.@ (@ self block-ctx) outbox))
    (marshal UInt8 1 out)
    (def message-bytes (get-output-u8vector out))
    (def sender-address {get-active-participant self})
    (call-function sender-address contract-address message-bytes
      ;; default gas value should be (void), i.e. ask for an automatic estimate,
      ;; unless we want to force the TX to happen, e.g. so we can see the failure in Remix
      gas: 1000000 ;; XXX ;;<=== DO NOT COMMIT THIS LINE UNCOMMENTED
      value: (.@ (@ self block-ctx) deposits))))

;; CodeBlock <- Runtime
(defmethod {get-current-code-block Runtime}
  (λ (self)
    (def participant-interaction
      (get-interaction (@ self program) (@ self role)))
    (hash-get participant-interaction (@ self current-code-block-label))))

;; TODO: map alpha-converted names to names in original source when displaying to user
;;       using the alpha-back-table
;; <- Runtime
(defmethod {initialize-environment Runtime}
  (λ (self)
    (def agreement (@ self agreement))
    (def participants (.@ agreement participants))
    (for (participant-name (.all-slots-sorted participants))
      {add-to-environment self participant-name (.ref participants participant-name)})
    (def parameters (.@ agreement parameters))
    (for ((values parameter-name-key parameter-json-value) parameters)
      (def parameter-name (symbolify parameter-name-key))
      (def parameter-type (lookup-type (@ self program) parameter-name))
      (def parameter-value (<-json parameter-type parameter-json-value))
      {add-to-environment self parameter-name parameter-value})))

;; TODO: make sure everything always has a type ???
;; Any <- Runtime
(defmethod {reduce-expression Runtime}
  (λ (self expression)
    (cond
     ((symbol? expression)
      (match (hash-ref/default
              (@ self environment) expression
              (cut error "variable missing from execution environment" expression))
        ([type . value]
         value)
        (value
          value)))
     ((boolean? expression) expression)
     ((string? expression) (string->bytes expression))
     ((bytes? expression) expression)
     ((integer? expression) expression)
     ;; TODO: reduce other trivial expressions
     (else
      expression))))

;; Symbol <- Runtime
(defmethod {get-active-participant Runtime}
  (λ (self)
    (def environment (@ self environment))
    (hash-get environment (@ self role))))

;; Bytes <- (List DependentPair)
(def (marshal-product-f fields)
  (call-with-output-u8vector (λ (out)
    (marshal-product-to fields out))))
;; <- (List DependentPair) BytesOutputPort
(def (marshal-product-to fields port)
  (for ((p fields))
    (with (([t . v] p)) (marshal t v port))))

;; : Digest <- (List DependentPair)
(def (digest-product-f fields)
  (digest<-bytes (marshal-product-f fields)))

;; : <- Runtime ProjectStatement
(defmethod {interpret-participant-statement Runtime}
  (λ (self statement)
    (displayln statement)
    (match statement

      (['set-participant new-participant]
        ;; Since the contract has already been separated into transaction boundaries,
        ;; the participant doesn't need to do anything here, since the active participant
        ;; is already known.
       (void))

      (['add-to-deposit amount-variable]
       (let
         ((this-participant {get-active-participant self})
          (amount {reduce-expression self amount-variable}))
         (.call BlockCtx .add-to-deposit (@ self block-ctx) this-participant amount)))

      (['expect-deposited amount-variable]
       (let
         ((this-participant {get-active-participant self})
          (amount {reduce-expression self amount-variable}))
         (.call BlockCtx .add-to-deposit (@ self block-ctx) this-participant amount)))

      (['participant:withdraw address-variable price-variable]
       (let ((address {reduce-expression self address-variable})
             (price {reduce-expression self price-variable}))
         (.call BlockCtx .add-to-withdraw (@ self block-ctx) address price)))

      (['add-to-publish ['quote publish-name] variable-name]
       (let ((publish-value {reduce-expression self variable-name})
             (publish-type (lookup-type (@ self program) variable-name)))
         (.call ActiveBlockCtx .add-to-published (@ self block-ctx)
                publish-name publish-type publish-value)))

      (['def variable-name expression]
       (let
         ((variable-value {interpret-participant-expression self expression}))
         {add-to-environment self variable-name variable-value}))

      (['require! variable-name]
       (match {reduce-expression self variable-name}
         (#t (void))
          ;; TODO: include debugging information when something fails!
         (#f
          (error "Assertion failed"))
         (n
          (error "Assertion failed, " variable-name " is not a Boolean."))))

      (['return _]
       (void))

      (['@label name]
       (set! (@ self current-label) name))

      (['switch variable-name cases ...]
       (let*
         ((variable-value {reduce-expression self variable-name})
          (matching-case (find (λ (case) (equal? {reduce-expression self (car case)} variable-value)) cases)))
        (for (case-statement (cdr matching-case))
          {interpret-participant-statement self case-statement}))))))

(defmethod {interpret-participant-expression Runtime}
  (λ (self expression)
    (match expression
      (['expect-published ['quote publish-name]]
       (let (publish-type (lookup-type (@ self program) publish-name))
         (.call PassiveBlockCtx .expect-published (@ self block-ctx) publish-name publish-type)))
      (['@app 'isValidSignature address-variable digest-variable signature-variable]
       (let
         ((address {reduce-expression self address-variable})
          (digest {reduce-expression self digest-variable})
          (signature {reduce-expression self signature-variable}))
         (isValidSignature address digest signature)))
      (['@app '< a b]
       (let
         ((av {reduce-expression self a})
          (bv {reduce-expression self b}))
         (< av bv)))
      (['@app '+ a b]
       (let
         ((av {reduce-expression self a})
          (bv {reduce-expression self b}))
         (+ av bv)))
      (['@app '- a b]
       (let
         ((av {reduce-expression self a})
          (bv {reduce-expression self b}))
         (- av bv)))
      (['@app '* a b]
       (let
         ((av {reduce-expression self a})
          (bv {reduce-expression self b}))
         (* av bv)))
      (['@app 'bitwise-xor a b]
       (let
         ((av {reduce-expression self a})
          (bv {reduce-expression self b}))
         (bitwise-xor av bv)))
      (['@app 'bitwise-and a b]
       (let
         ((av {reduce-expression self a})
          (bv {reduce-expression self b}))
         (bitwise-and av bv)))
      (['@app 'mod a b]
        (let
         ((av {reduce-expression self a})
          (bv {reduce-expression self b}))
         (modulo av bv)))
      (['@app 'randomUInt256]
       (randomUInt256))
      (['@app name . args]
        (error "Unknown @app expression: " name " " args))
      (['@tuple . es]
       (list->vector
        (for/collect ((e es))
          {reduce-expression self e})))
      (['digest . es]
       (digest
        (for/collect ((e es))
          (cons (lookup-type (@ self program) e)
                {reduce-expression self e}))))
      (['sign digest-variable]
       (let ((this-participant {get-active-participant self})
             (digest {reduce-expression self digest-variable}))
         (make-message-signature (secret-key<-address this-participant) digest)))
      (['input 'Nat tag]
       (let ((tagv {reduce-expression self tag}))
         (input UInt256 tagv)))
      (['== a b]
        (let ((av {reduce-expression self a})
              (bv {reduce-expression self b}))
          (equal? av bv)))
      (else
        {reduce-expression self expression}))))

;; : Frame <- Runtime Block (Table Offset <- Symbol) Symbol
(defmethod {create-frame-variables Runtime}
  (λ (self timer-start code-block-label code-block-participant)
    (def consensus-code-generator (@ self consensus-code-generator))
    (def checkpoint-location
      (hash-get (.@ consensus-code-generator labels) (make-checkpoint-label (@ self program) code-block-label)))
    (def active-participant-offset
      (lookup-variable-offset consensus-code-generator code-block-label code-block-participant))
    (def live-variables (lookup-live-variables (@ self program) code-block-label))
    ;; TODO: ensure keys are sorted in both hash-values
    [[UInt16 . checkpoint-location]
     [Block . timer-start]
     ;; [UInt16 . active-participant-offset]
     ;; TODO: designate participant addresses as global variables that are stored outside of frames
     (map
       (λ (variable-name)
         (def variable-type (lookup-type (@ self program) variable-name))
         (def variable-value (hash-get (@ self environment) variable-name))
         [variable-type . variable-value])
       (sort live-variables symbol<?))...]))

;; Block <- Frame
(def (timer-start<-frame-variables frame-variables)
  (cdadr frame-variables))

;; TODO: use [t . v] everywhere instead of [v t] ? and unify with sexp<-state in participant-runtime
;; Sexp <- Frame
(def (sexp<-frame-variables frame-variables)
  `(list ,@(map (match <> ([v t] `(list ,(sexp<- t v) ,(sexp<- Type t)))) frame-variables)))