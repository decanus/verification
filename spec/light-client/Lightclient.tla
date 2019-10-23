---------------------------- MODULE Lightclient ----------------------------
(*
 * A state-machine specification of the light client, following the English spec:
 * https://github.com/tendermint/tendermint/blob/master/docs/spec/consensus/light-client.md
 *
 * Whereas the English specification presents the light client as a piece of sequential code,
 * which contains non-tail recursion, we specify a state machine that explicitly has
 * a stack of requests in its state. This specification can be easily extended to support
 * multiple requests at the same time, e.g., to reduce latency.
 *) 

EXTENDS Integers, Sequences

\* the parameters of Lite Client
CONSTANTS
  TRUSTED_HEIGHT,
    (* an index of the block header that the light client trusts by social consensus *)
  TO_VERIFY_HEIGHT
    (* an index of the block header that the light client tries to verify *)

VARIABLES
  state,        (* the current state of the light client *)
  inEvent,      (* an input event to the light client, e.g., a header from a full node *)
  outEvent,     (* an output event from the light client, e.g., finished with a verdict *)
  requestStack,     (* the stack of requests to be issued by the light client to a full node *)
  storedHeaders     (* the set of headers obtained from a full node*) 

(* the variables of the lite client *)  
lcvars == <<state, outEvent, requestStack, storedHeaders>>  

(* the variables of the client's environment, that is, input events *)
envvars == <<inEvent>>  

(******************* Blockchain instance ***********************************)

\* the parameters that are propagated into Blockchain
CONSTANTS
  AllNodes,
    (* a set of all nodes that can act as validators (correct and faulty) *)
  ULTIMATE_HEIGHT,
    (* a maximal height that can be ever reached (modelling artifact) *)
  MAX_POWER
    (* a maximal voting power of a single node *)

\* the state variables of Blockchain, see Blockchain.tla for the details
VARIABLES tooManyFaults, height, minTrustedHeight, blockchain, Faulty

\* All the variables of Blockchain. For some reason, BC!vars does not work
bcvars == <<tooManyFaults, height, minTrustedHeight, blockchain, Faulty>>

(* Create an instance of Blockchain.
   We could write EXTENDS Blockchain, but then all the constants and state variables
   would be hidden inside the Blockchain module.
 *) 
BC == INSTANCE Blockchain WITH tooManyFaults <- tooManyFaults, height <- height,
  minTrustedHeight <- minTrustedHeight, blockchain <- blockchain, Faulty <- Faulty

(************************** Environment ************************************)
NoEvent == [type |-> "None"]

InEvents ==
        (* start the client given the height to verify (fixed in our modelling) *)
    [type: "start", heightToVerify: BC!Heights]
       \union
        (* receive a signed header that was requested before *)
    [type: "responseHeader", hdr: BC!SignedHeaders]
        \union
    {NoEvent}
    (* most likely, the implementation will have a timeout event, we do not need it here *)

(* initially, the environment is not issuing any requests to the lite client *)
EnvInit ==
    inEvent = NoEvent
    
(* The events that can be generated by the environment (reactor?):
    user requests and node responses *)
EnvNext ==
    \/ /\ state = "init"
       \* modeling feature, do not start the client before the blockchain is constructed
       /\ height >= TO_VERIFY_HEIGHT
       /\ inEvent' = [type |-> "start", heightToVerify |-> TO_VERIFY_HEIGHT]
    \/ /\ state = "working"
       /\ outEvent.type = "requestHeader"
       /\ \E hdr \in BC!SoundSignedHeaders(outEvent.height):
            inEvent' = [type |-> "responseHeader", hdr |-> hdr]

(************************** Lite client ************************************)

(* the control states of the lite client *) 
States == { "init", "working", "finished" }

(* the events that can be issued by the lite client *)    
OutEvents ==
        (* request the header for a given height from the peer full node *)
    [type: "requestHeader", height: BC!Heights]
        \union
        (* finish the check with a verdict *)
    [type: "finish", verdict: BOOLEAN]  
        \union
    {NoEvent}      

(* Produce a request event for the top element of the requestStack *)
RequestHeaderForTopRequest(stack) ==
    IF stack = <<>>
    THEN NoEvent
    ELSE  LET top == Head(stack)
              heightToRequest ==
                IF top.isLeft
                THEN top.endHeight      \* the pivot is on the right
                ELSE top.startHeight    \* the pivot is on the left
          IN
          [type |-> "requestHeader", height |-> heightToRequest]

(* When starting the light client *)
OnStart ==
    /\ state = "init"
    /\ inEvent.type = "start"
    /\ state' = "working"
        (* the block at trusted height is obtained by the user *)
    /\ storedHeaders' = { << blockchain[TRUSTED_HEIGHT],
                             DOMAIN blockchain[TRUSTED_HEIGHT].VP >> }
        (* The only request on the stack ("right", h1, h2).
           It is labelled as `right` to disable short-circuiting *)
    /\ LET initStack == << [isLeft |-> TRUE,
                           startHeight |-> TRUSTED_HEIGHT,
                           endHeight |-> inEvent.heightToVerify] >>
       IN           
        /\ requestStack' = initStack
        /\ outEvent' = RequestHeaderForTopRequest(initStack)

(* Check whether we can trust the signedHdr based on trustedHdr
   following the trusting period method.
   This operator is similar to CheckSupport in the English spec.
   
   The parameters have the following meanings:
   - heightToTrust is the height of the trusted header
   - heightToVerify is the height of the header to be verified
   - trustedHdr is the trusted header (not a signed header)
   - signedHdr is the signed header to verify (including commits)
   *)
