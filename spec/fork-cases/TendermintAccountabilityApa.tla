----------------------------- MODULE TendermintAccountabilityApa -----------------------------
(*
 A TLA+ specification of subset of Tendermint consensus needed to formalize fork accountability 
 protocol.
 
 This is the version for compatibility with Apalache.
 *)

EXTENDS Integers, FiniteSets

CONSTANTS
    PropFun \* the proposer function

N == 4 \* the total number of processes: correct and faulty
T == 1 \* an upper bound on the number of Byzantine processes
F == 2 \* the number of Byzantine processes
Corr == 1..N-F
Faulty == N-F+1..N
AllCorr == 1..N
Rounds == 0..2  \* the set of possible rounds, give a bit more freedom to the solver
ValidValues == {"0", "1"}     \* e.g., picked by a correct process, or a faulty one
InvalidValues == {"2"}    \* e.g., sent by a Byzantine process
Values == ValidValues \cup InvalidValues \* all values
NilRound == -1
NilValue == "None"

\* these are two thresholds that are used in the algorithm
THRESHOLD1 == T + 1 
THRESHOLD2 == 2 * T + 1 

(* APALACHE *)
a <: b == a

MT == [type |-> STRING, src |-> Int, round |-> Int,
       proposal |-> STRING, validRound |-> Int, id |-> STRING]
       
AsMsg(m) == m <: MT
SetOfMsgs(S) == S <: {MT}       
EmptyMsgSet == SetOfMsgs({})

ConstInit ==
    \*StartId \in 1..N
    \* the proposer is arbitrary -- ok for safety 
    PropFun \in [Rounds -> AllCorr]

(* END-OF-APALACHE *)


\* these variables are exactly as in the pseudo-code
VARIABLES round, step, decision, lockedValue, lockedRound, validValue, validRound

\* book-keeping variables
VARIABLES msgsPropose, \* the propose messages broadcasted in the system, a function Heights \X Rounds -> set of messages
          msgsPrevote, \* the prevote messages broadcasted in the system, a function Heights \X Rounds -> set of messages  
          msgsPrecommit, \* the precommit messages broadcasted in the system, a function Heights \X Rounds -> set of messages  
          msgsReceived  \* set of received messages a process acted on (that triggered some rule), a function p \in Corr -> set of messages  
 
 
\* this is needed for UNCHANGED
vars == <<round, step, decision, lockedValue, lockedRound, validValue,
          validRound, msgsPropose, msgsPrevote, msgsPrecommit, msgsReceived>>

\* A function which gives the proposer for a given round at a given height.
\* Here we use round robin. As Corr and Faulty are assigned non-deterministically,
\* it does not really matter who starts first.
\*Proposer(rd) == 1 + ((StartId + rd) % N)
Proposer(rd) == PropFun[rd]

Id(v) == v

IsValid(v) == v \in ValidValues


\* here we start with StartRound(0)
Init ==
    /\ round = [p \in Corr |-> 0]
    /\ step = [p \in Corr |-> "PROPOSE"]    \* Q: where we define set of possible steps process can be in?
    /\ decision = [p \in Corr |-> NilValue]
    /\ lockedValue = [p \in Corr |-> NilValue]
    /\ lockedRound = [p \in Corr |-> NilRound]
    /\ validValue = [p \in Corr |-> NilValue]
    /\ validRound = [p \in Corr |-> NilRound]
    /\ msgsPrevote = [rd \in Rounds |-> EmptyMsgSet]
    /\ msgsPrecommit = [rd \in Rounds |-> EmptyMsgSet]
    /\ msgsPropose = [rd \in Rounds |-> EmptyMsgSet]
    /\ msgsReceived = [p \in Corr |-> EmptyMsgSet]
    
FaultyMessages == \* the messages that can be sent by the faulty processes
    (SetOfMsgs([type: {"PROPOSAL"}, src: Faulty,
              round: Rounds, proposal: Values, validRound: Rounds \cup {NilRound}]))
       \cup
    (SetOfMsgs([type: {"PREVOTE"}, src: Faulty, round: Rounds, id: Values]))
       \cup
    (SetOfMsgs([type: {"PRECOMMIT"}, src: Faulty, round: Rounds, id: Values]))
    

\* lines 22-27        
UponProposalInPropose(p) ==
    \E v \in Values:
      /\ step[p] = "PROPOSE" \* line 22
      /\ (AsMsg([type |-> "PROPOSAL", src |-> Proposer(round[p]),
           round |-> round[p], proposal |-> v, validRound |-> NilRound])) \in msgsPropose[round[p]] \* line 22
      /\ LET isGood == IsValid(v) /\ (lockedRound[p] = NilRound \/ lockedValue[p] = v) IN \* line 23
         LET newMsg == ({AsMsg([type |-> "PREVOTE", src |-> p,
                     round |-> round[p], id |-> IF isGood THEN Id(v) ELSE NilValue])})
         IN  \* lines 24-26
         msgsPrevote' = [msgsPrevote EXCEPT ![round[p]] =
                            msgsPrevote[round[p]] \cup newMsg] 
      /\ step' = [step EXCEPT ![p] = "PREVOTE"]
      /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrecommit, msgsReceived>>
                    

