----------------------------- MODULE TendermintAccountabilityApa2 -----------------------------
(*
 A TLA+ specification of subset of Tendermint consensus needed to formalize
 fork accountability protocol. In this version, the faults are injected right
 in the initial states.
 
 This is the version for compatibility with Apalache.

 Zarko Milosevic, Igor Konnov, 2019-2020.
 *)

EXTENDS Integers, FiniteSets

CONSTANTS PropFun \* the proposer function

N == 4 \* the total number of processes: correct and faulty
T == 1 \* an upper bound on the number of Byzantine processes
F == 1 \* the number of Byzantine processes
NFaultyProposals == 0   \* the number of injected faulty PROPOSE messages
NFaultyPrevotes == 6    \* the number of injected faulty PREVOTE messages
NFaultyPrecommits == 6  \* the number of injected faulty PRECOMMIT messages
Corr == {"c1", "c2", "c3"}  \* 1..N-F
Faulty == {"f1"}            \* N-F+1..N
AllProcs == Corr \cup Faulty
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

MT == [type |-> STRING, src |-> STRING, round |-> Int,
       proposal |-> STRING, validRound |-> Int, id |-> STRING]
       
AsMsg(m) == m <: MT
SetOfMsgs(S) == S <: {MT}       
EmptyMsgSet == SetOfMsgs({})

\* the proposer is arbitrary -- works for safety 
ConstInit == PropFun \in [Rounds -> AllProcs]
(* END-OF-APALACHE *)


\* these variables are exactly as in the pseudo-code
VARIABLES round, step, decision, lockedValue, lockedRound, validValue, validRound

\* book-keeping variables

VARIABLES msgsPropose,
 \* PROPOSE messages broadcasted in the system, a function Rounds -> set of messages
          msgsPrevote,
 \* PREVOTE messages broadcasted in the system, a function Rounds -> set of messages
          msgsPrecommit,
 \* PRECOMMIT messages broadcasted in the system, a function Rounds -> set of messages  
          evidence
  \* at every step, evidence contains the messages that were used by the active process
 
\* this is needed for UNCHANGED
vars == <<round, step, decision, lockedValue, lockedRound,
          validValue, validRound, msgsPropose, msgsPrevote, msgsPrecommit>>

\* A function which gives the proposer for a given round at a given height.
Proposer(rd) == PropFun[rd]

\* A value hash. The identity is a perfect hash, except it does not shrink the set.
Id(v) == v

\* The validity predicate
IsValid(v) == v \in ValidValues

\* Given a set of allowed messages Msgs, this operator produces a function from
\* rounds to sets of messages.
\* Importantly, there will be exactly k messages in the image of msgFun.
\* We use this action to produce k faults in an initial state.
ProduceFaults(msgFun, From, k) ==
    \E f \in [1..k -> From]:
        msgFun = [r \in Rounds |-> {m \in {f[i]: i \in 1..k}: m.round = r}]

\* here we start with StartRound(0)
Init ==
    /\ round = [p \in Corr |-> 0]
    /\ step = [p \in Corr |-> "PROPOSE"]    \* Q: where we define set of possible steps process can be in?
    /\ decision = [p \in Corr |-> NilValue]
    /\ lockedValue = [p \in Corr |-> NilValue]
    /\ lockedRound = [p \in Corr |-> NilRound]
    /\ validValue = [p \in Corr |-> NilValue]
    /\ validRound = [p \in Corr |-> NilRound]
    /\ ProduceFaults(msgsPrevote',
                     SetOfMsgs([type: {"PREVOTE"}, src: Faulty, round: Rounds, id: Values]),
                     NFaultyPrevotes)
    /\ ProduceFaults(msgsPrecommit',
                     SetOfMsgs([type: {"PRECOMMIT"}, src: Faulty, round: Rounds, id: Values]),
                     NFaultyPrecommits)
    /\ ProduceFaults(msgsPropose',
                     SetOfMsgs([type: {"PROPOSAL"}, src: Faulty, round: Rounds,
                                proposal: Values, validRound: Rounds \cup {NilRound}]),
                     NFaultyProposals)
    /\ evidence = EmptyMsgSet
    
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
      /\ LET msg == AsMsg([type |-> "PROPOSAL", src |-> Proposer(round[p]),
           round |-> round[p], proposal |-> v, validRound |-> NilRound]) IN
          /\ msg \in msgsPropose[round[p]] \* line 22
          /\ evidence' = {msg}
      /\ LET isGood == IsValid(v) /\ (lockedRound[p] = NilRound \/ lockedValue[p] = v) IN \* line 23
         LET newMsg == AsMsg([type |-> "PREVOTE", src |-> p,
                     round |-> round[p], id |-> IF isGood THEN Id(v) ELSE NilValue])
         IN  \* lines 24-26
         /\ msgsPrevote' = [msgsPrevote EXCEPT ![round[p]] =
                                msgsPrevote[round[p]] \cup {newMsg}] 
      /\ step' = [step EXCEPT ![p] = "PREVOTE"]
      /\ UNCHANGED <<round, decision, lockedValue, lockedRound,
                     validValue, validRound, msgsPropose, msgsPrecommit>>