CheckSupport(heightToTrust, heightToVerify, trustedHdr, signedHdr) ==
    IF minTrustedHeight > heightToTrust \* outside of the trusting period
        \/ ~(signedHdr[2] \subseteq (DOMAIN signedHdr[1].VP)) \* signed by other nodes
    THEN FALSE
    ELSE
      LET TP == BC!PowerOfSet(trustedHdr.NextVP, DOMAIN trustedHdr.NextVP)
          SP == BC!PowerOfSet(trustedHdr.NextVP,
            signedHdr[2] \intersect DOMAIN trustedHdr.NextVP)
      IN
      IF heightToVerify = heightToTrust + 1
          \* the special case of adjacent heights: check 2/3s
      THEN (3 * SP > 2 * TP)
      ELSE \* the general case: check 1/3 between the headers and make sure there are 2/3 votes  
        LET TPV == BC!PowerOfSet(signedHdr[1].VP, DOMAIN signedHdr[1].VP)
            SPV == BC!PowerOfSet(signedHdr[1].VP, signedHdr[2])
        IN
        (3 * SP > TP) /\ (3 * SPV > 2 * TPV)

(* Make one step of bisection, roughly one stack frame of Bisection in the English spec *)
OneStepOfBisection(storedHdrs) ==
    LET topReq == Head(requestStack)
        lh == topReq.startHeight
        rh == topReq.endHeight
        lhdr == CHOOSE hdr \in storedHdrs: hdr[1].height = lh
        rhdr == CHOOSE hdr \in storedHdrs: hdr[1].height = rh
    IN
    \* pass only the header lhdr[1] and signed header rhdr
    IF CheckSupport(lh, rh, lhdr[1], rhdr)
        (* The header can be trusted, pop the request and return true *)
    THEN <<TRUE, Tail(requestStack)>>
    ELSE IF lh + 1 = rh \* sequential verification
        THEN (*
             Sequential verification tells us that the header cannot be trusted:
             If the search request was scheduled as a left branch, then
             (1) pop the top request (the left branch), and
             (2) pop the second top request, which is the request for the right branch.
             Otherwise, pop only the top request.
             This is the optimization that is introduced in the English spec.
             One can replace it e.g. with a parallel search.
             *)
            LET howManyToPop == IF topReq.isLeft THEN 2 ELSE 1 IN  
            <<FALSE, SubSeq(requestStack, 1 + howManyToPop, Len(requestStack))>>
        ELSE (*
             Dichotomy: schedule search requests for the left and right branches
             (and pop the top element off the stack).
             In contrast to the English spec, these requests are not processed immediately,
             but one-by-one in a depth-first order (mind the optimization above).
             *)
            LET rightReq == [isLeft |-> FALSE, startHeight |-> (lh + rh) \div 2, endHeight |-> rh]
                leftReq ==  [isLeft |-> TRUE, startHeight |-> lh, endHeight |-> (lh + rh) \div 2]
            IN
            <<TRUE, <<leftReq, rightReq>> \o Tail(requestStack)>>

OnResponseHeader ==
  /\ state = "working"
  /\ inEvent.type = "responseHeader"
  /\ storedHeaders' = storedHeaders \union { inEvent.hdr }
  /\ LET res == OneStepOfBisection(storedHeaders')
         verdict == res[1]
         newStack == res[2]
     IN
      /\ requestStack' = newStack
      /\ IF newStack = << >>
         THEN /\ outEvent' = [type |-> "finished", verdict |-> verdict]
              /\ state' = "finished"
         ELSE /\ outEvent' = RequestHeaderForTopRequest(newStack)
              /\ state' = "working"  

LCInit ==
    /\ state = "init"
    /\ outEvent = NoEvent
    /\ requestStack = <<>>
    /\ storedHeaders = {}

LCNext ==
  OnStart \/ OnResponseHeader
            
            
(********************* Lite client + Environment + Blockchain *******************)
Init == BC!Init /\ EnvInit /\ LCInit

Next ==
  \/ LCNext  /\ UNCHANGED bcvars /\ UNCHANGED envvars
  \/ EnvNext /\ UNCHANGED bcvars /\ UNCHANGED lcvars
  \/ BC!Next /\ UNCHANGED lcvars /\ UNCHANGED envvars


(* The properties to check *)
\* check this property to get an example of a terminating light client
NeverStart == state /= "working"

NeverFinish == state /= "finished"


\* Correctness states that all the obtained headers are exactly like in the blockchain
Correctness ==
    outEvent.type = "finished" /\ outEvent.verdict = TRUE
        => (\A hdr \in storedHeaders: hdr[1] = blockchain[hdr[1].height])

Precision ==
    outEvent.type = "finished" /\ outEvent.verdict = FALSE
        => (\E hdr \in storedHeaders: hdr[1] /= blockchain[hdr[1].height])

\* TODO: specify Completeness and Accuracy from the English spec

(************************** MODEL CHECKING ************************************)
(*
  # Experiment 1.
  Run TLC with the following parameters:
  
  ULTIMATE_HEIGHT <- 3,
  MAX_POWER <- 1,
  TO_VERIFY_HEIGHT <- 3,
  TRUSTED_HEIGHT <- 1,
  AllNodes <- { A_p1, A_p2, A_p3, A_p4 } \* choose symmetry reduction for model values
  
  Did not finish after 2:30 hours (> 5.3M states):
  
   * Deadlocks: a deadlock occurs when minTrustedHeight > height.
   * Correctness: ???
   * Precision: ???
 *)

=============================================================================
\* Modification History
\* Last modified Wed Oct 23 08:56:35 CEST 2019 by igor
\* Created Wed Oct 02 16:39:42 CEST 2019 by igor
