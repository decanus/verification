----------------------------- MODULE Blockchain -----------------------------
(* This is a high-level specification of Tendermint blockchain
   that is designed specifically for:
   
   (1) Lite client, and
   (2) Fork accountability.
 *)
EXTENDS Integers, Sequences

Min(a, b) == IF a < b THEN a ELSE b

CONSTANT
  AllNodes,
    (* a set of all nodes that can act as validators (correct and faulty) *)
  ULTIMATE_HEIGHT,
    (* a maximal height that can be ever reached (modelling artifact) *)
  MAX_POWER
    (* a maximal voting power of a single node *)

Heights == 0..ULTIMATE_HEIGHT   (* possible heights *)

Powers == 1..MAX_POWER          (* possible voting powers *)

(* A commit is just a set of nodes who have committed the block *)
Commits == SUBSET AllNodes

(* The set of all block headers that can be on the blockchain.
   This is a simplified version of the Block data structure in the actual implementation. *)
BlockHeaders == [
  height: Heights,
    \* the block height
  lastCommit: Commits,
    \* the nodes who have voted on the previous block, the set itself instead of a hash
  (* in the implementation, only the hashes of V and NextV are stored in a block,
     as V and NextV are stored in the application state *) 
  VP: UNION {[Nodes -> Powers]: Nodes \in SUBSET AllNodes \ {{}}},
    \* the validators of this block together with their voting powers,
    \* i.e., a multi-set. We store the validators instead of the hash.
  NextVP: UNION {[Nodes -> Powers]: Nodes \in SUBSET AllNodes \ {{}}}
    \* the validators of the next block together with their voting powers,
    \* i.e., a multi-set. We store the next validators instead of the hash.
]

(* A signed header is just a header together with a set of commits *)
\* TODO: Commits is the set of PRECOMMIT messages
SignedHeaders == BlockHeaders \X Commits

VARIABLES
    tooManyFaults,
    (* whether there are more faults in the system than the blockchain can handle *)
    height,
    (* the height of the blockchain, starting with 0 *)
    minTrustedHeight,
    (* The global height of the oldest block that is younger than
       the trusted period (AKA the almost rotten block).
       In the implementation, this is the oldest block,
       where block.bftTime + trustingPeriod >= globalClock.now. *)
    blockchain,
    (* A sequence of BlockHeaders,
       which gives us the God's (or Daemon's) view of the blockchain. *)
    Faulty
    (* A set of faulty nodes, which can act as validators. We assume that the set
       of faulty processes is non-decreasing. If a process has recovered, it should
       connect using a different id. *)
       
(* all variables, to be used with UNCHANGED *)       
vars == <<tooManyFaults, height, minTrustedHeight, blockchain, Faulty>>         

(* The set of all correct nodes in a state *)
Corr == AllNodes \ Faulty       

(****************************** BLOCKCHAIN ************************************)
(* in the future, we may extract it in a module on its own *)

(* Compute the total voting power of a subset of validators Nodes,
   whose individual voting powers are given by a function vp *)  
RECURSIVE PowerOfSet(_, _)
PowerOfSet(vp, Nodes) ==
    IF Nodes = {}
    THEN 0
    ELSE LET node == CHOOSE n \in Nodes: TRUE IN
        (* ASSERT(node \in DOMAIN vp) *)
        vp[node] + PowerOfSet(vp, Nodes \ {node})

TwoThirds(vp, set) ==
    LET TP == PowerOfSet(vp, DOMAIN vp)
        SP == PowerOfSet(vp, set)
    IN
    3 * SP > 2 * TP 

IsCorrectPowerForSet(Flt, vp, set) ==
    LET FV == Flt \intersect set
        CV == set \ FV
        CP == PowerOfSet(vp, CV)
        FP == PowerOfSet(vp, FV)
    IN
    CP > 2 * FP \* 2/3 rule. Note: when FP = 0, this implies CP > 0.

(* Is the voting power correct,
   that is, more than 2/3 of the voting power belongs to the correct processes? *)
IsCorrectPower(Flt, vp) ==
    IsCorrectPowerForSet(Flt, vp, DOMAIN vp)
    
(* This is what we believe is the assumption about failures in Tendermint *)     
FaultAssumption(Flt, mth, bc) ==
    \A h \in mth..Len(bc):
        IsCorrectPower(Flt, bc[h].NextVP)