\* lines 28-33        
UponProposalInProposeAndPrevote(p) ==
    \E v \in Values, vr \in Rounds:
      /\ step[p] = "PROPOSE" /\ 0 <= vr /\ vr < round[p] \* line 28, the while part
      /\ LET msg == AsMsg([type |-> "PROPOSAL", src |-> Proposer(round[p]),
                        round |-> round[p], proposal |-> v, validRound |-> vr]) IN
          /\ msg \in msgsPropose[round[p]] \* line 28
          /\ LET PV == { m \in msgsPrevote[vr]: m.id = Id(v) } IN
             /\ Cardinality(PV) >= THRESHOLD2 \* line 28
             /\ evidence' = PV \union {msg}
      /\ LET isGood == IsValid(v) /\ (lockedRound[p] <= vr \/ lockedValue[p] = v) IN \* line 29
         LET newMsg == AsMsg([type |-> "PREVOTE", src |-> p, 
                     round |-> round[p], id |-> IF isGood THEN Id(v) ELSE NilValue])
         IN \* lines 30-32
         /\ msgsPrevote' = [msgsPrevote EXCEPT ![round[p]] =
                            msgsPrevote[round[p]] \cup {newMsg}] 
      /\ step' = [step EXCEPT ![p] = "PREVOTE"]
      /\ UNCHANGED <<round, decision, lockedValue, lockedRound,
                     validValue, validRound, msgsPropose, msgsPrecommit>>
                     
InsertProposal(p) == 
  LET r == round[p] IN
    /\ p = Proposer(r)
    /\ step[p] = "PROPOSE"
    \* if the proposer is sending a proposal, then there are no other proposals
    \* by the correct processes for the same round
    /\ \A m \in msgsPropose[r]: m.src \in Faulty
    /\ \E v \in ValidValues: 
        LET proposal == IF validValue[p] /= NilValue THEN validValue[p] ELSE v IN
        LET newMsg ==
            AsMsg([type |-> "PROPOSAL", src |-> p, round |-> r,
                proposal |-> proposal, validRound |-> validRound[p]])
        IN
        \* a correct proposer never sends two proposals
        msgsPropose' = [msgsPropose EXCEPT ![r] =
                                msgsPropose[r] \cup {newMsg}]  
    /\ evidence' = EmptyMsgSet
    /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue, step,
                         validRound, msgsPrevote, msgsPrecommit>>
                     
                     
 \* lines 34-35 + lines 61-64
UponQuorumOfPrevotesAny(p) ==
      /\ step[p] = "PREVOTE" \* line 34 and 61
      /\ Cardinality(msgsPrevote[round[p]]) >= THRESHOLD2 \* line 34
         \* TODO: Note that multiple messages from the same (faulty) process may trigger this rule!  
      /\ evidence' = msgsPrevote[round[p]]
      /\ LET newMsg == AsMsg([type |-> "PRECOMMIT", src |-> p, round |-> round[p], id |-> NilValue]) IN
          msgsPrecommit' = [msgsPrecommit EXCEPT ![round[p]] =
                            msgsPrecommit[round[p]] \cup {newMsg}] 
      /\ step' = [step EXCEPT ![p] = "PRECOMMIT"]
      /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrevote>>
                     
                     
