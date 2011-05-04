
Require Export SubstValueValue.
Require Import Preservation.
Require Import TyJudge.
Require Export EsJudge.
Require Export Exp.


(* Big Step Evaluation **********************************************
   This is also called 'Natural Semantics'.
 *)
Inductive EVAL : exp -> exp -> Prop :=
 | EVDone
   :  forall v2
   ,  whnfX  v2
   -> EVAL   v2 v2

 | EVLamApp
   :  forall x1 t11 x12 x2 v2 v3
   ,  EVAL x1 (XLam t11 x12) -> EVAL x2 v2 -> EVAL (subst v2 x12) v3
   -> EVAL (XApp x1 x2) v3.

Hint Constructors EVAL.


(* A terminating big-step evaluation always produces a whnf.
   The fact that the evaluation has terminated is implied by the fact
   that we have a proof of EVAL to pass to this lemma. If the
   evaluation was non-terminating, then we wouldn't have a finite
   proof of EVAL.
 *)
Lemma eval_produces_whnfX
 :  forall x1 v1
 ,  EVAL   x1 v1
 -> whnfX  v1.
Proof.
 intros. induction H; eauto.
Qed.
Hint Resolve eval_produces_whnfX.


(* Big to Small steps ***********************************************)
Lemma eval_to_steps
 :  forall x1 t1 x2
 ,  TYPE Empty x1 t1
 -> EVAL x1 x2
 -> STEPS x1 x2.
Proof.
 intros x1 t1 v2 HT HE. gen t1.
 induction HE.
 Case "EVDone".
  intros. apply ESNone.

 Case "EVLamApp".
  intros. inverts HT.

  lets E1: IHHE1 H2. 
  lets E2: IHHE2 H4.

  lets T1: preservation_steps H2 E1. inverts keep T1.
  lets T2: preservation_steps H4 E2.
  lets T3: subst_value_value H1 T2.
  lets E3: IHHE3 T3.

  eapply ESAppend.
    eapply steps_app1. eauto.
   eapply ESAppend.
    eapply steps_app2. eauto. eauto.
   eapply ESAppend.
    eapply ESStep.
     eapply ESLamApp. eauto.
   eauto.      
Qed.


(* Small to Big steps ***********************************************)
Lemma expansion
 :  forall te x1 t1 x2 v3
 ,  TYPE te x1 t1
 -> STEP x1 x2 -> EVAL x2 v3 
 -> EVAL x1 v3.
Proof.
 intros. gen te t1 v3.
 induction H0; intros.

 eapply EVLamApp.
  eauto.
  inverts H. 
  apply EVDone. auto. auto.
 
 Case "x1 steps".
  inverts H. inverts H1.
   inverts H.
   eapply EVLamApp; eauto.

 Case "x2 steps".
  inverts H1. inverts H2.
  inverts H1.
  eapply EVLamApp; eauto.
Qed.


Lemma stepsl_to_eval
 :  forall x1 t1 v2
 ,  TYPE Empty x1 t1
 -> STEPSL x1 v2 -> value v2
 -> EVAL   x1 v2.
Proof.
 intros.
 induction H0.
 
 Case "ESLNone".
   apply EVDone. inverts H1. auto.

 Case "ESLCons".
  eapply expansion. 
   eauto. eauto. 
   apply IHSTEPSL.
   eapply preservation. eauto. auto. auto.
Qed.

