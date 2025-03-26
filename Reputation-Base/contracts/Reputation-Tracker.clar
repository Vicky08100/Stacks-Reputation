;; Reputation Management Protocol Smart Contract

;; Error Constants
(define-constant ERR-UNAUTHORIZED-ACCESS (err u100))
(define-constant ERR-GOVERNANCE-DISABLED (err u101))
(define-constant ERR-DUPLICATE-PROPOSAL (err u102))
(define-constant ERR-INVALID-PARAMETERS (err u200))
(define-constant ERR-OUT-OF-BOUNDS (err u201))
(define-constant ERR-INSUFFICIENT-THRESHOLD (err u202))
(define-constant ERR-PARTICIPANT-NOT-FOUND (err u300))
(define-constant ERR-PARTICIPANT-ALREADY-EXISTS (err u301))
(define-constant ERR-INVALID-PARTICIPANT-STATE (err u302))
(define-constant ERR-INSUFFICIENT-ECONOMIC-RESOURCES (err u400))
(define-constant ERR-ECONOMIC-POLICY-VIOLATION (err u401))
(define-constant ERR-INVALID-CONTEXT-LENGTH (err u500))

;; Protocol Constants
;; Reputation Management Bounds
(define-constant MIN-REPUTATION-SCORE u0)
(define-constant MAX-REPUTATION-SCORE u100)

;; Economic Parameters
(define-constant MINIMUM-STAKE-REQUIREMENT u1000)
(define-constant STAKE-MULTIPLIER u2)
(define-constant PENALTY-PERCENTAGE u10)

;; Temporal Constants
(define-constant BLOCK-EPOCH-LENGTH u144)  ;; Approximately 1 day in blocks
(define-constant REPUTATION-DECAY-INTERVAL u10000)
(define-constant REPUTATION-DECAY-RATE u5)

;; Governance Parameters
(define-constant GOVERNANCE-PROPOSAL-APPROVAL-THRESHOLD u75)
(define-constant GOVERNANCE-VOTING-PERIOD u1008)  ;; ~1 week in blocks

;; Protocol State Variables
;; Administrative Configuration
(define-data-var protocol-governance-admin principal tx-sender)
(define-data-var is-governance-enabled bool true)
(define-data-var protocol-configuration
    {
        minimum-reputation-threshold: uint,
        maximum-reputation-threshold: uint,
        minimum-stake-amount: uint,
        epoch-block-length: uint
    }
    {
        minimum-reputation-threshold: MIN-REPUTATION-SCORE,
        maximum-reputation-threshold: MAX-REPUTATION-SCORE,
        minimum-stake-amount: MINIMUM-STAKE-REQUIREMENT,
        epoch-block-length: BLOCK-EPOCH-LENGTH
    }
)

;; Protocol Metrics Tracking
(define-data-var protocol-metrics
    {
        total-participants: uint,
        total-staked-value: uint,
        total-reputation-evaluations: uint,
        current-protocol-epoch: uint
    }
    {
        total-participants: u0,
        total-staked-value: u0,
        total-reputation-evaluations: u0,
        current-protocol-epoch: u0
    }
)

;; Data Maps
;; Participant Registration and Tracking
(define-map participant-directory
    principal
    {
        reputation-level: uint,
        last-activity-epoch: uint,
        total-evaluations-received: uint,
        stake-balance: uint,
        participant-status: (string-ascii 20)
    }
)

;; Reputation Evaluation History
(define-map reputation-evaluation-log
    { evaluated-participant: principal, evaluation-epoch: uint }
    {
        base-reputation-score: uint,
        weighted-reputation-score: uint,
        evaluator-principal: principal,
        evaluation-timestamp: uint,
        evaluation-context: (optional (string-utf8 100))
    }
)

;; Evaluator Qualification Management
(define-map evaluator-authorization
    principal
    {
        is-authorized: bool,
        total-evaluations-conducted: uint,
        evaluator-accuracy-score: uint,
        most-recent-evaluation-epoch: uint
    }
)

;; Governance Proposal Tracking
(define-map governance-proposal-registry
    uint
    {
        proposal-creator: principal,
        proposal-description: (string-utf8 500),
        proposal-start-block: uint,
        proposal-end-block: uint,
        proposal-status: (string-ascii 10),
        supporting-votes: uint,
        opposing-votes: uint,
        proposal-execution-payload: (optional (buff 1024))
    }
)