\* lines 36-46
UponProposalInPrevoteOrCommitAndPrevote(p) ==
    \E v \in ValidValues, vr \in Rounds \cup {NilRound}:
      /\ step[p] \in {"PREVOTE", "PRECOMMIT"} \* line 36
      /\ LET msg == AsMsg([type |-> "PROPOSAL", src |-> Proposer(round[p]),
                           round |-> round[p], proposal |-> v, validRound |-> vr]) IN
          /\ msg \in msgsPropose[round[p]] \* line 36
          /\ LET PV == { m \in msgsPrevote[round[p]]: m.id = Id(v) } IN
             /\ Cardinality(PV) >= THRESHOLD2 \* line 36
             /\ evidence' = PV \union {msg}
      /\ lockedValue' =
         IF step[p] = "PREVOTE"
         THEN [lockedValue EXCEPT ![p] = v] \* line 38
         ELSE lockedValue \* else of line 37
      /\ lockedRound' =
         IF step[p] = "PREVOTE"
         THEN [lockedRound EXCEPT ![p] = round[p]] \* line 39
         ELSE lockedRound \* else of line 37
      /\  IF step[p] = "PREVOTE"
          THEN
          LET newMsg == AsMsg([type |-> "PRECOMMIT", src |-> p, round |-> round[p], id |-> Id(v)])
          IN
          msgsPrecommit' = [msgsPrecommit EXCEPT ![round[p]] =
                            msgsPrecommit[round[p]] \cup {newMsg}] \* line 40, or else of 37
          ELSE UNCHANGED msgsPrecommit \* line 40
      /\ step' = IF step[p] = "PREVOTE" THEN [step EXCEPT ![p] = "PRECOMMIT"] ELSE step \* line 41
      /\ validValue' = [validValue EXCEPT ![p] = v] \* line 42
      /\ validRound' = [validRound EXCEPT ![p] = round[p]] \* line 43
      /\ UNCHANGED <<round, decision, msgsPropose, msgsPrevote>>
      
      
\* lines 11-21
StartRound(p, r) ==
   /\ step[p] /= "DECIDED" \* when decided, do not switch the round
   /\ round' = [round EXCEPT ![p] = r]
   /\ step' = [step EXCEPT ![p] = "PROPOSE"] 

\* lines 47-48        
UponQuorumOfPrecommitsAny(p) ==
      /\ Cardinality(msgsPrecommit[round[p]]) >= THRESHOLD2 \* line 47
      /\ evidence' = msgsPrecommit[round[p]]
      /\ round[p] + 1 \in Rounds
      /\ StartRound(p, round[p] + 1)   
      /\ UNCHANGED <<decision, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrevote, msgsPrecommit>>
                     
\* lines 49-54        
UponProposalInPrecommitNoDecision(p) ==
    /\ decision[p] = NilValue \* line 49
    \* TODO: a catch-up is going on here, not exactly Algorithm 1
    /\ \E v \in ValidValues (* line 50*) , r \in Rounds, vr \in Rounds \cup {NilRound}:
      /\ LET msg == AsMsg([type |-> "PROPOSAL", src |-> Proposer(r), 
                           round |-> r, proposal |-> v, validRound |-> vr]) IN
          /\ msg \in msgsPropose[r] \* line 49
          /\ LET PV == { m \in msgsPrecommit[r]: m.id = Id(v) } IN
             /\ Cardinality(PV) >= THRESHOLD2 \* line 49
             /\ evidence' = PV \union {msg}
      /\ decision' = [decision EXCEPT ![p] = v] \* update the decision, line 51
      \* The original algorithm does not have the 'DECIDED' step, but it increments the height.
      \* Thus, we introduced 'DECIDED' here to prevent the process from changing its decision.
      /\ step' = [step EXCEPT ![p] = "DECIDED"]
      /\ UNCHANGED <<round, lockedValue, lockedRound, validValue,
                     validRound, msgsPropose, msgsPrevote, msgsPrecommit>>
                                                          

