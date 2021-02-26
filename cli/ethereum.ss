(export #t)

(import
  :gerbil/expander
  :std/format :std/getopt :std/iter :std/misc/hash
  :std/sort :std/srfi/13 :std/sugar
  :clan/cli :clan/decimal :clan/exit :clan/hash :clan/list :clan/multicall :clan/path-config
  :clan/poo/object :clan/poo/brace :clan/poo/cli :clan/poo/debug
  :clan/persist/db
  :mukn/ethereum/network-config :mukn/ethereum/types :mukn/ethereum/ethereum :mukn/ethereum/known-addresses :mukn/ethereum/json-rpc :mukn/ethereum/cli
  ./contacts ./identities)

(define-entry-point (transfer from: (from #f) to: (to #f) value: (value #f)
                              contacts: (contacts-file #f) identities: (identities-file #f))
  (help: "Send tokens from one account to the other"
   getopt: (make-options [] [(cut hash-restrict-keys! <> '(from to value))] options/send))
  (load-identities from: identities-file)
  (load-contacts contacts-file)
  (def currency (.@ (ethereum-config) nativeCurrency))
  (def token-symbol (.@ currency symbol))
  (def network (.@ (ethereum-config) network))
  (set! from (parse-address (or from (error "Missing sender. Please use option --from"))))
  (set! to (parse-address (or to (error "Missing recipient. Please use option --to"))))
  (set! value (parse-currency-value
               (or value (error "Missing value. Please use option --value")) currency))
  (printf "\nSending ~a ~a from ~a to ~a on network ~a:\n"
          value token-symbol (0x<-address from) (0x<-address to) network)
  (printf "\nBalance before\n for ~a: ~a ~a,\n for ~a: ~a ~a\n"
          ;; TODO: use a function to correctly print with the right number of decimals,
          ;; with the correct token-symbol, depending on the current network and/or asset
          (0x<-address from) (decimal-string-ether<-wei (eth_getBalance from)) token-symbol
          (0x<-address to) (decimal-string-ether<-wei (eth_getBalance to)) token-symbol)
  (import-testing-module) ;; for debug-send-tx
  (cli-send-tx {from to value} confirmations: 0)
  (printf "\nBalance after\n for ~a: ~a ~a,\n for ~a: ~a ~a\n"
          ;; TODO: use a function to correctly print with the right number of decimals
          (0x<-address from) (decimal-string-ether<-wei (eth_getBalance from)) token-symbol
          (0x<-address to) (decimal-string-ether<-wei (eth_getBalance to)) token-symbol))

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