;; Private Validation Functions
(define-private (is-within-reputation-bounds (reputation-score uint))
    (let
        (
            (protocol-params (var-get protocol-configuration))
        )
        (and 
            (>= reputation-score (get minimum-reputation-threshold protocol-params))
            (<= reputation-score (get maximum-reputation-threshold protocol-params))
        )
    )
)

(define-private (validate-protocol-configuration 
    (new-protocol-params {
        minimum-reputation-threshold: uint,
        maximum-reputation-threshold: uint,
        minimum-stake-amount: uint,
        epoch-block-length: uint
    }))
    (if (and 
        (< (get minimum-reputation-threshold new-protocol-params) 
           (get maximum-reputation-threshold new-protocol-params))
        (>= (get minimum-stake-amount new-protocol-params) MINIMUM-STAKE-REQUIREMENT)
        (and 
            (>= (get epoch-block-length new-protocol-params) u1) 
            (<= (get epoch-block-length new-protocol-params) u10000))
    )
    (ok new-protocol-params)
    ERR-INVALID-PARAMETERS)
)

(define-private (validate-evaluation-context (context (optional (string-utf8 100))))
    (match context
        ctx (if (<= (len ctx) u100) (ok context) ERR-INVALID-CONTEXT-LENGTH)
        (ok none)
    )
)

(define-private (compute-weighted-reputation 
    (current-reputation uint) 
    (new-reputation uint) 
    (total-evaluations uint)
    (evaluator-precision uint)
    )
    (let
        (
            (base-reputation-weight (/ (* current-reputation total-evaluations) (+ total-evaluations u1)))
            (new-reputation-weight (/ (* new-reputation evaluator-precision) (* u100 (+ total-evaluations u1))))
        )
        (+ base-reputation-weight new-reputation-weight)
    )
)

(define-private (apply-reputation-decay (reputation-score uint) (last-activity-epoch uint))
    (let
        (
            (elapsed-epochs (- (get current-protocol-epoch (var-get protocol-metrics)) last-activity-epoch))
            (decay-magnitude (* (/ elapsed-epochs REPUTATION-DECAY-INTERVAL) REPUTATION-DECAY-RATE))
        )
        (if (> reputation-score decay-magnitude)
            (- reputation-score decay-magnitude)
            MIN-REPUTATION-SCORE
        )
    )
)

;; Public Protocol Management Functions
(define-public (update-protocol-configuration 
    (proposed-protocol-params {
        minimum-reputation-threshold: uint,
        maximum-reputation-threshold: uint,
        minimum-stake-amount: uint,
        epoch-block-length: uint
    }))
    (begin
        (asserts! (is-governance-administrator) ERR-UNAUTHORIZED-ACCESS)
        
        ;; Explicitly validate the minimum-reputation-threshold
        (asserts! (>= (get minimum-reputation-threshold proposed-protocol-params) MIN-REPUTATION-SCORE) ERR-INVALID-PARAMETERS)
        
        ;; Explicitly validate the maximum-reputation-threshold
        (asserts! (<= (get maximum-reputation-threshold proposed-protocol-params) MAX-REPUTATION-SCORE) ERR-INVALID-PARAMETERS)
        
        ;; Explicitly validate the minimum-stake-amount
        (asserts! (>= (get minimum-stake-amount proposed-protocol-params) MINIMUM-STAKE-REQUIREMENT) ERR-INVALID-PARAMETERS)
        
        ;; Explicitly validate the epoch-block-length
        (asserts! (and 
            (>= (get epoch-block-length proposed-protocol-params) u1)
            (<= (get epoch-block-length proposed-protocol-params) u10000)
        ) ERR-INVALID-PARAMETERS)
        
        (let
            ((validated-params (try! (validate-protocol-configuration proposed-protocol-params))))
            
            ;; Additional validation after the validate-protocol-configuration function
            (asserts! (< (get minimum-reputation-threshold validated-params) 
                        (get maximum-reputation-threshold validated-params)) 
                    ERR-INVALID-PARAMETERS)
            
            (var-set protocol-configuration validated-params)
            (ok true)
        )
    )
)