Next ==
      /\ \E p \in Corr:
           \/ UponProposalInPropose(p)
           \/ UponProposalInProposeAndPrevote(p)
           \/ InsertProposal(p)
           \/ UponQuorumOfPrevotesAny(p)
           \/ UponProposalInPrevoteOrCommitAndPrevote(p)
           \/ UponQuorumOfPrecommitsAny(p)
           \/ UponProposalInPrecommitNoDecision(p)
        
    \* a safeguard to prevent deadlocks when the algorithm goes to further heights or rounds
    \*\/ UNCHANGED vars

(******************************** INVARIANTS *********************************)
(* first, we define the sets of all potential messages *)
AllProposals == 
  [type: {"PROPOSAL"},
   src: AllProcs,
   round: Rounds,
   proposal: Values \cup {NilValue},
   validRound: Rounds \cup {NilRound}] <: {MT}
  
AllPrevotes ==
  [type: {"PREVOTE"},
   src: AllProcs,
   round: Rounds,
   id: Values \cup {NilValue}] <: {MT}

AllPrecommits ==
  [type: {"PRECOMMIT"},
   src: AllProcs,
   round: Rounds,
   id: Values \cup {NilValue}] <: {MT}
   
BenignRoundsInMessages(msgfun) ==
  \* the message function never contains a message for a wrong round
  \A r \in Rounds:
    \A m \in msgfun[r]:
      r = m.round

(* the standard type invariant -- importantly, it is inductive *)
TypeOK ==
    /\ round \in [Corr -> Rounds]
    /\ step \in [Corr -> { "PROPOSE", "PREVOTE", "PRECOMMIT", "DECIDED" }]
    /\ decision \in [Corr -> ValidValues \cup {NilValue}]
    /\ lockedValue \in [Corr -> ValidValues \cup {NilValue}]
    /\ lockedRound \in [Corr -> Rounds \cup {NilRound}]
    /\ validValue \in [Corr -> ValidValues \cup {NilValue}]
    /\ validRound \in [Corr -> Rounds \cup {NilRound}]
    /\ msgsPropose \in [Rounds -> SUBSET AllProposals]
    /\ BenignRoundsInMessages(msgsPropose)
    /\ msgsPrevote \in [Rounds -> SUBSET AllPrevotes]
    /\ BenignRoundsInMessages(msgsPrevote)
    /\ msgsPrecommit \in [Rounds -> SUBSET AllPrecommits]
    /\ BenignRoundsInMessages(msgsPrecommit)
    /\ evidence \in SUBSET (AllProposals \union AllPrevotes \union AllPrecommits)

NoFutureMessagesForLargerRounds(p) ==
  \* a correct process does not send messages for the future rounds
  \A r \in { rr \in Rounds: rr > round[p] }:
    /\ \A m \in msgsPropose[r]: m.src /= p
    /\ \A m \in msgsPrevote[r]: m.src /= p
    /\ \A m \in msgsPrecommit[r]: m.src /= p

NoFutureMessagesForCurrentRound(p) ==
  \* a correct process does not send messages in the future
  LET r == round[p] IN
    /\ Proposer(r) = p \/ \A m \in msgsPropose[r]: m.src /= p
    /\ \/ step[p] \in {"PREVOTE", "PRECOMMIT", "DECIDED"}
       \/ \A m \in msgsPrevote[r]: m.src /= p
    /\ \/ step[p] \in {"PRECOMMIT", "DECIDED"}
       \/ \A m \in msgsPrecommit[r]: m.src /= p
          
\* the correct processes never send future messages
AllNoFutureMessagesSent ==
  \A p \in Corr:
    /\ NoFutureMessagesForCurrentRound(p)                 
    /\ NoFutureMessagesForLargerRounds(p)

\* a correct process in the PREVOTE state has sent a PREVOTE message
IfInPrevoteThenSentPrevote(p) ==
  step[p] = "PREVOTE" =>
    \E m \in msgsPrevote[round[p]]:
      /\ m.id \in ValidValues \cup { NilValue }
      /\ m.src = p
      