\* lines 28-33        
UponProposalInProposeAndPrevote(p) ==
    \E v \in Values, vr \in Rounds:
      /\ step[p] = "PROPOSE" /\ 0 <= vr /\ vr < round[p] \* line 28, the while part
      /\ (AsMsg([type |-> "PROPOSAL", src |-> Proposer(round[p]),
           round |-> round[p], proposal |-> v, validRound |-> vr])) \in msgsPropose[round[p]] \* line 28
      /\ LET PV == { m \in msgsPrevote[vr]: m.id = Id(v) } IN
         Cardinality(PV) >= THRESHOLD2 \* line 28
      /\ LET isGood == IsValid(v) /\ (lockedRound[p] <= vr \/ lockedValue[p] = v) IN \* line 29
         LET newMsg == ({AsMsg([type |-> "PREVOTE", src |-> p, 
                     round |-> round[p], id |-> IF isGood THEN Id(v) ELSE NilValue])})
         IN \* lines 30-32
         msgsPrevote' = [msgsPrevote EXCEPT ![round[p]] =
                            msgsPrevote[round[p]] \cup newMsg] 
      /\ step' = [step EXCEPT ![p] = "PREVOTE"]
      /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrecommit, msgsReceived>>
                     
\* TODO: Multiple proposal messages will potentially be generated from this rule. We should probably constrain sending multiple propose msgs!
InsertProposal(p) == 
    \E v \in ValidValues: 
     LET proposal == IF validValue[p] /= NilValue THEN validValue[p] ELSE v IN
     LET newMsg ==
        IF p = Proposer(round[p]) /\ step[p] = "PROPOSE"
        THEN {AsMsg([type |-> "PROPOSAL", src |-> p, round |-> round[p],
          proposal |-> proposal, validRound |-> validRound[p]])}
        ELSE EmptyMsgSet
     IN
     msgsPropose' = [msgsPropose EXCEPT ![round[p]] =
                            msgsPropose[round[p]] \cup newMsg]  
     /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue, step,
                     validRound, msgsPrevote, msgsPrecommit, msgsReceived>>  
                     
                     
 \* lines 34-35 + lines 61-64
UponQuorumOfPrevotesAny(p) ==
      /\ step[p] = "PREVOTE" \* line 34 and 61
      /\ Cardinality(msgsPrevote[round[p]]) >= THRESHOLD2 \* line 34 TODO: Note that multiple messages from the same (faulty) process will trigger this rule!  
      /\ LET newMsg == AsMsg([type |-> "PRECOMMIT", src |-> p, round |-> round[p], id |-> NilValue]) IN
         msgsPrecommit' = [msgsPrecommit EXCEPT ![round[p]] =
                            msgsPrecommit[round[p]] \cup {newMsg}] 
      /\ step' = [step EXCEPT ![p] = "PRECOMMIT"]
      /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrevote, msgsReceived>>
                     
                     
\* lines 36-46
UponProposalInPrevoteOrCommitAndPrevote(p) ==
    \E v \in ValidValues, vr \in Rounds \cup {NilRound}:
      /\ step[p] \in {"PREVOTE", "PRECOMMIT"} \* line 36
      /\ (AsMsg([type |-> "PROPOSAL", src |-> Proposer(round[p]),
           round |-> round[p], proposal |-> v, validRound |-> vr])) \in msgsPropose[round[p]] \* line 36
      /\ LET PV == { m \in msgsPrevote[round[p]]: m.id = Id(v) } IN
         Cardinality(PV) >= THRESHOLD2 \* line 36
      /\ lockedValue' =
         IF step[p] = "PREVOTE"
         THEN [lockedValue EXCEPT ![p] = v] \* line 38
         ELSE lockedValue \* else of line 37
      /\ lockedRound' =
         IF step[p] = "PREVOTE"
         THEN [lockedRound EXCEPT ![p] = round[p]] \* line 39
         ELSE lockedRound \* else of line 37
      /\ LET newMsgs ==
           IF step[p] = "PREVOTE"
           THEN {AsMsg([type |-> "PRECOMMIT", src |-> p, round |-> round[p], id |-> Id(v)])} \* line 40
           ELSE EmptyMsgSet 
         IN \* else of line 37
         msgsPrecommit' = [msgsPrecommit EXCEPT ![round[p]] =
                            msgsPrecommit[round[p]] \cup newMsgs] \* line 40, or else of 37
      /\ step' = IF step[p] = "PREVOTE" THEN [step EXCEPT ![p] = "PRECOMMIT"] ELSE step \* line 41
      /\ validValue' = [validValue EXCEPT ![p] = v] \* line 42
      /\ validRound' = [validRound EXCEPT ![p] = round[p]] \* line 43
      /\ UNCHANGED <<round, decision, msgsPropose, msgsPrevote, msgsReceived>>
      
      