(define-public (register-new-participant (initial-stake uint))
    (let
        (
            (protocol-params (var-get protocol-configuration))
        )
        (asserts! (>= initial-stake (get minimum-stake-amount protocol-params)) ERR-ECONOMIC-POLICY-VIOLATION)
        (asserts! (is-none (map-get? participant-directory tx-sender)) ERR-PARTICIPANT-ALREADY-EXISTS)
        
        (try! (stx-transfer? initial-stake tx-sender (as-contract tx-sender)))
        
        (let
            (
                (new-participant-record {
                    reputation-level: MAX-REPUTATION-SCORE,
                    last-activity-epoch: (get current-protocol-epoch (var-get protocol-metrics)),
                    total-evaluations-received: u0,
                    stake-balance: initial-stake,
                    participant-status: "ACTIVE"
                })
            )
            (map-set participant-directory tx-sender new-participant-record)
        )
        
        (var-set protocol-metrics
            (merge (var-get protocol-metrics)
                {
                    total-participants: (+ (get total-participants (var-get protocol-metrics)) u1),
                    total-staked-value: (+ (get total-staked-value (var-get protocol-metrics)) initial-stake)
                }
            )
        )
        (ok true)
    )
)

(define-public (submit-participant-reputation-evaluation 
    (target-participant principal) 
    (proposed-reputation-score uint)
    (evaluation-context (optional (string-utf8 100))))
    (let
        (
            (evaluator-credentials (unwrap! (map-get? evaluator-authorization tx-sender) ERR-UNAUTHORIZED-ACCESS))
            (participant-record (unwrap! (map-get? participant-directory target-participant) ERR-PARTICIPANT-NOT-FOUND))
            (current-protocol-epoch (get current-protocol-epoch (var-get protocol-metrics)))
            ;; Create a safe default context
            (default-context none)
        )
        (asserts! (get is-authorized evaluator-credentials) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (is-within-reputation-bounds proposed-reputation-score) ERR-OUT-OF-BOUNDS)
        
        ;; Validate the evaluation context and get a validated version
        (let
            (
                ;; Use unwrap-panic since we're just validating, not returning the result
                (validated-context (if (is-some evaluation-context)
                                      (begin
                                        ;; Validate and use the original if valid
                                        (unwrap-panic (validate-evaluation-context evaluation-context))
                                        evaluation-context)
                                      ;; Use the default if none provided
                                      default-context))
                
                (weighted-reputation-score (compute-weighted-reputation 
                    (get reputation-level participant-record)
                    proposed-reputation-score
                    (get total-evaluations-received participant-record)
                    (get evaluator-accuracy-score evaluator-credentials)
                ))
                (updated-participant-record (merge participant-record
                    {
                        reputation-level: weighted-reputation-score,
                        last-activity-epoch: current-protocol-epoch,
                        total-evaluations-received: (+ (get total-evaluations-received participant-record) u1)
                    }
                ))
            )
            (asserts! (is-within-reputation-bounds weighted-reputation-score) ERR-OUT-OF-BOUNDS)
            
            (map-set reputation-evaluation-log 
                { evaluated-participant: target-participant, evaluation-epoch: current-protocol-epoch }
                {
                    base-reputation-score: proposed-reputation-score,
                    weighted-reputation-score: weighted-reputation-score,
                    evaluator-principal: tx-sender,
                    evaluation-timestamp: block-height,
                    evaluation-context: validated-context
                }
            )
            
            (map-set participant-directory target-participant updated-participant-record)
            
            (var-set protocol-metrics
                (merge (var-get protocol-metrics)
                    {
                        total-reputation-evaluations: (+ (get total-reputation-evaluations (var-get protocol-metrics)) u1)
                    }
                )
            )
            
            (ok weighted-reputation-score)
        )
    )
)

;; Read-Only Query Functions
(define-read-only (get-participant-profile (target-participant principal))
    (let
        (
            (participant-record (unwrap! (map-get? participant-directory target-participant) ERR-PARTICIPANT-NOT-FOUND))
        )
        (ok {
            current-reputation: (apply-reputation-decay 
                (get reputation-level participant-record)
                (get last-activity-epoch participant-record)
            ),
            total-evaluations: (get total-evaluations-received participant-record),
            stake-balance: (get stake-balance participant-record),
            participant-status: (get participant-status participant-record)
        })
    )
)

(define-read-only (get-protocol-performance-metrics)
    (ok (var-get protocol-metrics))
)

(define-read-only (is-governance-administrator)
    (is-eq tx-sender (var-get protocol-governance-admin))
)

(define-read-only (retrieve-participant-evaluation-history 
    (target-participant principal) 
    (start-epoch uint)
    (end-epoch uint))
    (ok (map-get? reputation-evaluation-log 
        { evaluated-participant: target-participant, evaluation-epoch: start-epoch }))
)