AllIfInPrevoteThenSentPrevote ==
  \A p \in Corr: IfInPrevoteThenSentPrevote(p)      

\* a correct process in the PRECOMMIT state has sent a PRECOMMIT message
IfInPrecommitThenSentPrecommit(p) ==
  step[p] = "PRECOMMIT" =>
    \E m \in msgsPrecommit[round[p]]:
      /\ m.id \in ValidValues \cup { NilValue }
      /\ m.src = p
      
AllIfInPrecommitThenSentPrecommit ==
  \A p \in Corr: IfInPrecommitThenSentPrecommit(p)      

\* a process in the PRECOMMIT state has sent a PRECOMMIT message
IfInDecidedThenValidDecision(p) ==
  step[p] = "DECIDED" <=> decision[p] \in ValidValues
  
AllIfInDecidedThenValidDecision ==
  \A p \in Corr: IfInDecidedThenValidDecision(p)  

\* a decided process should have received a proposal on its decision
IfInDecidedThenReceivedProposal(p) ==
  step[p] = "DECIDED" =>
    \E r \in Rounds: \* r is not necessarily round[p]
      /\ \E m \in msgsPropose[r]:
          /\ m.src = Proposer(r)
          /\ m.proposal = decision[p]
          \* not inductive: /\ m.src \in Corr => (m.validRound <= r)
          
AllIfInDecidedThenReceivedProposal ==
  \A p \in Corr: IfInDecidedThenReceivedProposal(p)          

\* a decided process has received two-thirds of precommit messages
IfInDecidedThenReceivedTwoThirds(p) ==
  step[p] = "DECIDED" =>
    \E r \in Rounds:
      LET PV == { m \in msgsPrecommit[r]: m.id = decision[p] } IN
        Cardinality(PV) >= THRESHOLD2
        
AllIfInDecidedThenReceivedTwoThirds ==
  \A p \in Corr: IfInDecidedThenReceivedTwoThirds(p)        

\* for a round r, there is proposal by the round proposer for a valid round vr
ProposalInRound(r, proposedVal, vr) ==
  \E m \in msgsPropose[r]:
    /\ m.src = Proposer(r)
    /\ m.proposal = proposedVal
    /\ m.validRound = vr

TwoThirdsPrevotes(vr, v) ==
  LET PV == { mm \in msgsPrevote[vr]: mm.id = v } IN
  Cardinality(PV) >= THRESHOLD2

\* if a process sends a PREVOTE, then there are three possibilities:
\* 1) the process is faulty, 2) the PREVOTE cotains Nil,
\* 3) there is a proposal in an earlier (valid) round and two thirds of PREVOTES
IfSentPrevoteThenReceivedProposalOrTwoThirds(r) ==
  \A mpv \in msgsPrevote[r]:
    \/ mpv.src \in Faulty
      \* lockedRound and lockedValue is beyond my comprehension
    \/ mpv.id = NilValue
    \//\ mpv.src \in Corr
      /\ mpv.id /= NilValue
      /\ \/ ProposalInRound(r, mpv.id, NilRound)
         \/ \E vr \in { rr \in Rounds: rr < r }:
            /\ ProposalInRound(r, mpv.id, vr)
            /\ TwoThirdsPrevotes(vr, mpv.id)

AllIfSentPrevoteThenReceivedProposalOrTwoThirds ==
  \A r \in Rounds:
    IfSentPrevoteThenReceivedProposalOrTwoThirds(r)

\* if a correct process has sent a PRECOMMIT, then there are two thirds,
\* either on a valid value, or a nil value
IfSentPrecommitThenReceivedTwoThirds ==
  \A r \in Rounds:
    \A mpc \in msgsPrecommit[r]:
      \/ mpc.src \in Faulty
      \/ /\ mpc.src \in Corr
         /\ \/ /\ mpc.id \in ValidValues
               /\ LET PV == { m \in msgsPrevote[r]: m.id = mpc.id } IN
                  Cardinality(PV) >= THRESHOLD2
            \/ /\ mpc.id = NilValue
               /\ Cardinality(msgsPrevote[r]) >= THRESHOLD2