\* lines 11-21
StartRound(p, r) ==
   /\ round' = [round EXCEPT ![p] = r]
   /\ step' = [step EXCEPT ![p] = "PROPOSE"] 
   

\* lines 47-48        
UponQuorumOfPrecommitsAny(p) ==
      /\ Cardinality(msgsPrecommit[round[p]]) >= THRESHOLD2 \* line 47
      /\ round[p] + 1 \in Rounds
      /\ StartRound(p, round[p] + 1)   
      /\ UNCHANGED <<decision, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrevote, msgsPrecommit, msgsReceived>> 
                     
                     
\* lines 49-54        
UponProposalInPrecommitNoDecision(p) ==
    /\ decision[p] = NilValue \* line 49
    /\ \E v \in ValidValues (* line 50*) , r \in Rounds, vr \in Rounds \cup {NilRound}:
      /\ (AsMsg([type |-> "PROPOSAL", src |-> Proposer(r), 
           round |-> r, proposal |-> v, validRound |-> vr])) \in msgsPropose[r] \* line 49
      /\ LET PV == { m \in msgsPrecommit[r]: m.id = Id(v) } IN
         Cardinality(PV) >= THRESHOLD2 \* line 49
      /\ decision' = [decision EXCEPT ![p] = v] \* update the decision, line 51
      /\ UNCHANGED <<round, step, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrevote, msgsPrecommit, msgsReceived>>                      
                                                          
InsertFaultyPrevoteMessage == 
    \E src \in Faulty:
      \E r \in Rounds:
        \E id \in Values:
          LET msg == AsMsg([type |-> "PREVOTE", src |-> src, round |-> r, id |-> id])
          IN
          /\ msgsPrevote' = [msgsPrevote EXCEPT ![msg.round] = msgsPrevote[msg.round] \cup {msg}]
          /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue, step,
                     validRound, msgsPropose, msgsPrecommit, msgsReceived>>  
                     
InsertFaultyPrecommitMessage == 
    \E src \in Faulty:
      \E r \in Rounds:
        \E id \in Values:
          LET msg == AsMsg([type |-> "PRECOMMIT", src |-> src, round |-> r, id |-> id])
          IN
          /\ msgsPrecommit' = [msgsPrecommit EXCEPT ![msg.round] = msgsPrecommit[msg.round] \cup {msg}]
          /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue, step,
                     validRound, msgsPropose, msgsPrevote, msgsReceived>>        
                     
InsertFaultyProposalMessage == 
    \E srcA \in Faulty, r \in Rounds, idV \in Values:
        LET newMsg == AsMsg([type |-> "PROPOSAL", src |-> srcA, round |-> r, id |-> idV]) IN
         msgsPropose' = [msgsPropose EXCEPT ![r] = msgsPropose[r] \cup {newMsg}] 
        /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue, step,
                     validRound, msgsPrecommit, msgsPrevote, msgsReceived>>                                            
Next ==
    \/ \E p \in Corr:
        \/ UponProposalInPropose(p)
        \/ UponProposalInProposeAndPrevote(p)
        \/ InsertProposal(p)
        \/ UponQuorumOfPrevotesAny(p)
        \/ UponProposalInPrevoteOrCommitAndPrevote(p)
        \/ UponQuorumOfPrecommitsAny(p)
        \/ InsertFaultyPrevoteMessage
        \/ InsertFaultyPrecommitMessage
        \/ UponProposalInPrecommitNoDecision(p)
        \/ InsertFaultyProposalMessage
        
    \* a safeguard to prevent deadlocks when the algorithm goes to further heights or rounds
    \*\/ UNCHANGED vars
                    
\* simple reachability properties to make sure that the algorithm is doing anything useful
NoPrevote == \A p \in Corr: step[p] /= "PREVOTE" 

NoPrecommit == \A p \in Corr: step[p] /= "PRECOMMIT"   

NoValidPrecommit ==
    \A r \in Rounds:
      \A m \in msgsPrecommit[r]:
        m.id = NilValue \/ m.src \in Faulty

NoHigherRounds == \A p \in Corr: round[p] < 1

NoDecision == \A p \in Corr: decision[p] = NilValue                    

Agreement == \A p, q \in Corr:
    \/ decision[p] = NilValue
    \/ decision[q] = NilValue
    \/ decision[p] = decision[q]
 
    
=============================================================================    
    
    
 