(* Append a new block on the blockchain.
   Importantly, more than 2/3 of voting power in the next set of validators
   belongs to the correct processes. *)       
AppendBlock ==
  LET last == blockchain[Len(blockchain)] IN
  \E lastCommit \in (SUBSET (DOMAIN last.VP)) \ {{}},
     NextV \in SUBSET AllNodes \ {{}}:
     \E NextVP \in [NextV -> Powers]:
    LET new == [ height |-> height + 1, lastCommit |-> lastCommit,
                 VP |-> last.NextVP, NextVP |-> NextVP ] IN
    /\ TwoThirds(last.VP, lastCommit)
    /\ IsCorrectPower(Faulty, NextVP) \* the correct validators have >2/3 of power
    /\ blockchain' = Append(blockchain, new)
    /\ height' = height + 1

(* Initialize the blockchain *)
Init ==
  /\ tooManyFaults = FALSE
  /\ height = 1
  /\ minTrustedHeight = 1
  /\ Faulty = {}
  (* pick a genesis block of all nodes where next correct validators have >2/3 of power *)
  /\ \E NextV \in SUBSET AllNodes:
       \E NextVP \in [NextV -> Powers]:
         LET VP == [n \in AllNodes |-> 1] 
             genesis == [ height |-> 1, lastCommit |-> {},
                          VP |-> VP, NextVP |-> NextVP]
         IN
         /\ NextV /= {}
         /\ blockchain = <<genesis>>

(********************* BLOCKCHAIN ACTIONS ********************************)
          
(*
  The blockchain may progress by adding one more block, provided that:
     (1) The ultimate height has not been reached yet, and
     (2) The faults are within the bounds.
 *)
AdvanceChain ==
  /\ height < ULTIMATE_HEIGHT /\ ~tooManyFaults
  /\ AppendBlock
  /\ UNCHANGED <<minTrustedHeight, tooManyFaults, Faulty>>

(*
  As time is passing, the minimal trusted height may increase.
  As a result, the blockchain may move out of the faulty zone.
  *)
AdvanceTime ==
  /\ minTrustedHeight' \in (minTrustedHeight + 1) .. Min(height + 1, ULTIMATE_HEIGHT)
  /\ tooManyFaults' = ~FaultAssumption(Faulty, minTrustedHeight', blockchain)
  /\ UNCHANGED <<height, blockchain, Faulty>>

(* One more process fails. As a result, the blockchain may move into the faulty zone. *)
OneMoreFault ==
  /\ \E n \in AllNodes \ Faulty:
      /\ Faulty' = Faulty \cup {n}
      /\ tooManyFaults' = ~FaultAssumption(Faulty', minTrustedHeight, blockchain)
  /\ UNCHANGED <<height, minTrustedHeight, blockchain>>

(* stuttering at the end of the blockchain *)
StutterInTheEnd == 
  height = ULTIMATE_HEIGHT /\ UNCHANGED vars

(* Let the blockchain to make progress *)
Next ==
  \/ AdvanceChain
  \/ AdvanceTime
  \/ OneMoreFault
  \/ StutterInTheEnd


(* Invariant: it should be always possible to add one more block unless:
  (1) either there are too many faults,
  (2) or the bonding period of the last transaction has expired, so we are stuck.
 *)
NeverStuck ==
  \/ tooManyFaults
  \/ height = ULTIMATE_HEIGHT
  \/ minTrustedHeight > height \* the bonding period has expired
  \/ ENABLED AdvanceChain

NextVPNonEmpty ==
    \A h \in 1..Len(blockchain):
      DOMAIN blockchain[h].NextVP /= {}

(* False properties that can be checked with TLC, to see interesting behaviors *)

(* Check this to see how the blockchain can jump into the faulty zone *)
NeverFaulty == ~tooManyFaults

(* False: it should be always possible to add one more block *)
NeverStuckFalse1 ==
  ENABLED AdvanceChain

(* False: it should be always possible to add one more block *)
NeverStuckFalse2 ==
  \/ tooManyFaults
  \/ height = ULTIMATE_HEIGHT
  \/ ENABLED AdvanceChain

=============================================================================
\* Modification History
\* Last modified Thu Oct 17 12:28:38 CEST 2019 by igor
\* Created Fri Oct 11 15:45:11 CEST 2019 by igor