\* there is a locked round if a only if there is a locked value
LockedRoundIffLockedValue(p) ==
  (lockedRound[p] = NilRound) <=> (lockedValue[p] = NilValue)
  
AllLockedRoundIffLockedValue ==
  \A p \in Corr: LockedRoundIffLockedValue(p)
            
\* when a process locked a round, it should have seen a precommit on a locked value
IfLockedRoundThenSentCommit(p) ==
  lockedRound[p] /= NilRound
    => \E r \in { rr \in Rounds: rr <= round[p] }:
       \E m \in msgsPrecommit[r]:
         m.src = p /\ m.id = lockedValue[p]
         
AllIfLockedRoundThenSentCommit ==
  \A p \in Corr: IfLockedRoundThenSentCommit(p)
         
\* a process always locks the latest round, for which it has sent a PRECOMMIT
LatestPrecommitHasLockedRound(p) ==
  LET pPrecommits == {mm \in UNION { msgsPrecommit[r]: r \in Rounds }: mm.src = p } IN
  pPrecommits /= {} <: {MT}
    => LET latest ==
         CHOOSE m \in pPrecommits:
           \A m2 \in pPrecommits:
             m2.round < m.round
       IN
       /\ lockedRound[p] = latest.round
       /\ lockedValue[p] = latest.id
       
AllLatestPrecommitHasLockedRound ==
  \A p \in Corr:
    LatestPrecommitHasLockedRound(p)
    
\* NOT USED?
ValidRoundNotSmallerThanLockedRound(p) ==
  validRound[p] >= lockedRound[p]

ValidRoundIffValidValue(p) ==
  (validRound[p] = NilRound) <=> (validValue[p] = NilValue)

AllValidRoundIffValidValue ==
  \A p \in Corr: ValidRoundIffValidValue(p)

\* if validRound is defined, then there are two-thirds of PREVOTEs
IfValidRoundThenTwoThirds(p) ==
  \/ validRound[p] = NilRound
  \/ LET PV == { m \in msgsPrevote[validRound[p]]: m.id = validValue[p] } IN
     Cardinality(PV) >= THRESHOLD2
     
AllIfValidRoundThenTwoThirds ==
  \A p \in Corr: IfValidRoundThenTwoThirds(p)     

\* a valid round can be only set to a valid value that was proposed earlier
IfValidRoundThenProposal(p) ==
  \/ validRound[p] = NilRound
  \/ \E m \in msgsPropose[validRound[p]]:
       m.proposal = validValue[p]

AllIfValidRoundThenProposal ==
  \A p \in Corr: IfValidRoundThenProposal(p)

\* Every correct process sends only one value or NilValue.
\* This test has quantifier alternation -- a threat to all decision procedures.
\* Luckily, the sets Corr and ValidValues are small.
NoEquivocationByCorrect(r, msgs) ==
  \A p \in Corr:
    \E v \in ValidValues \cup {NilValue}:
      \A m \in msgs[r]:
        \/ m.src /= p
        \/ m.id = v

\* a proposer nevers sends two values
ProposalsByProposer(r, msgs) ==
  \* if the proposer is not faulty, it sends only one value
  \E v \in ValidValues:
    \A m \in msgs[r]:
      \/ m.src \in Faulty
      \/ m.src = Proposer(r) /\ m.proposal = v
    
AllNoEquivocationByCorrect ==
  \A r \in Rounds:
    /\ ProposalsByProposer(r, msgsPropose)    
    /\ NoEquivocationByCorrect(r, msgsPrevote)    
    /\ NoEquivocationByCorrect(r, msgsPrecommit)    

\* construct the set of the message senders
Senders(M) == { m.src: m \in M }

\* The final piece by Josef Widder:
\* if T + 1 processes precommit on the same value in a round,
\* then in the future rounds there are less than 2T + 1 prevotes for another value
PrecommitsLockValue ==
  \A r \in Rounds:
    \A v \in ValidValues \union {NilValue}:
      \/ Cardinality(Senders({m \in msgsPrecommit[r]: m.id = v})) < THRESHOLD1
      \/ \A fr \in { rr \in Rounds: rr > r }:  \* future rounds
           \A w \in (Values \union {NilValue}) \ {v}:
            Cardinality(Senders({m \in msgsPrevote[fr]: m.id = w})) < THRESHOLD2
    
