(export #t)

(import
  :std/getopt :std/format :std/iter :std/misc/hash :std/srfi/13 :std/sugar
  :clan/base :clan/config :clan/files :clan/hash :clan/json :clan/multicall :clan/syntax :clan/crypto/secp256k1
  :clan/poo/brace :clan/poo/cli :clan/poo/io :clan/poo/mop :clan/poo/object :clan/poo/type
  :mukn/ethereum/cli :mukn/ethereum/hex :mukn/ethereum/ethereum :mukn/ethereum/known-addresses :mukn/ethereum/network-config
  :mukn/ethereum/json-rpc)

;; TODO:
;; - always populate contacts as well as identity and/or check consistency between nicknames of the two
;; - store only the secret-key, not address and public-key
;; - store they key type (ethereum, bitcoin, some HD wallet, etc.) -- BIP32 path?
;; - store some version schema identifier in the file or its name, and
;;   automatically (or at least manually) migrate from one version to the other.

(def (secret-key-ring)
  (xdg-config-home "glow" "secret-key-ring.json"))

(def (load-identities from: (from (secret-key-ring)))
  (with-catch
   (lambda (e)
     (displayln (error-message e))
     (error "Failed to read and parse the secret key ring file" from))
   (lambda ()
     (if (file-exists? from)
      (hash-key-value-map
        (lambda (nickname keypair-json)
          (def keypair (import-keypair/json keypair-json))
          (register-keypair nickname keypair)
          (cons nickname keypair))
        (read-file-json from))
      (make-hash-table)))))

(def (store-identities identities from: (from (secret-key-ring)))
  (def identities-json
    (hash-key-value-map
      (lambda (nickname keypair)
        (cons nickname (export-keypair/json keypair)))
      identities))
  (clobber-file from (string<-json identities-json) salt?: #t))

(def (call-with-identities f from: (from #f))
  (set! from (or from (secret-key-ring)))
  (def identities
    (if (file-exists? from)
      (load-identities from: from)
      (make-hash-table)))
  (f identities)
  (store-identities identities from: from))

(def options/identities
  (make-options
    [(option 'identities "-I" "--identities" default: (secret-key-ring)
             help: "file to load and store identities")] []))

(define-entry-point (add-identity
                     identities: (identities #f)
                     nickname: (nickname #f)
                     secret-key: (secret-key #f))
  (help: "Add identity"
   getopt: (make-options
            ;; TODO: Consolidate with contact options
            [(option 'nickname "-N" "--nickname"
                     help: "nickname of identity")
             (option 'secret-key "-S" "--secret-key"
                     help: "secret key of identity")]
            []
            [options/test options/identities]))
  (unless secret-key (error "missing secret-key"))
  (unless nickname (error "missing nickname"))
  (def new-keypair (keypair<-secret-key (<-string Bytes32 secret-key)))
  (call-with-identities
   from: identities
   (cut hash-put! <> (string-downcase nickname) new-keypair))
  (displayln "Added identity: " nickname " [ " (string<- Address (keypair-address new-keypair)) " ]"))

(define-entry-point (generate-identity
                     identities: (identities #f)
                     nickname: (nickname #f)
                     prefix: (prefix #f))
  (help: "Generate identity"
   getopt: (make-options
            [(option 'nickname "-N" "--nickname"
                     help: "nickname of identity")
             (option 'prefix "-P" "--prefix" default: #f
                     help: "desired hex prefix of generated address")]
            []
            [options/test options/identities]))
  (unless nickname (error "missing nickname option"))
  (def scoring (if prefix (scoring<-prefix prefix) trivial-scoring))
  (def keypair (generate-keypair scoring: scoring))
  (call-with-identities
   from: identities
   (cut hash-put! <> (string-downcase nickname) keypair))
  (displayln "Generated identity: " nickname " [ " (string<- Address (keypair-address keypair)) " ]"))

(define-entry-point (remove-identity
                     identities: (identities #f)
                     nickname: (nickname #f))
  (help: "Remove identity"
   getopt: (make-options
            [(option 'nickname "-N" "--nickname")] [] [options/identities]))
  (unless nickname (error "missing nickname option"))
  (call-with-identities (cut hash-remove! <> (string-downcase nickname)) from: identities)
  (displayln "Removed identity " nickname))

(define-entry-point (list-identities identities: (identities #f))
  (help: "List identities" getopt: options/identities)
  (def identities (load-identities from: identities))
  (for-each
    (match <>
      ([nickname . keypair]
        (displayln nickname " [ " (string<- Address (keypair-address keypair)) " ]")))
    (hash->list/sort identities string<?)))

(define-entry-point (faucet from: (from #f) to: (to #f) identities: (identities #f))
  (help: "Fund some accounts from the network faucet"
   getopt: (make-options []
                         [(cut hash-restrict-keys! <> '(from to value))]
                         [options/identities options/to]))
  (def-slots (network faucets name nativeCurrency) (ethereum-config))
  (load-identities from: identities) ;; Only needed for side-effect of registering keypairs.
  (cond
   ((member name '("Private Ethereum Testnet" "Cardano EVM Devnet"))
    (let ()
      (unless to (error "Missing recipient. Please use option --to"))
      (set! to (parse-address to))
      ;; We import testing *after* the above, so we have *our* t/croesus,
      ;; but the user may have their own alice.
      (import-testing-module)
      (def value-in-ether 5)
      (def value (wei<-ether value-in-ether))
      (def token-symbol (.@ nativeCurrency symbol))
      (def from (address<-nickname "t/croesus"))
      (printf "\nSending ~a ~a from faucet ~a\n to ~a on network ~a:\n\n"
              value-in-ether token-symbol (0x<-address from) (0x<-address to) network)
      (printf "\nInitial balance: ~a ~a\n\n" (decimal-string-ether<-wei (eth_getBalance to)) token-symbol)
      (cli-send-tx {from to value} confirmations: 0)
      (printf "\nFinal balance: ~a ~a\n\n" (decimal-string-ether<-wei (eth_getBalance to)) token-symbol)))
   ((not (null? faucets))
    (printf "\nVisit the following URL to get ethers on network ~a:\n\n\t~a\n\n"
            (car faucets) network))
   (else
    (printf "\nThere is no faucet for network ~a - Go earn tokens the hard way.\n\n" network))))