Inv ==
    /\ AllNoFutureMessagesSent
    /\ AllIfInPrevoteThenSentPrevote
    /\ AllIfInPrecommitThenSentPrecommit
    /\ AllIfInDecidedThenReceivedProposal 
    /\ AllIfInDecidedThenReceivedTwoThirds 
    /\ AllIfInDecidedThenValidDecision
    /\ AllLockedRoundIffLockedValue
    /\ AllIfLockedRoundThenSentCommit
    /\ AllLatestPrecommitHasLockedRound
    \* /\ AllIfValidRoundThenTwoThirds  \* no need for safety
    \*/\ AllIfValidRoundThenProposal    \* no need for safety
    /\ AllIfSentPrevoteThenReceivedProposalOrTwoThirds
    /\ IfSentPrecommitThenReceivedTwoThirds
    /\ AllNoEquivocationByCorrect
    /\ PrecommitsLockValue

TypedInv == TypeOK /\ Inv    
    
(**************************** FORK ACCOUNTABILITY  ***************************)
Equivocation ==
  \E r \in Rounds:
    \/ \E m1, m2 \in msgsPropose[r]:
      m1 /= m2 /\ m1.src = m2.src
    \/ \E m1, m2 \in msgsPrevote[r]:
      m1 /= m2 /\ m1.src = m2.src
    \/ \E m1, m2 \in msgsPrecommit[r]:
      m1 /= m2 /\ m1.src = m2.src

InitNoEquivocation ==
    Init /\ ~Equivocation

\* amnesic behavior by a process p
Amnesia(p) ==
    \E r1, r2 \in Rounds:
      /\ r1 < r2
      /\ \E v1, v2 \in ValidValues:
        /\ v1 /= v2
        /\ AsMsg([type |-> "PRECOMMIT", src |-> p, round |-> r1, id |-> Id(v1)]) \in msgsPrecommit[r1]    
        /\ AsMsg([type |-> "PREVOTE", src |-> p, round |-> r2, id |-> Id(v2)]) \in msgsPrecommit[r2]
        /\ \A r \in { rnd \in Rounds: r1 <= rnd /\ rnd <= r2 }:
            LET prevotes ==
                { m \in msgsPrevote[r]:
                  m.type = "PREVOTE" /\ m.round = r /\ m.id = Id(v2) }
            IN
            Cardinality(prevotes) < THRESHOLD2

(******************************** PROPERTIES  ***************************************)
\* simple reachability properties to see that the spec is progressing
NoPrevote == \A p \in Corr: step[p] /= "PREVOTE" 

NoPrecommit == \A p \in Corr: step[p] /= "PRECOMMIT"   

NoValidPrecommit ==
    \A r \in Rounds:
      \A m \in msgsPrecommit[r]:
        m.id = NilValue \/ m.src \in Faulty

NoHigherRounds == \A p \in Corr: round[p] < 1

NoDecision == \A p \in Corr: decision[p] = NilValue                    

\* the safety property -- agreement
Agreement == \A p, q \in Corr:
    \/ decision[p] = NilValue
    \/ decision[q] = NilValue
    \/ decision[p] = decision[q]

Validity ==
    \A p \in Corr: decision[p] \in ValidValues \union {NilValue}
 
\* when agreement is violated, at least one faulty process has amnesia
AgreementOrAmnesia ==
    Agreement \/ (\E p \in Faulty: Amnesia(p))
 
AgreementNoAmnesia ==
    Agreement \/ ~(\E p \in Faulty: Amnesia(p))

InvAndNoEquivocation ==
    Inv /\ ~Equivocation
    
\* use this predicate for the initial states
TypedInvNoEquivocationNoAmnesia ==
    TypeOK /\ Inv /\ ~Equivocation /\ (\A p \in Faulty: ~Amnesia(p))

\* the invariant to check
AgreementOrEquivocationOrAmnesia ==
    \/ Agreement
    \/ Equivocation
    \/ \E p \in Faulty: Amnesia(p)


=============================================================================    
 
