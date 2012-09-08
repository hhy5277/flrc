(* COPYRIGHT_NOTICE_1 *)
(*
 * Module that aims to implement things defined in GHC.Prim.
 *
 * Primitive functions are converted directly into Mil codeblocks.
 *
 * NOTE: we must keep the same word size as GHC. Because GHC for
 * Windows is only 32-bit and we are using 32-bit Mlton on all
 * platforms too, so we set a fixed 32-bit word size for now.
 *
 *)
signature GHC_PRIM =
sig

  type state = HsToMilUtils.state
  type var   = Mil.variable
  type argsAndTyps = (Mil.simple * Mil.typ) list 
  type block = HsToMilUtils.MS.t

  val pkgName : string

  val tagTyp       : Config.wordSize -> Mil.typ
  val tagArbTyp    : Config.wordSize -> IntArb.typ
  val intArbTyp    : Config.wordSize -> IntArb.typ
  val wordArbTyp   : Config.wordSize -> IntArb.typ
  val intTyp       : Config.wordSize -> Mil.typ
  val wordTyp      : Config.wordSize -> Mil.typ
  val floatTyp     : Mil.typ
  val doubleTyp    : Mil.typ
  val floatNumTyp  : Mil.Prims.numericTyp
  val doubleNumTyp : Mil.Prims.numericTyp

  val exnHandlerTyp : Mil.typ
  val wrapThread    : state * block -> block
  val setHandler    : state * Mil.operand -> block
  
  val tagToConst  : Config.wordSize * Int.t -> Mil.constant
  val castLiteral : Config.wordSize -> CoreHs.coreLit * 'a GHCPrimType.primTy -> Mil.constant * Mil.typ 

  val primToMilTy : Config.wordSize * ('a -> Mil.typ) -> 'a GHCPrimType.primTy -> Mil.typ
  val primOp      : state * GHCPrimOp.primOp * var Vector.t * argsAndTyps -> block * Mil.effects

  val arith : Mil.Prims.numericTyp * Mil.Prims.arithOp -> argsAndTyps -> Mil.rhs

  val externDo0 : Mil.effects -> string -> state * argsAndTyps -> block * Mil.effects

  val initStableRoot   : Mil.symbolTableManager * Config.t -> var * Mil.global

end 

structure GHCPrim : GHC_PRIM =
struct

  structure SD = StringDict
  structure I = Identifier
  structure VD = I.VariableDict
  structure VS = I.VariableSet
  structure LS = I.LabelSet
  structure IM = I.Manager
  structure CH = CoreHs
  structure M  = Mil
  structure MP = M.Prims
  structure FK = MilUtils.FieldKind
  structure FS = MilUtils.FieldSize
  structure MUP = MilUtils.Prims
  structure TMU = HsToMilUtils
  structure MS = TMU.MS
  structure MU = TMU.MU

  open GHCPrimType
  open GHCPrimOp

  fun failMsg (f, s) = Fail.fail ("GHCPrim", f, s)
  fun assertSingleton (f, rvar) = 
      let
        val () = if Vector.length rvar <> 1 then failMsg (f, "expect only one return value") else ()
      in
        Vector.sub (rvar, 0)
      end

  type state = HsToMilUtils.state
  type var   = Mil.variable
  type argsAndTyps = (Mil.simple * Mil.typ) list 
  type block = HsToMilUtils.MS.t

  val pkgName = "plsr-prims-ghc"
  (* mil types *)
  val boolTyp      = M.TBoolean
  val int64ArbTyp  = IntArb.T (IntArb.S64, IntArb.Signed)
  val int32ArbTyp  = IntArb.T (IntArb.S32, IntArb.Signed)
  val int16ArbTyp  = IntArb.T (IntArb.S16, IntArb.Signed)
  val int8ArbTyp   = IntArb.T (IntArb.S8, IntArb.Signed)
  val word64ArbTyp = IntArb.T (IntArb.S64, IntArb.Unsigned)
  val word32ArbTyp = IntArb.T (IntArb.S32, IntArb.Unsigned)
  val word16ArbTyp = IntArb.T (IntArb.S16, IntArb.Unsigned)
  val word8ArbTyp  = IntArb.T (IntArb.S8, IntArb.Unsigned)
  val byteArbTyp   = word8ArbTyp
  val charArbTyp   = word32ArbTyp
  val intArbTyp    = fn ws => case ws of Config.Ws32 => int32ArbTyp  | Config.Ws64 => int64ArbTyp 
  val wordArbTyp   = fn ws => case ws of Config.Ws32 => word32ArbTyp | Config.Ws64 => word64ArbTyp 
  val int64Typ     = MUP.NumericTyp.tIntegerFixed int64ArbTyp
  val int32Typ     = MUP.NumericTyp.tIntegerFixed int32ArbTyp
  val int16Typ     = MUP.NumericTyp.tIntegerFixed int16ArbTyp
  val int8Typ      = MUP.NumericTyp.tIntegerFixed int8ArbTyp
  val word64Typ    = MUP.NumericTyp.tIntegerFixed word64ArbTyp
  val word32Typ    = MUP.NumericTyp.tIntegerFixed word32ArbTyp
  val word16Typ    = MUP.NumericTyp.tIntegerFixed word16ArbTyp
  val word8Typ     = MUP.NumericTyp.tIntegerFixed word8ArbTyp
  val byteTyp      = MUP.NumericTyp.tIntegerFixed byteArbTyp
  val charTyp      = MUP.NumericTyp.tIntegerFixed charArbTyp
  val intTyp       = MUP.NumericTyp.tIntegerFixed o intArbTyp
  val wordTyp      = MUP.NumericTyp.tIntegerFixed o wordArbTyp
  val integerTyp   = MUP.NumericTyp.tIntegerArbitrary
  val floatTyp     = MUP.NumericTyp.tFloat
  val doubleTyp    = MUP.NumericTyp.tDouble
  val addrTyp      = M.TNonRefPtr
  val refTyp       = M.TRef
  val indexTyp     = wordTyp
  val indexArbTyp  = wordArbTyp
  val tagTyp       = wordTyp
  val tagArbTyp    = wordArbTyp

  (* field descriptor functions *)
  (* NOTE: for now, all arrays are created with a default alignment of its value type *)
  fun alignment (cfg, ty) =
      case MilUtils.Typ.valueSize (cfg, ty)
        of SOME size => size
         | NONE => failMsg("alignment", "cannot guess alignment for given type")
  fun immutableFD ty cfg = M.FD { kind = FK.fromTyp (cfg, ty), alignment = alignment (cfg, ty), var = M.FvReadOnly }
  fun mutableFD   ty cfg = M.FD { kind = FK.fromTyp (cfg, ty), alignment = alignment (cfg, ty), var = M.FvReadWrite }
  fun indexFD cfg     = immutableFD (indexTyp (Config.targetWordSize cfg)) cfg
  val immutableByteFD = immutableFD byteTyp
  val mutableRefFD    = mutableFD  M.TRef
  val immutableRefFD  = immutableFD  M.TRef
  val mutableByteFD   = mutableFD  byteTyp

  (* type and field variance functions *)
  fun immutableTF ty  = (ty, M.Vs8, M.FvReadOnly)
  fun mutableTF   ty  = (ty, M.Vs8, M.FvReadWrite)
  val indexTF         = immutableTF o indexTyp
  val immutableRefTF  = immutableTF M.TRef
  val immutableByteTF = immutableTF byteTyp
  val noneTF          = immutableTF M.TNone
  val mutableRefTF    = mutableTF M.TRef
  val mutableByteTF   = mutableTF byteTyp

  val mutVarTyp         = M.TTuple { pok = M.PokNone, fixed = Vector.new1 mutableRefTF, array = noneTF }
  val mVarTyp           = M.TTuple { pok = M.PokNone, fixed = Vector.new1 mutableRefTF, array = noneTF }
  val immutVarTyp       = M.TTuple { pok = M.PokNone, fixed = Vector.new1 immutableRefTF, array = noneTF }
  (* we use mutable Mil arrays for Array and ByteArray even when they are to be immutable in Haskell *)
  fun arrayTyp ws     = M.TTuple { pok = M.PokNone, fixed = Vector.new1 (indexTF ws), array = mutableRefTF }
  fun immutableArrayTyp (ws, t) = M.TTuple {pok = M.PokNone, fixed = Vector.new1 (indexTF ws), array = immutableTF t}
  fun byteArrayTyp ws = M.TTuple { pok = M.PokNone, fixed = Vector.new1 (indexTF ws), array = mutableByteTF }
  fun mutableArrayTyp ws typ = M.TTuple { pok = M.PokNone, fixed = Vector.new1 (indexTF ws), array = mutableTF typ }

  val threadIdTyp = M.TRef

  (* stableRoot and stablePtr *)
  val stableBoxTV =
      let
        val tvPtr = (M.TRef, M.Vs8, M.FvReadWrite)
        val tvVal = (M.TRef, M.Vs8, M.FvReadOnly)
      in
        Vector.new3 (tvPtr, tvVal, tvPtr)
      end

  val stableBoxFD =
      let
        val tvPtr = M.FD { kind = M.FkRef, alignment = M.Vs8, var = M.FvReadWrite }
        val tvVal = M.FD { kind = M.FkRef, alignment = M.Vs8, var = M.FvReadOnly }
      in
        Vector.new3 (tvPtr, tvVal, tvPtr)
      end
  
  val weakPtrTyp = M.TRef (* use non-reference pointer? *)

  val stableBoxTD = M.TD { fixed = stableBoxFD, array = NONE }
  val stableBoxTyp = M.TTuple { pok = M.PokNone, fixed = stableBoxTV, array = noneTF }
  val stablePtrTyp = M.TNonRefPtr (* use non-reference pointer because we don't want it to be traced by GC *)


  val stableRootTV = Vector.new1 (M.TRef, M.Vs8, M.FvReadWrite)
  val stableRootFD = Vector.new1 (M.FD { kind = M.FkRef, alignment = M.Vs8, var = M.FvReadWrite })
  val stableRootTD = M.TD { fixed = stableRootFD, array = NONE }
  val stableRootTyp = M.TTuple { pok = M.PokNone, fixed = stableRootTV, array = noneTF }


  (* number precisions *)
  val integerPrec  = MP.IpArbitrary
  val intPrec      = MP.IpFixed o intArbTyp
  val int8Prec     = MP.IpFixed   int8ArbTyp
  val int16Prec    = MP.IpFixed   int16ArbTyp
  val int32Prec    = MP.IpFixed   int32ArbTyp
  val int64Prec    = MP.IpFixed   int64ArbTyp
  val wordPrec     = MP.IpFixed o wordArbTyp
  val word8Prec    = MP.IpFixed   word8ArbTyp
  val word16Prec   = MP.IpFixed   word16ArbTyp
  val word32Prec   = MP.IpFixed   word32ArbTyp
  val word64Prec   = MP.IpFixed   word64ArbTyp
  val charPrec     = MP.IpFixed   charArbTyp
  val bytePrec     = MP.IpFixed   word8ArbTyp
  val doublePrec   = MP.FpDouble
  val floatPrec    = MP.FpSingle

  val integerNumTyp = MP.NtInteger integerPrec
  val intNumTyp     = MP.NtInteger o intPrec
  val int8NumTyp    = MP.NtInteger int8Prec
  val int16NumTyp   = MP.NtInteger int16Prec
  val int32NumTyp   = MP.NtInteger int32Prec
  val int64NumTyp   = MP.NtInteger int64Prec
  val wordNumTyp    = MP.NtInteger o wordPrec
  val word8NumTyp   = MP.NtInteger word8Prec
  val word16NumTyp  = MP.NtInteger word16Prec
  val word32NumTyp  = MP.NtInteger word32Prec
  val word64NumTyp  = MP.NtInteger word64Prec
  val charNumTyp    = MP.NtInteger charPrec
  val byteNumTyp    = MP.NtInteger bytePrec
  val doubleNumTyp  = MP.NtFloat   doublePrec
  val floatNumTyp   = MP.NtFloat   floatPrec
  val tagNumTyp     = wordNumTyp

  (* Take a type to it's unboxed type.
   * Expects a thunk of a sum of a single type; returns that type.
   *)
  fun unboxedType typ =
      case typ
       of M.TThunk (M.TSum {arms, ...}) =>
          if Vector.length arms = 1
          then
            let
              val (_, vtyps) = Vector.sub (arms, 0)
            in
              if Vector.length vtyps = 1
              then Vector.sub (vtyps, 0)
              else failMsg("unboxedType", "type must be a thunk of sum of a single type")
            end
          else failMsg("unboxedType", "type must be a thunk of sum of a single arm")
        | _ => failMsg("unboxedType", "type must be a thunk of sum type")

  fun tagToConst (ws, i) = TMU.constInt (i, SOME (tagArbTyp ws))
  fun defaultTag ws = tagToConst (ws, 0)

  fun primToMilTy (ws, toMilTy)
    = fn Int                    => intTyp ws
      |  Int64                  => int64Typ
      |  Integer                => integerTyp
      |  Bool                   => boolTyp
      |  Char                   => charTyp
      |  Word                   => wordTyp ws
      |  Word64                 => word64Typ
      |  Addr                   => addrTyp
      |  Float                  => floatTyp
      |  Double                 => doubleTyp
      |  ByteArray              => byteArrayTyp ws
      |  MutableByteArray _     => mutableArrayTyp ws byteTyp
      |  ThreadId               => threadIdTyp
      |  MutVar _               => mutVarTyp
      |  MVar _                 => mVarTyp
      |  Array _                => arrayTyp ws
      |  ImmutableArray _       => immutableArrayTyp (ws, M.TRef)
      |  StrictImmutableArray _ => immutableArrayTyp (ws, M.TRef)
      |  UnboxedWordArray       => immutableArrayTyp (ws, wordTyp ws)
      |  UnboxedWord8Array      => immutableArrayTyp (ws, word8Typ)
      |  UnboxedWord16Array     => immutableArrayTyp (ws, word16Typ)
      |  UnboxedWord32Array     => immutableArrayTyp (ws, word32Typ)
      |  UnboxedWord64Array     => immutableArrayTyp (ws, word64Typ)
      |  UnboxedIntArray        => immutableArrayTyp (ws, intTyp ws)
      |  UnboxedInt8Array       => immutableArrayTyp (ws, int8Typ)
      |  UnboxedInt16Array      => immutableArrayTyp (ws, int16Typ)
      |  UnboxedInt32Array      => immutableArrayTyp (ws, int32Typ)
      |  UnboxedInt64Array      => immutableArrayTyp (ws, int64Typ)
      |  UnboxedFloatArray      => immutableArrayTyp (ws, floatTyp)
      |  UnboxedDoubleArray     => immutableArrayTyp (ws, doubleTyp)
      |  UnboxedCharArray       => immutableArrayTyp (ws, charTyp)
      |  UnboxedAddrArray       => immutableArrayTyp (ws, addrTyp)
      |  MutableArray _         => mutableArrayTyp ws refTyp
      |  WeakPtr _              => weakPtrTyp
      |  StablePtr _            => stablePtrTyp
      |  (Tuple _)              => failMsg ("primToMilTy", "Got unboxed tuple type")
(*      |  (Tuple [])              => M.TNone           (* unboxed tuple of () *)
      (* 
       * NOTE: The following tuple conversion is only used by ToMil, 
       *       and only when multiReturn is enabled.
       *)
      |  (Tuple tys)            => 
        let (* use default alignment, which is Vs8 *)
           val fixed = Vector.fromListMap (tys, fn ty => (toMilTy ty, M.Vs8, M.FvReadOnly))
        in
           M.TTuple { pok = M.PokNone, fixed = fixed, array = noneTF }
        end*)
      |  _                      => M.TRef

  fun castLiteral ws =
    fn (CH.Lint i, Int)    => (M.CIntegral (IntArb.fromIntInf (intArbTyp ws, i)), intTyp ws)
     | (CH.Lint i, Int64)  => (M.CIntegral (IntArb.fromIntInf (int64ArbTyp, i)), int64Typ)
     | (CH.Lint i, Char)   => (M.CIntegral (IntArb.fromIntInf (charArbTyp, i)), charTyp)
     | (CH.Lint i, Word)   => (M.CIntegral (IntArb.fromIntInf (wordArbTyp ws, i)), wordTyp ws)
     | (CH.Lint i, Word64) => (M.CIntegral (IntArb.fromIntInf (word64ArbTyp, i)), word64Typ)
     | (CH.Lint i, Integer)=> (M.CInteger i, integerTyp)
     | (CH.Lint i, Float)  => (M.CFloat  (Real32.fromIntInf i), floatTyp)
     | (CH.Lint i, Double) => (M.CDouble (Real64.fromIntInf i), doubleTyp)
     | (CH.Lrational r, Float)  => (M.CFloat  (Rat.toReal32 r), floatTyp)
     | (CH.Lrational r, Double) => (M.CDouble (Rat.toReal64 r), doubleTyp)
     | (CH.Lchar i, Int)    => (M.CIntegral (IntArb.fromInt (intArbTyp ws, i)), intTyp ws)
     | (CH.Lchar i, Int64)  => (M.CIntegral (IntArb.fromInt (int64ArbTyp, i)), int64Typ)
     | (CH.Lchar i, Char)   => (M.CIntegral (IntArb.fromInt (charArbTyp, i)), charTyp)
     | (CH.Lchar i, Word)   => (M.CIntegral (IntArb.fromInt (wordArbTyp ws, i)), wordTyp ws)
     | (CH.Lchar i, Word64) => (M.CIntegral (IntArb.fromInt (word64ArbTyp, i)), word64Typ)
     | (CH.Lchar i, Integer) => (M.CInteger (IntInf.fromInt i), integerTyp)
     | (CH.Lint  i, Addr)   => (M.CIntegral (IntArb.fromIntInf (intArbTyp ws, i)), addrTyp)
     | (l, ty) => failMsg("castLiteral", "cannot cast literal " ^
                    Layout.toString (CoreHsLayout.layoutCoreLit l) ^ " to prim type " ^
                    Layout.toString (GHCPrimTypeLayout.layoutPrimTy (fn _ => Layout.str "%data") ty))

  fun identity l =
      let
        val (arg, _) = List.first l
      in
        M.RhsSimple arg
      end

  fun identityWithTy (cfg, l) =
      let
        val (arg, ty) = List.first l
      in
        (M.RhsSimple arg, ty)
      end

  fun rhsPrim p argstyps =
      let
        val (args, typs) = List.unzip argstyps
      in
        (* no types for Mil primitives since they are monomorphic *)
        M.RhsPrim { prim = p, createThunks = false, typs = Vector.new0 (), args = Vector.fromList args }
      end

  fun arith   (ty, opr) = rhsPrim (MP.Prim (MP.PNumArith   { typ = ty,   operator = opr}))
  fun floatOp (ty, opr) = rhsPrim (MP.Prim (MP.PFloatOp    { typ = ty,   operator = opr}))
  fun compare (ty, opr) = rhsPrim (MP.Prim (MP.PNumCompare { typ = ty,   operator = opr}))
  fun bitwise (ty, opr) = rhsPrim (MP.Prim (MP.PBitwise    { typ = ty,   operator = opr}))
  fun convert (frm, to) = rhsPrim (MP.Prim (MP.PNumConvert { from = frm, to = to }))
  fun cast (frm, to) = rhsPrim (MP.Prim (MP.PNumCast { from = frm, to = to }))
  fun bitwiseWith (ty, opr, operand) argstyps 
    = rhsPrim (MP.Prim (MP.PBitwise    { typ = ty,   operator = opr})) (argstyps @ [operand])

  (* wrap M.TBool in a sum type *)
  fun wrapBool (state, rvar, bval) =
      let
        val {im, cfg, ...} = state
        val rvar = assertSingleton ("wrapBool", rvar)
        val tagTrue  = 1 (* hard coded tag value *)
        val tagFalse = 0 (* hard coded tag value *)
        val ws = Config.targetWordSize cfg
        val rtyp  = TMU.variableTyp (im, rvar)
        val fkind = FK.fromTyp (cfg, rtyp)
        val uvar = IM.variableClone (im, rvar)
        val vvar = IM.variableClone (im, rvar)
        fun blk1 (lt, lf) = 
          ( MS.empty
          , M.TCase { select = M.SeConstant
                    , on = bval
                    , cases = Vector.new2 ( (M.CBoolean true,  M.T { block = lt, arguments = Vector.new0 () })
                                          , (M.CBoolean false, M.T { block = lf, arguments = Vector.new0 () }))
                    , default = NONE })
        val blk2 = MS.bindRhs (uvar, M.RhsSum { tag = tagToConst (ws, tagTrue)
                                              , typs = Vector.new0 ()
                                              , ofVals = Vector.new0 () })
        val blk3 = MS.bindRhs (vvar, M.RhsSum { tag = tagToConst (ws, tagFalse)
                                              , typs = Vector.new0 ()
                                              , ofVals = Vector.new0 () })
        val blk' = MU.join (im, cfg, blk1, 
                       (blk2, Vector.new1 (M.SVariable uvar)),
                       (blk3, Vector.new1 (M.SVariable vvar)), Vector.new1 rvar)
      in
        blk'
      end

  fun single ((state : TMU.state, rvar), rhs) = MS.bindsRhs (rvar, rhs)

  (* a variant of single that wraps primitive boolean into sum *)
  fun singleB ((state : TMU.state, rvar), rhs) =
      let
        val { im, cfg, ... } = state
        val bvar = TMU.localVariableFresh0 (im, boolTyp)
        val blk0 = MS.bindRhs (bvar, rhs)
        val blk1 = wrapBool (state, rvar, M.SVariable bvar)
      in
        MS.seq (blk0, blk1)
      end

  fun tupleSimple ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val ws = Config.targetWordSize cfg
        val () = if Vector.length rvar = List.length argstyps then ()
                 else failMsg ("tupleSimple", "expect " ^ Int.toString (Vector.length rvar) ^ 
                                              " return value, but got " ^ Int.toString (List.length argstyps))
        val blks = List.map (List.zip (Vector.toList rvar, argstyps),
                          fn (u, (arg, _)) => MS.bindRhs (u, M.RhsSimple arg))
      in
        MS.seqn blks
      end

  fun tupleRhs ((state, rvar), rhstyps) =
      let
        val { im, cfg, ... } = state
        val (rhss, typs) = List.unzip rhstyps
        val vars = List.map (typs, fn typ => TMU.localVariableFresh0 (im, typ))
        val blks = List.map (List.zip (vars, rhss), fn (var, rhs) => MS.bindRhs (var, rhs))
        val argstyps = List.zip (List.map (vars, M.SVariable), typs)
        val blk = tupleSimple ((state, rvar), argstyps)
      in
        MS.seqn (blks @ [blk])
      end

  (* We do not use multi-return for extern calls; 
   * externs always return a sum for multi-return values *)
  fun extern fx fname ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val ws = Config.targetWordSize cfg
        val (args, typs) = List.unzip argstyps
      in
        if Vector.length rvar = 1 
          then 
            let
              val rtyp = Vector.map (rvar, fn v => TMU.variableTyp (im, v))
              val (fvar, _) = TMU.externVariable (state, pkgName, fname,
                          fn () => M.TCode { cc = M.CcCode, args = Vector.fromList typs, ress = rtyp })
            in
              (MU.call (im, cfg, M.CCode { ptr = fvar, code = TMU.noCode },
                           Vector.fromList args, TMU.noCut, fx, rvar), fx)
            end
          else
            let 
              val rtyps = Vector.map (rvar, fn v => TMU.variableTyp (im, v))
              val fks   = Vector.map (rtyps, fn t => FK.fromTyp (cfg, t))
              val rtyp0 = M.TSum { tag = tagTyp ws
                                 , arms = Vector.new1 (defaultTag ws, rtyps) }
              val rvar0 = TMU.localVariableFresh0 (im, rtyp0)
              val (fvar, _) = TMU.externVariable (state, pkgName, fname,
                          fn () => M.TCode { cc = M.CcCode, args = Vector.fromList typs, ress = Vector.new1 rtyp0 })
              val blk = MU.call (im, cfg, M.CCode { ptr = fvar, code = TMU.noCode },
                           Vector.fromList args, TMU.noCut, fx, Vector.new1 rvar0)
              fun sub (i, v, blk) = MS.seq (blk, MS.bindRhs (v, 
                                      M.RhsSumProj { typs = fks, sum = rvar0, tag = defaultTag ws, idx = i }))
              val blk = Vector.foldi (rvar, blk, sub)
            in
              (blk, fx)
            end
      end

  fun externB fx fname ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val (args, typs) = List.unzip argstyps
        val bvar = TMU.localVariableFresh0 (im, boolTyp)
        val (fvar, _) = TMU.externVariable (state, pkgName, fname,
                          fn () => M.TCode { cc = M.CcCode, args = Vector.fromList typs, ress = Vector.new1 boolTyp })
        val blk0 = MU.call (im, cfg, M.CCode { ptr = fvar, code = TMU.noCode },
                           Vector.fromList args, TMU.noCut, fx, Vector.new1 bvar)
        val blk1 = wrapBool (state, rvar, M.SVariable bvar)
      in
        (MS.seq (blk0, blk1), fx)
      end

  fun externDo0 fx fname (state, argstyps) =
      let
        val { im, cfg, ... } = state
        val (args, typs) = List.unzip argstyps
        val (fvar, _) = TMU.externVariable (state, pkgName, fname,
                          fn () => M.TCode { cc = M.CcCode, args = Vector.fromList typs, ress = Vector.new0 () })
      in
        (MU.call (im, cfg, M.CCode { ptr = fvar, code = TMU.noCode },
                           Vector.fromList args, TMU.noCut, fx, Vector.new0 ()), fx)
      end

  fun externDo fx fname ((state, rvar), argstyps) = externDo0 fx fname (state, argstyps)

  fun externWithState fx (fname, utyp) ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val (argstyps, (v, vtyp)) = List.splitLast argstyps
        val uvar = TMU.localVariableFresh0 (im, utyp)
        val (blk1, _) = extern fx fname ((state, Vector.new1 uvar), argstyps)
        val rhstyps = [(M.RhsSimple v, vtyp), (M.RhsSimple (M.SVariable uvar), utyp)]
        val blk2 = tupleRhs ((state, rvar), rhstyps)
      in
        (MS.seq (blk1, blk2), fx)
      end

  fun externWithStateDo fx fname ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val (argstyps, (v, vtyp)) = List.splitLast argstyps
        val (blk1, _) = externDo0 fx fname (state, argstyps)
        val blk2 = MS.bindsRhs (rvar, M.RhsSimple v)
      in
        (MS.seq (blk1, blk2), fx)
      end

  fun narrow (fromTyp, toTyp) ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(ival, ityp)] =>
          let
            val toT = M.TNumeric toTyp
            val nvar = TMU.localVariableFresh0 (im, toT)
            val blk1 = MS.bindRhs (nvar, cast (fromTyp, toTyp) [(ival, ityp)])
            val blk2 = MS.bindsRhs (rvar, cast (toTyp, fromTyp) [(M.SVariable nvar, toT)])
            val blk = MS.seq (blk1, blk2)
          in blk
          end 
        | _ => failMsg("narrow", "argument number mismatch")

  fun withCast (fromMP, toMP, typ, toRhs) ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val (v, vty) = List.first argstyps
        val rhs0 = cast (fromMP, toMP) [(v, vty)]
        val u = TMU.localVariableFresh0 (im, typ)
        val blk0 = MS.bindRhs (u, rhs0)
        val argstyps = (M.SVariable u, typ) :: (tl argstyps)
        val rhs1 = toRhs argstyps
        val w = TMU.localVariableFresh0 (im, typ)
        val blk1 = MS.bindRhs (w, rhs1)
        val rhs2 = cast (toMP, fromMP) [(M.SVariable w, typ)]
        val blk2 = MS.bindsRhs (rvar, rhs2)
      in
        MS.seqn [blk0, blk1, blk2]
      end

      (*
  fun castAfter (fromMP, typ, toMP, toRhs) ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val (v, vty) = List.first argstyps
        val rhs0 = toRhs argstyps
        val u = TMU.localVariableFresh0 (im, typ)
        val blk0 = MS.bindRhs (im, cfg, u, rhs0)
        val argstyps = (M.SVariable u, typ) :: (tl argstyps)
        val rhs1 = cast (fromMP, toMP) [(M.SVariable u, vty)]
        val blk1 = MS.bindRhs (im, cfg, rvar, rhs1)
      in
        MS.seqn (im, cfg, [blk0, blk1])
      end
      *)

  fun withoutState toRhsAndTy ((state, rvar), argstyps) =
      let
        val { cfg, ... } = state
      in
        single ((state, rvar), #1 (toRhsAndTy (cfg, argstyps)))
      end

  (* specifically for indexArrayzh *)
  fun withoutState' toBlk ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val u = TMU.localVariableFresh0 (im, M.TRef)
        val blk0 = toBlk ((state, Vector.new1 u), argstyps)
        val blk1 = tupleSimple ((state, rvar), [(M.SVariable u, M.TRef)])
      in
        MS.seq (blk0, blk1)
      end

  fun withState toRhsAndTy ((state : TMU.state, rvar), argstyps) =
      let
        val { cfg, ... } = state
        val (argstyps, (v, t)) = List.splitLast argstyps
        val (rhs, ty) = toRhsAndTy (cfg, argstyps)
      in
        tupleRhs ((state, rvar), (M.RhsSimple v, t) :: [(rhs, ty)]) 
      end

  fun withStateAndTy (toRhs, ty) = withState (fn x => (toRhs x, ty))

  fun withStateDo toRhs ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val (argstyps, (v, t)) = List.splitLast argstyps
        val blk0 = MS.doRhs (toRhs (cfg, argstyps))
        val blk1 = MS.bindsRhs (rvar, M.RhsSimple v)
      in
        MS.seq (blk0, blk1)
      end

  fun withStateDoNothing ((state : TMU.state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val (argstyps, (v, t)) = List.splitLast argstyps
      in
        MS.bindsRhs (rvar, M.RhsSimple v)
      end

  fun newMutableArray (cfg, pinned, size, vtyp) =
      let
        val valueFD =mutableFD vtyp cfg
        val ws = Config.targetWordSize cfg
        val atyp = mutableArrayTyp ws vtyp
        val mdes = M.MDD { pok = M.PokNone , pinned = pinned , fixed = Vector.new1 (indexFD cfg) , array = SOME (0, valueFD) }
      in
        (M.RhsTuple {mdDesc = mdes, inits = Vector.new1 size}, atyp)
      end

  (* new array with intialization *)
  fun newArray mkFD ((state, rvar), argstyps) =
      case argstyps
        of [(size, styp), (arg, atyp), (M.SVariable v, t)] =>
          let
            val { im, cfg, ... } = state
            val ws = Config.targetWordSize cfg
            val wordTyp = wordTyp ws
            val wordPrec = wordPrec ws
            val wordArbTyp = wordArbTyp ws
            val wordNumTyp = wordNumTyp ws
            val intNumTyp = intNumTyp ws
            val one  = TMU.simpleInt (1, SOME wordArbTyp)
            val zero = TMU.simpleInt (0, SOME wordArbTyp)
            val siz  = TMU.localVariableFresh0 (im, wordTyp)
            val blk0 = MS.bindRhs (siz, convert (intNumTyp, wordNumTyp) [(size, styp)])
            val (trhs, ttyp) = newMutableArray (cfg, false, M.SVariable siz, atyp)
            val tvar = TMU.localVariableFresh0 (im, ttyp)
            val blk1 = MS.bindRhs (tvar, trhs)
            fun body idx = 
                let
                  val td = M.TD { fixed = Vector.new1 (immutableFD wordTyp cfg), array = SOME (mkFD cfg) }
                  val tf = M.TF { tupDesc = td, tup = tvar, field = M.FiVariable (M.SVariable idx) }
                in
                  MS.doRhs (M.RhsTupleSet { tupField = tf, ofVal = arg })
                end
            val blk2 = MU.uintpLoop (im, cfg, MU.noCarried, zero, M.SVariable siz, one, body)
            val blk3 = tupleSimple ((state, rvar), [(M.SVariable v, t), (M.SVariable tvar, ttyp)])
          in
            MS.seqn [blk0, blk1, blk2, blk3]
          end
         | _ => failMsg("newArray", "number of argument mismatch")

  (* new immutable arrays without initialisation *)
  fun newImmutableArray ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(sz, szt), (M.SVariable s, st)] =>
          let
            val ws = Config.targetWordSize cfg
            val et = M.TRef
            val szu = TMU.localVariableFresh0 (im, wordTyp ws)
            val blk0 = MS.bindRhs (szu, convert (intNumTyp ws, wordNumTyp ws) [(sz, szt)])
            val at = immutableArrayTyp (ws, et)
            val a = TMU.localVariableFresh0 (im, at)
            val amd = M.MDD {pok = M.PokNone, pinned = false, fixed = Vector.new1 (indexFD cfg),
                             array = SOME (0, immutableFD et cfg)}
            val blk1 = MS.bindRhs (a, M.RhsTuple {mdDesc = amd, inits = Vector.new1 (M.SVariable szu)})
            val blk2 = tupleSimple ((state, rvar), [(M.SVariable s, st), (M.SVariable a, at)])
            val blk = MS.seqn [blk0, blk1, blk2]
          in blk
          end
        | _ => failMsg("newImmutableArray", "argument number mismatch")

  fun newStrictImmutableArray ((state, rvar), argstyps) = newImmutableArray ((state, rvar), argstyps)

  fun newUnboxedArray2 et ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(sz, szt), (M.SVariable s, st)] =>
          let
            val ws = Config.targetWordSize cfg
            val szu = TMU.localVariableFresh0 (im, wordTyp ws)
            val blk0 = MS.bindRhs (szu, convert (intNumTyp ws, wordNumTyp ws) [(sz, szt)])
            val at = immutableArrayTyp (ws, et)
            val a = TMU.localVariableFresh0 (im, at)
            val amd = M.MDD {pok = M.PokNone, pinned = false, fixed = Vector.new1 (indexFD cfg),
                             array = SOME (0, immutableFD et cfg)}
            val blk1 = MS.bindRhs (a, M.RhsTuple {mdDesc = amd, inits = Vector.new1 (M.SVariable szu)})
            val blk2 = tupleSimple ((state, rvar), [(M.SVariable s, st), (M.SVariable a, at)])
            val blk = MS.seqn [blk0, blk1, blk2]
          in blk
          end
        | _ => failMsg("newUnboxedArray2", "argument number mismatch")

  (* new byte array without intialization *)
  fun newByteArray pinned (cfg, argstyps) =
      case argstyps
        of [(size, styp)] => newMutableArray (cfg, pinned, size, byteTyp)
         | _ => failMsg("newByteArray", "number of argument mismatch")

  (* new aligned byte array without intialization. TODO: support alignment argument *)
  fun newAlignedByteArray pinned (cfg, argstyps) =
      case argstyps
        of [(size, styp), (align, atyp)] => newMutableArray (cfg, pinned, size, byteTyp)
         | _ => failMsg("newAlignedByteArray", "number of argument mismatch")

  (*
   * new unboxed array without intialization even though an initialization value
   * must be present for type purpose. The type must be a thunk of a sum type of
   * a single primitive type.
   *)
  fun newUnboxedArray pinned (cfg, argstyps) =
      case argstyps
        of [(size, styp), (_, vtyp)] =>
           let
             val utyp = unboxedType vtyp
           in
             case utyp
              of M.TNonRefPtr => newMutableArray (cfg, pinned, size, utyp)
               | M.TNumeric _ => newMutableArray (cfg, pinned, size, utyp)
               | M.TBits _    => newMutableArray (cfg, pinned, size, utyp)
               | _ => failMsg("newUnboxedArray", "value type not supported")
           end
         | _ => failMsg("newUnboxedArray", "number of argument mismatch")

  (*
   * new aligned unboxed array without intialization. TODO: support alignment argument
   *)
  fun newAlignedUnboxedArray pinned (cfg, argstyps) =
      case argstyps
        of [(size, styp), (align, atyp), (_, vtyp)] => newUnboxedArray pinned (cfg, [(size, styp), (align, atyp)])
         | _ => failMsg("newAlignedByteArray", "number of argument mismatch")

  fun sizeOfArray mkFD (cfg, argstyps) =
      case argstyps
        of [(tup, ttyp)] =>
          (case (tup, ttyp)
            of (M.SVariable arr, M.TTuple { pok, fixed, array }) =>
               let
                 val td = M.TD { fixed = Vector.new1 (indexFD cfg), array = SOME (mkFD cfg) }
                 val ws = Config.targetWordSize cfg
               in
                 (M.RhsTupleSub (M.TF {tupDesc = td, tup = arr, field = M.FiFixed 0}), indexTyp ws)
               end
             | _ => failMsg("sizeOfArray", "not a variable of tuple type"))
         | _ => failMsg("sizeOfArray", "number of argument mismatch")

  fun sizeOfImmutableArray (cfg, argstyps) =
      case argstyps
       of [(tup, ttyp)] =>
          (case (tup, ttyp)
            of (M.SVariable arr, M.TTuple {pok, fixed, array}) =>
               let
                 val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = NONE}
               in
                 (M.RhsTupleSub (M.TF {tupDesc = td, tup = arr, field = M.FiFixed 0}), intTyp)
               end
             | _ => failMsg("sizeOfImmutableArray", "not a variable of tuple type"))
        | _ => failMsg("sizeofImmutableArray", "argument number mismatch")

  fun sizeOfStrictImmutableArray (cfg, argstypes) = sizeOfStrictImmutableArray (cfg, argstypes)

  fun sizeOfUnboxedArray (cfg, argstypes) = sizeOfStrictImmutableArray (cfg, argstypes)
 
  (* return array size in bytes *)
  fun sizeOfByteArray mkFD ((state, rvar), argstyps) =
      case argstyps
        of [(tup, ttyp)] =>
          (case (tup, ttyp)
            of (M.SVariable arr, M.TTuple { pok, fixed, array }) =>
               let
                 val { im, cfg, ... } = state
                 val ws = Config.targetWordSize cfg
                 val intTyp = intTyp ws
                 val intPrec = intPrec ws
                 val intNumTyp = intNumTyp ws
                 val intArbTyp = intArbTyp ws
                 val (_, valueSize, _) = array
                 val vs = TMU.simpleInt (MilUtils.ValueSize.numBytes valueSize, SOME intArbTyp)
                 val td = M.TD { fixed = Vector.new1 (indexFD cfg), array = SOME (mkFD cfg) }
                 val uvar = TMU.localVariableFresh0 (im, indexTyp ws)
                 val blk0 = MS.bindRhs (uvar,
                              M.RhsTupleSub (M.TF {tupDesc = td, tup = arr, field = M.FiFixed 0}))
                 val blk1 = MS.bindsRhs (rvar,
                              arith (intNumTyp, MP.ATimes) [(M.SVariable uvar, intTyp), (vs, intTyp)])
               in
                 MS.seq (blk0, blk1)
               end
             | _ => failMsg("sizeOfArray", "not a variable of tuple type"))
         | _ => failMsg("sizeOfArray", "number of argument mismatch")

  fun readArray (conv, typ) ((state, rvar), argstyps) =
      case argstyps
        of (tup, ttyp) :: (idx, ityp) :: more =>
          (case (tup, ttyp)
            of (M.SVariable arr, M.TTuple { pok, fixed, array }) =>
               let
                 val { im, cfg, ... } = state
                 val td = M.TD { fixed = Vector.new1 (indexFD cfg), array = SOME (mutableFD typ cfg) }
                 fun blk0 v = MS.bindsRhs (v, M.RhsTupleSub (M.TF {tupDesc = td, tup = arr, field = M.FiVariable idx}))
                 fun blk1 v =
                     case conv
                       of SOME (fromMP, toArb) =>
                         let
                           val toMP = MP.NtInteger (MP.IpFixed toArb)
                           val u = TMU.localVariableFresh0 (im, typ)
                         in
                           MS.seq (blk0 (Vector.new1 u), 
                                   MS.bindsRhs (v, convert (fromMP, toMP) [(M.SVariable u, typ)]))
                         end
                        | NONE => blk0 v
                 fun blk2 v =
                     case more
                       of [(M.SVariable s, styp)] =>
                         let
                           val utyp = case conv 
                                        of SOME (_, toArb) => MUP.NumericTyp.tIntegerFixed toArb
                                         | _ => typ
                           val u = TMU.localVariableFresh0 (im, utyp)
                           val blk2 = tupleSimple ((state, v), [(M.SVariable s, styp), (M.SVariable u, utyp)])
                         in
                           MS.seq (blk1 (Vector.new1 u), blk2)
                         end
                        | [] => blk1 v
                        | _ => failMsg("readArray", "wrong state variable")
               in
                 blk2 rvar
               end
             | _ => failMsg("readArray", "not a variable of tuple type"))
         | _ => failMsg("readArray", "number of argument mismatch")

  fun indexImmutableArray ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(a, at), (i, it)] =>
          (case (a, at)
            of (M.SVariable a, M.TTuple {array = (et, _, _), ...}) =>
               let
                 val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = SOME (immutableFD et cfg)}
                 val r = TMU.localVariableFresh0 (im, et)
                 val rhs = M.RhsTupleSub (M.TF {tupDesc = td, tup = a, field = M.FiVariable i})
                 val blk0 = MS.bindRhs (r, rhs)
                 val blk1 = tupleSimple ((state, rvar), [(M.SVariable r, et)])
                 val blk = MS.seqn ([blk0, blk1])
               in blk
               end
             | _ => failMsg("indexImmutableArray", "not a variable of array type"))
        | _ => failMsg("indexImmutableArray", "argument number mismatch")

  fun indexStrictImmutableArray ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(a, at), (i, it)] =>
          (case (a, at)
            of (M.SVariable a, M.TTuple {array = (et, _, _), ...}) =>
               let
                 val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = SOME (immutableFD et cfg)}
                 val r1 = TMU.localVariableFresh0 (im, et)
                 val rhs = M.RhsTupleSub (M.TF {tupDesc = td, tup = a, field = M.FiVariable i})
                 val blk0 = MS.bindRhs (r1, rhs)
                 val ett = M.TThunk et
                 val r2 = TMU.localVariableFresh0 (im, ett)
                 val fk = FK.fromTyp (cfg, et)
                 val blk1 = MS.bindRhs (r2, M.RhsThunkValue {typ = fk, thunk = NONE, ofVal = M.SVariable r1})
                 val blk2 = tupleSimple ((state, rvar), [(M.SVariable r2, ett)])
                 val blk = MS.seqn [blk0, blk1, blk2]
               in blk
               end
             | _ => failMsg("indexStrictImmutableArray", "not a variable of array type"))
        | _ => failMsg("indexStrictImmutableArray", "argument number mismatch")

  fun indexUnboxedArray conv ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(a, at), (i, it)] =>
          (case (a, at)
            of (M.SVariable a, M.TTuple {array = (et, _, _), ...}) =>
               let
                 val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = SOME (immutableFD et cfg)}
                 val rhs = M.RhsTupleSub (M.TF {tupDesc = td, tup = a, field = M.FiVariable i})
                 val (rhs, blk0) =
                     case conv
                      of NONE => (rhs, MS.empty)
                       | SOME (fromMP, toMP) =>
                         let
                           val res' = TMU.localVariableFresh0 (im, et)
                           val blk = MS.bindRhs (res', rhs)
                           val rhs = convert (fromMP, toMP) [(M.SVariable res', et)]
                         in (rhs, blk)
                         end
                 val blk1 = MS.bindsRhs (rvar, rhs)
                 val blk = MS.seqn [blk0, blk1]
               in blk
               end
             | _ => failMsg("indexUnboxedArray", "not a variable of array type"))
        | _ => failMsg("indexUnboxedArray", "argument number mismatch")

  fun writeArray (conv, typ) ((state, rvar), argstyps) =
      case argstyps
        of [(tup, ttyp), (idx, ityp), (dat, dty), (v, t)] =>
          (case (tup, ttyp)
            of (M.SVariable arr, M.TTuple { pok, fixed, array }) =>
               let
                 val { im, cfg, ... } = state
                 val td = M.TD { fixed = Vector.new1 (indexFD cfg), array = SOME (mutableFD typ cfg) }
                 val (u, blk) =
                   case conv
                     of SOME (fromMP, toMP) =>
                       let
                         val u = TMU.localVariableFresh0 (im, typ)
                       in
                         (M.SVariable u, MS.bindRhs (u, convert (fromMP, toMP) [(dat, dty)]))
                       end
                      | NONE => (dat, MS.empty)
                 val blk = MS.seq (blk, MS.doRhs (
                             M.RhsTupleSet { tupField = M.TF {tupDesc = td, tup = arr, field = M.FiVariable idx}
                                           , ofVal = u }))
                 val blk = MS.seq (blk, MS.bindsRhs (rvar, M.RhsSimple v))
               in
                 blk
               end
             | _ => failMsg("writeArray", "not a variable of tuple type"))
         | _ => failMsg("writeArray", "number of argument mismatch")

  fun initImmutableArray ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(a, at), (i, _), (e, _), (s, st)] =>
          (case (a, at)
            of (M.SVariable a, M.TTuple {array = (et, _, _), ...}) =>
               let
                 val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = SOME (immutableFD et cfg)}
                 val rhs = M.RhsTupleSet {tupField = M.TF {tupDesc = td, tup = a, field = M.FiVariable i}, ofVal = e}
                 val blk0 = MS.doRhs rhs
                 val blk1 = MS.bindsRhs (rvar, M.RhsSimple s)
                 val blk = MS.seqn [blk0, blk1]
               in blk
               end
             | _ => failMsg("initImmutableArray", "not a variable of array type"))
        | _ => failMsg("initImmutableArray", "argument number mismatch")

  fun initStrictImmutableArray ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(a, at), (i, _), (e, et), (s, st)] =>
          (case (a, at, e, et)
            of (M.SVariable a, M.TTuple {array = (et, _, _), ...}, M.SVariable e, M.TThunk set) =>
               let
                 (* Eval *)
                 val se = TMU.localVariableFresh0 (im, set)
                 val blk0 = TMU.kmThunk (state, Vector.new1 se, e, Effect.Control)
                 (* Initialise *)
                 val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = SOME (immutableFD et cfg)}
                 val tf = M.TF {tupDesc = td, tup = a, field = M.FiVariable i}
                 val rhs = M.RhsTupleSet {tupField = tf, ofVal = M.SVariable se}
                 val blk1 = MS.doRhs rhs
                 val blk2 = MS.bindsRhs (rvar, M.RhsSimple s)
                 val blk = MS.seqn [blk0, blk1, blk2]
               in blk
               end
             | _ => failMsg("initStrictImmutableArray", "bad operands or types"))
        | _ => failMsg("initStrictImmutableArray", "argument number mismatch")

  fun initUnboxedArray conv ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(a, at), (i, _), (e, ety), (s, st)] =>
          (case (a, at)
            of (M.SVariable a, M.TTuple {array = (et, _, _), ...}) =>
               let
                 val (e, blk0) =
                     case conv
                      of NONE => (e, MS.empty)
                       | SOME (fromMP, toMP) =>
                         let
                           val e' = TMU.localVariableFresh0 (im, et)
                           val blk = MS.bindRhs (e', convert (fromMP, toMP) [(e, ety)])
                         in (M.SVariable e', blk)
                         end
                 val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = SOME (immutableFD et cfg)}
                 val rhs = M.RhsTupleSet {tupField = M.TF {tupDesc = td, tup = a, field = M.FiVariable i}, ofVal = e}
                 val blk1 = MS.doRhs rhs
                 val blk2 = MS.bindsRhs (rvar, M.RhsSimple s)
                 val blk = MS.seqn [blk0, blk1, blk2]
               in blk
               end
             | _ => failMsg("initUnboxedArray", "not a variable of array type"))
        | _ => failMsg("initUnboxedArray", "argument number mismatch")

  fun arrayInited ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(a, at), (s, st)] =>
          (case (a, at)
            of (M.SVariable a, M.TTuple {array = (et, _, _), ...}) =>
               let
                 val mdd = M.MDD {pok = M.PokNone, pinned = false, fixed = Vector.new1 (indexFD cfg),
                                  array = SOME (0, immutableFD et cfg)}
                 val blk1 = MS.doRhs (M.RhsTupleInited {mdDesc = mdd, tup = a})
                 val blk2 = tupleSimple ((state, rvar), [(s, st), (M.SVariable a, at)])
                 val blk = MS.seqn [blk1, blk2]
               in blk
               end
             | _ => failMsg ("arrayInited", "not a variable of array type"))
        | _ => failMsg ("arrayInited", "arugment number mismatch")

  fun copyMutableArray ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(srca, arrtyp), (srcoff, _), (dsta, _), (dstoff, _), (cnt, cntt), (state, _)] =>
          (* cnt' = SIntp2UIntp(cnt)
           * for i in 0..cnt-1 do
           *   srci = srcoff + i
           *   elem = srca[srci]
           *   dsti = dstoff + i
           *   !dsta[dsti] <- elem
           * rvar = state
           *)
          let
            val ws = Config.targetWordSize cfg
            val elemTyp =
                case arrtyp
                 of M.TTuple {array = (t, _, _), ...} => t
                  | _ => failMsg("copyArray", "cannot determine element type")
            val cntu = TMU.localVariableFresh0 (im, wordTyp ws)
            val s0 = MS.bindRhs (cntu, convert (intNumTyp ws, wordNumTyp ws) [(cnt, cntt)])
            val one  = TMU.simpleInt (1, SOME (wordArbTyp ws))
            val zero = TMU.simpleInt (0, SOME (wordArbTyp ws))
            fun body i = 
                let
                  (* val i  = TMU.localVariableFresh0 (im, wordTyp ws) *)
                  val srci = TMU.localVariableFresh0 (im, wordTyp ws)
                  fun mkPlus (o1, o2) =
                      M.RhsPrim {prim = MP.Prim (MP.PNumArith {typ = intNumTyp ws, operator = MP.APlus}),
                                 createThunks = false,
                                 typs = Vector.new0 (),
                                 args = Vector.new2 (o1, o2)}
                  val s1 = MS.bindRhs (srci, mkPlus (srcoff, M.SVariable i))
                  val elem = TMU.localVariableFresh0 (im, elemTyp)
                  val td = M.TD {fixed = Vector.new1 (indexFD cfg), array = SOME (mutableFD elemTyp cfg)}
                  val srcav =
                      case srca
                       of M.SVariable v => v
                        | _ => failMsg("copyArray", "expected source array to be a variable")
                  val rhs = M.RhsTupleSub (M.TF {tupDesc = td, tup = srcav, field = M.FiVariable (M.SVariable srci)})
                  val s2 = MS.bindRhs (elem, rhs)
                  val dsti = TMU.localVariableFresh0 (im, wordTyp ws)
                  val s3 = MS.bindRhs (dsti, mkPlus (dstoff, M.SVariable i))
                  val dstav =
                      case dsta
                       of M.SVariable v => v
                        | _ => failMsg("copyArray", "expected dest array to be a variable")
                  val tf = M.TF {tupDesc = td, tup = dstav, field = M.FiVariable (M.SVariable dsti)}
                  val s4 = MS.doRhs (M.RhsTupleSet {tupField = tf, ofVal = M.SVariable elem})
                in
                  MS.seqn [s1, s2, s3, s4]
                end
            val s1 = MU.uintpLoop (im, cfg, MU.noCarried, zero, M.SVariable cntu, one, body)
            val s2 = MS.bindsRhs (rvar, M.RhsSimple state)
            val s = MS.seqn [s0, s1, s2]
          in s
          end
        | _ => failMsg("copyArray", "argument number mismatch")

  fun copyArray ((state, rvar), argstyps) = copyMutableArray ((state, rvar), argstyps)

  fun copyByteArray ((state, rvar), argstyps) = copyMutableArray ((state, rvar), argstyps)

  fun copyMutableByteArray ((state, rvar), argstyps) = copyMutableArray ((state, rvar), argstyps)

  fun newMutVar (cfg, argstyps) =
      case argstyps
       of [(arg, typ)] =>
          let
            val mdes = M.MDD {pok = M.PokNone, pinned = false, fixed = Vector.new1 (mutableRefFD cfg), array = NONE}
          in
            (M.RhsTuple {mdDesc = mdes, inits  = Vector.new1 arg}, mutVarTyp)
          end
        | _ => failMsg("newMutVar", "number of argument mismatch")

  fun readMutVar (cfg, argstyps) =
      case argstyps
        of [(arg, typ)] =>
          (case (arg, typ)
            of (M.SVariable arr, M.TTuple { pok, fixed, array }) =>
               let
                 val (ty, _, _) = Vector.sub (fixed, 0)
                 val td = M.TD { fixed = Vector.new1 (mutableRefFD cfg), array = NONE }
               in
                 (M.RhsTupleSub (M.TF {tupDesc = td, tup = arr, field = M.FiFixed 0}), ty)
               end
             | _ => failMsg("readMutVar", "not a variable of tuple type"))
         | _ => failMsg("readMutVar", "number of argument mismatch")

  fun writeMutVar (cfg, argstyps) =
      case argstyps
        of [(arg, typ), (dat, dty)] =>
          (case (arg, typ)
            of (M.SVariable arr, M.TTuple { pok, fixed, array }) =>
               let
                 val (ty, _, _) = Vector.sub (fixed, 0)
                 val td = M.TD { fixed = Vector.new1 (mutableRefFD cfg), array = NONE }
               in
                 M.RhsTupleSet { tupField = M.TF {tupDesc = td, tup = arr, field = M.FiFixed 0}, ofVal = dat }
               end
             | _ => failMsg("writeMutVar", "not a variable of tuple type"))
         | _ => failMsg("writeMutVar", "number of argument mismatch")

  fun casMutVar ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (cv, _), (nv, _), (s, st)] =>
          (case (arg, typ)
            of (M.SVariable arr, M.TTuple { pok, fixed, array }) =>
               let
                 val (ty, _, _) = Vector.sub (fixed, 0)
                 val td = M.TD { fixed = Vector.new1 (mutableRefFD cfg), array = NONE }
                 val tf = M.TF {tupDesc = td, tup = arr, field = M.FiFixed 0}
                 val rhs = M.RhsTupleCAS {tupField = tf, cmpVal = cv, newVal = nv}
                 val res = TMU.localVariableFresh0 (im, ty)
                 val blk0 = MS.bindRhs (res, rhs)
                 val suct = M.TBoolean
                 val suc = TMU.localVariableFresh0 (im, suct)
                 val p = MP.Prim MP.PPtrEq
                 val args = Vector.new2 (M.SVariable res, cv)
                 val rhs = M.RhsPrim {prim = p, createThunks = false, typs = Vector.new0 (), args = args}
                 val blk1 = MS.bindRhs (suc, rhs)
                 val blk2 = tupleSimple ((state, rvar), [(s, st), (M.SVariable suc, suct), (M.SVariable res, ty)])
                 val blk = MS.seqn [blk0, blk1, blk2]
               in blk
               end
             | _ => failMsg("casMutVar", "not a variable of tuple type"))
         | _ => failMsg("casMutVar", "number of argument mismatch")

  local
    val fx = Effect.Control
    fun mkEval (state as {im, cfg, ...}, f, a, typs) =
        let
          val (ft, fvt, at, pt, _, _) = typs
          val selft = M.TThunk pt
          val r = TMU.localVariableFresh0 (im, selft)
          val self = IM.variableClone (im, r)
          val f' = IM.variableClone (im, f)
          val () = TMU.setVariableKind (im, f', M.VkLocal)
          val a' = IM.variableClone (im, a)
          val () = TMU.setVariableKind (im, a', M.VkLocal)
          val fv = TMU.localVariableFresh0 (im, fvt)
          val eval = 
              let
                val code = TMU.stateGetCodesForFunction (state, f)
              in M.EThunk {thunk = f', code = code}
              end
          val blk0 = MU.eval (im, cfg, FK.fromTyp (cfg, fvt), eval, TMU.exitCut, fx, fv)
          val call = M.CClosure {cls = fv, code = TMU.noCode}
          val tr = M.TInterProc {callee = M.IpCall {call = call, args = Vector.new1 (M.SVariable a')}, 
                                 ret = M.RTail {exits = true}, fx = fx}
          val ccCode = M.CcThunk {thunk = self, fvs = Vector.new2 (f', a')}
          val ccType = M.CcThunk {thunk = selft, fvs = Vector.new2 (ft, at)}
          val code = TMU.mkNamedFunction (state, "atomicModifyMutVarEval_#", ccCode, ccType, true, true, 
                                          Vector.new0 (), Vector.new0 (), Vector.new1 pt, blk0, tr, fx)
          val fvs = Vector.new2 ((FK.fromTyp (cfg, ft), M.SVariable f), (FK.fromTyp (cfg, at), M.SVariable a))
          val rhs = M.RhsThunkInit {typ = FK.fromTyp (cfg, pt), thunk = NONE, fx = fx, code = SOME code, fvs = fvs}
          val blk = MS.bindRhs (r, rhs)
        in (blk, r)
        end
    fun mkPrj (state as {im, cfg, ...}, p, i, typs) =
        let
          val ws = Config.targetWordSize cfg
          val (_, _, _, pt, t1, t2) = typs
          val ptt = M.TThunk pt
          val rt = case i of 0 => t1 | 1 => t2 | _ => failMsg("atomicModifyMutVar.mkPrj", "bad index")
          val selft = M.TThunk rt
          val r = TMU.localVariableFresh0 (im, selft)
          val self = IM.variableClone (im, r)
          val p' = IM.variableClone (im, p)
          val () = TMU.setVariableKind (im, p', M.VkLocal)
          val pv = TMU.localVariableFresh0 (im, pt)
          val eval = 
              let
                val code = TMU.stateGetCodesForFunction (state, p)
              in M.EThunk {thunk = p', code = code}
              end
          val blk0 = MU.eval (im, cfg, FK.fromTyp (cfg, pt), eval, TMU.exitCut, fx, pv)
          val prjthnk = TMU.localVariableFresh0 (im, selft)
          val fks = Vector.new2 (FK.fromTyp (cfg, t1), FK.fromTyp (cfg, t2))
          val rhs = M.RhsSumProj {typs = fks, sum = pv, tag = defaultTag ws, idx = i}
          val blk1 = MS.bindRhs (prjthnk, rhs)
          val blk = MS.seqn [blk0, blk1]
          val eval = M.EThunk {thunk = prjthnk, code = TMU.noCode}
          val fk = FK.fromTyp (cfg, rt)
          val t = M.TInterProc {callee = M.IpEval {typ = fk, eval = eval}, ret = M.RTail {exits = true}, fx = fx}
          val ccCode = M.CcThunk {thunk = self, fvs = Vector.new1 p'}
          val ccType = M.CcThunk {thunk = selft, fvs = Vector.new1 ptt}
          val f = TMU.mkNamedFunction 
                    (state, "atomicModifyMutVarPrj" ^ Int.toString i ^ "_#", ccCode, ccType, true, true, 
                     Vector.new0 (), Vector.new0 (), Vector.new1 rt, blk, t, fx)
          val fvs = Vector.new1 (FK.fromTyp (cfg, ptt), M.SVariable p)
          val rhs = M.RhsThunkInit {typ = FK.fromTyp (cfg, rt), thunk = NONE, fx = fx, code = SOME f, fvs = fvs}
          val blk = MS.bindRhs (r, rhs)
        in (blk, r, selft)
        end
    fun getTypes ft =
        case ft
         of M.TThunk (fvt as M.TClosure {args, ress}) =>
            let
              val at = if Vector.length args = 1 then Vector.sub (args, 0) else M.TRef
              val pt =
                  if Vector.length ress = 1 then
                    case Vector.sub (ress, 0)
                     of M.TThunk t => t
                      | _          => M.TRef
                  else
                    M.TRef
              val (t1, t2) =
                  case pt
                   of M.TSum {arms, ...} =>
                      if Vector.length arms = 1 then
                        let
                          val (_, ts) = Vector.sub (arms, 0)
                        in
                          if Vector.length ts = 2 then (Vector.sub (ts, 0), Vector.sub (ts, 1)) else (M.TRef, M.TRef)
                        end
                      else
                        (M.TRef, M.TRef)
                    | _ => (M.TRef, M.TRef)
            in (ft, fvt, at, pt, t1, t2)
            end
          | _ => (M.TRef, M.TRef, M.TRef, M.TRef, M.TRef, M.TRef)
  in
  fun atomicModifyMutVar ((state as {im, cfg, ...}, rvar), argstyps : (M.operand * M.typ) list) =
      case argstyps
       of [(mv, mvt), (f, ft), (s, st)] =>
          (case (mv, mvt, f)
            of (M.SVariable mv, M.TTuple {fixed, ...}, M.SVariable f) =>
               let
                 val (ty, _, _) = Vector.sub (fixed, 0)
                 val typs = getTypes ft
                 (* mv is the mutable variable
                  * f is a thunk on a closure that takes value of the mut var to pair of new value and return value
                  * (note that the pair's contents are thunked)
                  * s is the state
                  *
                  * We want to do this:
                  * loop:
                  *   ov = read mv
                  *   t1 = thunk{eval(f)(ov)}
                  *   t2 = thunk{p=eval(t1); eval(fst(p))}
                  *   if (CAS(mv.val, ov, t2)!=ov) goto loop;
                  *   t3 = thunk{p=eval(t2); eval(snd(p))}
                  * return(#s,t3#)
                  *)
                 val l = IM.labelFresh im
                 val goto = M.TGoto (M.T {block = l, arguments = Vector.new0 ()})
                 val blk0 = MS.prependTL (goto, l, Vector.new0 (), MS.empty)
                 val ov = TMU.localVariableFresh0 (im, ty)
                 val td = M.TD {fixed = Vector.new1 (mutableRefFD cfg), array = NONE}
                 val rhs = M.RhsTupleSub (M.TF {tupDesc = td, tup = mv, field = M.FiFixed 0})
                 val blk1 = MS.bindRhs (ov, rhs)
                 val (blk2, t1) = mkEval (state, f, ov, typs)
                 val (blk3, t2, _) = mkPrj (state, t1, 0, typs)
                 val ofv = TMU.localVariableFresh0 (im, ty)
                 val tf = M.TF {tupDesc = td, tup = mv, field = M.FiFixed 0}
                 val rhs = M.RhsTupleCAS {tupField = tf, cmpVal = M.SVariable ov, newVal = M.SVariable t2}
                 val blk4 = MS.bindRhs (ofv, rhs)
                 val c = TMU.localVariableFresh0 (im, M.TBoolean)
                 val p = MP.Prim MP.PPtrEq
                 val args = Vector.new2 (M.SVariable ofv, M.SVariable ov)
                 val rhs = M.RhsPrim {prim = p, createThunks = false, typs = Vector.new0 (), args = args}
                 val blk5 = MS.bindRhs (c, rhs)
                 val l' = IM.labelFresh im
                 val mkIf =
                     let
                       val cs = Vector.new2 ((M.CBoolean false, M.T {block = l,  arguments = Vector.new0 ()}),
                                             (M.CBoolean true,  M.T {block = l', arguments = Vector.new0 ()}))
                       val t = M.TCase {select = M.SeConstant, on = M.SVariable c, cases = cs, default = NONE}
                     in t
                     end
                 val blk6 = MS.prependTL (mkIf, l', Vector.new0 (), MS.empty)
                 val (blk7, t3, t3t) = mkPrj (state, t1, 1, typs)
                 val blk8 = tupleSimple ((state, rvar), [(s, st), (M.SVariable t3, t3t)])
                 val blk = MS.seqn [blk0, blk1, blk2, blk3, blk4, blk5, blk6, blk7, blk8]
               in blk
               end
             | _ => failMsg("atomicModifyMutVar", "mutable variable not variable or wrong type"))
        | _ => failMsg("atomicModifyMutVar", "argument number mismatch")
  end

  fun applyFirst ((state, rvar), argstyps) =
    case argstyps
      of [(fval, ftyp), (svar, styp)] =>
        (case (fval, ftyp)
          of (M.SVariable fvar, M.TThunk ctyp) =>
            (case ctyp
               of M.TClosure { args, ress } =>
                  let
                    val { im, cfg, effects, ... } = state
                    val clo = TMU.localVariableFresh0 (im, ctyp)
                    val eval = 
                        let
                          val code = TMU.stateGetCodesForFunction (state, fvar)
                        in M.EThunk { thunk = fvar, code = code }
                        end
                    val blk0 = MU.eval (im, cfg, FK.fromTyp (cfg, ftyp), eval, TMU.exitCut, Effect.Any, clo)
                    val fx = TMU.lookupEffect (effects, clo, true, true)
                    val blk1 = MU.call (im, cfg, M.CClosure { cls = clo, code = TMU.noCode },
                                         Vector.new1 svar, TMU.exitCut, fx, rvar)
                  in
                    (MS.seq (blk0, blk1), fx)
                  end
              | _ => failMsg("applyFirst", "first argument is not a function"))
           | _ => failMsg("applyFirst", "first argument is not a thunk variable"))
       | _ => failMsg("applyFirst", "number of argument mismatch")

  fun wrapThread (state as {im, cfg, ...}, blk) =
      let
        val tr = M.TReturn (Vector.new0 ())
        val f = TMU.mkMainFunction (state, "threadMain_#", blk, tr, Effect.Any)
        fun twTyp () =
            let
              val tmt = M.TCode {cc = M.CcCode, args = Vector.new0 (), ress = Vector.new0 ()}
              val twt = M.TCode {cc = M.CcCode, args = Vector.new1 tmt, ress = Vector.new0 ()}
            in twt
            end
        val (tw, _) = TMU.externVariable (state, pkgName, "ihrThreadWrapper0", twTyp)
        val call = M.CCode {ptr = tw, code = TMU.noCode}
        val blk = MU.call (im, cfg, call, Vector.new1 (M.SVariable f), TMU.noCut, Effect.Any, Vector.new0 ())
      in blk
      end

  val exnHandlerTyp = M.TContinuation (Vector.new0 ())
  (*val exnHandlerTyp = M.TContinuation (Vector.new1 M.TRef)*)

  fun cut (state, arg, rvar) =
      let
        val {im, cfg, ...} = state
        val cvar = TMU.localVariableFresh0 (im, exnHandlerTyp)
        fun seTyp () = M.TCode {cc = M.CcCode, args = Vector.new1 M.TRef, ress = Vector.new0 ()}
        val (geh, _) = TMU.externVariable (state, pkgName, "ihrExceptionExnSet", seTyp)
        val call = M.CCode {ptr = geh, code = TMU.noCode}
        val blk0' = MU.call (im, cfg, call, Vector.new1 arg, TMU.noCut, Effect.Heap, Vector.new0 ())
        fun gehTyp () = M.TCode {cc = M.CcCode, args = Vector.new0 (), ress = Vector.new1 exnHandlerTyp}
        val (geh, _) = TMU.externVariable (state, pkgName, "ihrExceptionHandlerGet", gehTyp)
        val call = M.CCode {ptr = geh, code = TMU.noCode}
        val blk0 = MU.call (im, cfg, call, Vector.new0 (), TMU.noCut, Effect.Heap, Vector.new1 cvar)
        val mkCut = M.TCut {cont = cvar, args = Vector.new0 (), cuts = TMU.exitCut}
        (*fun mkCut (_, _, _) = M.TCut {cont = cvar, args = Vector.new1 arg, cuts = TMU.exitCut}*)
        val blk1 = MS.prependTL (mkCut, IM.labelFresh im, rvar, MS.empty)
        val blk = MS.seqn [blk0', blk0, blk1]
      in blk
      end

  fun raisezh ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ)] => cut (state, arg, rvar)
        |  _ => failMsg("raisezh", "number of argument mismatch")

  fun raiseIOzh ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (sval, styp)] =>
          let
            val { im, cfg, ... } = state
            val uvar = TMU.localVariableFresh0 (im, M.TRef)
            val blk0 = cut (state, arg, Vector.new1 uvar)
            val blk1 = tupleSimple ((state, rvar), [(sval, styp), (M.SVariable uvar, M.TRef)])
          in
            MS.seq (blk0, blk1)
          end
        |  _ => failMsg("raiseIOzh", "number of argument mismatch")

  fun setHandler (state as {im, cfg, ...}, h) =
      let
        fun sehTyp () = M.TCode {cc = M.CcCode, args = Vector.new1 exnHandlerTyp, ress = Vector.new0 ()}
        val (seh, _) = TMU.externVariable (state, pkgName, "ihrExceptionHandlerSet", sehTyp)
        val call = M.CCode {ptr = seh, code = TMU.noCode}
        val blk = MU.call (im, cfg, call, Vector.new1 h, TMU.noCut, Effect.Heap, Vector.new0 ())
      in blk
      end

  fun catchzh ((state, rvar), argstyps) =
      case argstyps
        of [(fvar, ftyp), (hvar, htyp), (svar, styp)] =>
          (case (fvar, ftyp, hvar, htyp)
            of (M.SVariable fvar, M.TThunk ftyp, M.SVariable hvar, M.TThunk htyp) =>
              let
                (* f : state -> (# state, a #)
                 * h : b -> state -> (# state, a #)
                 * s : state
                 *
                 * We want:
                 *   oeh = getExnHandler()
                 *   t2 = Cont(L1)
                 *   setExnHandler(t2)
                 *   fv = eval(f)
                 *   sr1 = fv(s)
                 *   setExnHandler(oeh)
                 *   goto L2(sr1)
                 * L1(exn : TRef)
                 *   setExnHandler(oeh)
                 *   hv = eval(h)
                 *   t3 = hv(exn)
                 *   sr2 = t3(s)
                 *   goto L2(sr2)
                 * L2(rvar)
                 *)
                val { im, cfg, effects, ... } = state
                val sr1 = TMU.variablesClone (im, rvar)
                val sr2 = TMU.variablesClone (im, rvar)
                val oeh = TMU.localVariableFresh0 (im, exnHandlerTyp)
                fun gehTyp () = M.TCode {cc = M.CcCode, args = Vector.new0 (), ress = Vector.new1 exnHandlerTyp}
                val (geh, _) = TMU.externVariable (state, pkgName, "ihrExceptionHandlerGet", gehTyp)
                val call = M.CCode {ptr = geh, code = TMU.noCode}
                val b0 = MU.call (im, cfg, call, Vector.new0 (), TMU.noCut, Effect.Heap, Vector.new1 oeh)
                val cv = TMU.localVariableFresh0 (im, exnHandlerTyp)
                val l2 = IM.labelFresh im
                val goto1 = M.TGoto (M.T {block = l2, arguments = Vector.map (sr2, M.SVariable)})
                val b11 = MS.prependTL (goto1, l2, rvar, MS.empty)
                val goto2 = M.TGoto (M.T {block = l2, arguments = Vector.map (sr1, M.SVariable)})
                val exn = TMU.localVariableFresh0 (im, M.TRef)
                val (l1, b6) =
                    let
                      fun geTyp () = M.TCode {cc = M.CcCode, args = Vector.new0 (), ress = Vector.new1 M.TRef}
                      val (ge, _) = TMU.externVariable (state, pkgName, "ihrExceptionExnGet", geTyp)
                      val call = M.CCode {ptr = ge, code = TMU.noCode}
                      val b = MU.call (im, cfg, call, Vector.new0 (), TMU.noCut, Effect.Heap, Vector.new1 exn)
                      val l = IM.labelFresh im
                      val b = MS.prependTL (goto2, l, Vector.new0 (), b)
                    in (l, b)
                    end
                (*val (l1, b6) = MS.enterWith (im, cfg, MS.new (im, cfg), Vector.new1 exn, mkGoto)*)
                val b1 = MS.bindRhs (cv, M.RhsCont l1)
                val b2 = setHandler (state, M.SVariable cv)
                val fv = TMU.localVariableFresh0 (im, ftyp)
                val cuts = M.C {exits = true, targets = LS.singleton l1}
                val cx = Effect.Control
                val ax = Effect.Any
                val eval = 
                    let
                      val code = TMU.stateGetCodesForFunction (state, fvar)
                    in M.EThunk {thunk = fvar, code = code}
                    end
                val b3 = MU.eval (im, cfg, M.FkRef, eval, cuts, cx, fv)
                val call = M.CClosure {cls = fv, code = TMU.noCode}
                val b4 = MU.call (im, cfg, call, Vector.new1 svar, cuts, ax, sr1)
                val b5 = setHandler (state, M.SVariable oeh)
                val b7 = setHandler (state, M.SVariable oeh)
                val hv = TMU.localVariableFresh0 (im, htyp)
                val eval = 
                    let
                      val code = TMU.stateGetCodesForFunction (state, hvar)
                    in M.EThunk {thunk = hvar, code = code}
                    end
                val b8 = MU.eval (im, cfg, M.FkRef, eval, TMU.exitCut, cx, hv)
                val call = M.CClosure {cls = hv, code = TMU.noCode}
                val h' = TMU.localVariableFresh0 (im, M.TRef)
                val b9 = MU.call (im, cfg, call, Vector.new1 (M.SVariable exn), TMU.exitCut, cx, Vector.new1 h')
                val call = M.CClosure {cls = h', code = TMU.noCode}
                val b10 = MU.call (im, cfg, call, Vector.new1 svar, TMU.exitCut, ax, sr2)
                val blk = MS.seqn [b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11]
              in blk
              end
            | _ => failMsg("catchzh", "expect arguments to be variables"))
        | _ =>  failMsg("catchzh", "number of argument mismatch")

  val null = M.SConstant (M.CRef 0)

  (* MVars:
   *   We use a heap object with a single mutable field that is null when empty.
   *   To implement the operations in a thread-safe manner, we must CAS.
   *   To block until the contents is empty/not-empty we use ?
   *)

  fun mkMVarTD (cfg, t) =
      M.TD {fixed = Vector.new1 (mutableRefFD cfg), array = NONE}

  fun mkMVarTF (cfg, t, mv) =
      M.TF {tupDesc = mkMVarTD (cfg, t), tup = mv, field = M.FiFixed 0}

  fun mkMVarRead (cfg, t, mv) =
      M.RhsTupleSub (mkMVarTF (cfg, t, mv))

  fun mkMVarCAS (cfg, t, mv, cmp, new) =
      M.RhsTupleCAS {tupField = mkMVarTF (cfg, t, mv), cmpVal = cmp, newVal = new}

  fun newMVar (cfg, argstyps) =
      case argstyps
       of [] =>
          let
            val et = M.TRef
            val mdd = M.MDD {pok = M.PokNone, pinned = false, fixed = Vector.new1 (mutableRefFD cfg), array = NONE}
            val rhs = M.RhsTuple {mdDesc = mdd, inits  = Vector.new1 null}
          in (rhs, mVarTyp)
          end
        | _ => failMsg("newMVar", "argument number mismatch")

  fun takeMVar ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(mv, mvt), (s, st)] =>
          let
            (*   goto L1()
             * L1():
             *   rv = mv.0
             *   if rv==0 goto L2() else L3()
             * L2():
             *   yield()
             *   goto L1()
             * L3():
             *   cv = CAS(mv.0, rv, null)
             *   if cv==rv goto L4() else goto L2()
             * L4():
             *   rvar = (# s, rv #)
             *)
            val (mv, et) =
                case (mv, mvt)
                 of (M.SVariable mv, M.TTuple {fixed, ...}) => (mv, #1 (Vector.sub (fixed, 0)))
                  | _ => failMsg("takeMVar", "MVar not variable of MVar type")
            val rv = TMU.localVariableFresh0 (im, et)
            val cv = TMU.localVariableFresh0 (im, et)
            val cmp1 = TMU.localVariableFresh0 (im, M.TBoolean)
            val cmp2 = TMU.localVariableFresh0 (im, M.TBoolean)
            val l1 = IM.labelFresh im
            val l2 = IM.labelFresh im
            val l3 = IM.labelFresh im 
            val l4 = IM.labelFresh im
            val goto1 = M.TGoto (M.T {block = l1, arguments = Vector.new0 ()})
            val blk0 = MS.prependTL (goto1, l1, Vector.new0 (), MS.empty)
            val goto2 = M.TGoto (M.T {block = l1, arguments = Vector.new0 ()})
            val blk5 = MS.prependTL (goto2, l3, Vector.new0 (), MS.empty)
            val mkIf2 =
                let
                  val tt = M.T {block = l2, arguments = Vector.new0 ()}
                  val ft = M.T {block = l3, arguments = Vector.new0 ()}
                  val t = MilUtils.Bool.ifT (cfg, M.SVariable cmp1, {trueT = tt, falseT = ft})
                in t
                end
            val blk3 = MS.prependTL (mkIf2, l2, Vector.new0 (), MS.empty)
            val mkIf4 =
                let
                  val tt = M.T {block = l4, arguments = Vector.new0 ()}
                  val ft = M.T {block = l2, arguments = Vector.new0 ()}
                  val t = MilUtils.Bool.ifT (cfg, M.SVariable cmp2, {trueT = tt, falseT = ft})
                in t
                end
            val blk8 = MS.prependTL (mkIf4, l4, Vector.new0 (), MS.empty) 
            val blk1 = MS.bindRhs (rv, mkMVarRead (cfg, et, mv))
            val blk2 = MS.bindRhs (cmp1, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable rv, et), (null, et)])
            fun pyTyp () = M.TCode {cc = M.CcCode, args = Vector.new0 (), ress = Vector.new0 ()}
            (* prtYield is not actually in pkgName, but it's not in an actual package, and is included *)
            val (py, _) = TMU.externVariable (state, pkgName, "prtYield", pyTyp)
            val call = M.CCode {ptr = py, code = TMU.noCode}
            val blk4 = MU.call (im, cfg, call, Vector.new0 (), TMU.noCut, Effect.Any, Vector.new0 ())
            val blk6 = MS.bindRhs (cv, mkMVarCAS (cfg, et, mv, M.SVariable rv, null))
            val blk7 = MS.bindRhs (cmp2, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable rv, et), (M.SVariable cv, et)])
            val blk9 = tupleSimple ((state, rvar), [(s, st), (M.SVariable rv, et)])
            val blk = MS.seqn [blk0, blk1, blk2, blk3, blk4, blk5, blk6, blk7, blk8, blk9]
          in blk
          end
        | _ => failMsg("takeMVar", "argument number mismatch")

  fun tryTakeMVar ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(mv, mvt), (s, st)] =>
          let
            (*   rv1 = mv.0
             *   if rv1==0 goto L2() else L1()
             * L1():
             *   cv = CAS(mv.0, rv1, null)
             *   if cv==rv goto L3(1, rv1) else goto L2
             * L2():
             *   undefined = thunk{loop;}
             *   goto L3(0, undefined)
             * L3(suc, rv2):
             *   rvar = (# s, suc, rv2 #)
             *)
            val ws = Config.targetWordSize cfg
            val (mv, et) =
                case (mv, mvt)
                 of (M.SVariable mv, M.TTuple {fixed, ...}) => (mv, #1 (Vector.sub (fixed, 0)))
                  | _ => failMsg("tryTakeMVar", "MVar not variable of MVar type")
            val rv1 = TMU.localVariableFresh0 (im, et)
            val rv2 = TMU.localVariableFresh0 (im, et)
            val undefined = TMU.localVariableFresh0 (im, et)
            val cv = TMU.localVariableFresh0 (im, et)
            val cmp1 = TMU.localVariableFresh0 (im, M.TBoolean)
            val cmp2 = TMU.localVariableFresh0 (im, M.TBoolean)
            val suct = intTyp ws
            val suc = TMU.localVariableFresh0 (im, suct)
            val zero = TMU.simpleInt (0, SOME (wordArbTyp ws))
            val one = TMU.simpleInt (1, SOME (wordArbTyp ws))
            val l1 = IM.labelFresh im
            val l2 = IM.labelFresh im
            val l3 = IM.labelFresh im
            val goto3 = M.TGoto (M.T {block = l3, arguments = Vector.new2 (zero, M.SVariable undefined)})
            val blk7 = MS.prependTL (goto3, l3, Vector.new2 (suc, rv2), MS.empty)
            val mkIf2 =
                let
                  val tt = M.T {block = l3, arguments = Vector.new2 (one, M.SVariable rv1)}
                  val ft = M.T {block = l2, arguments = Vector.new0 ()}
                  val t = MilUtils.Bool.ifT (cfg, M.SVariable cmp2, {trueT = tt, falseT = ft})
                in t
                end
            val blk5 = MS.prependTL (mkIf2, l2, Vector.new0 (), MS.empty)
            val mkIf1 =
                let
                  val tt = M.T {block = l2, arguments = Vector.new0 ()}
                  val ft = M.T {block = l1, arguments = Vector.new0 ()}
                  val t = MilUtils.Bool.ifT (cfg, M.SVariable cmp1, {trueT = tt, falseT = ft})
                in t
                end
            val blk2 = MS.prependTL (mkIf1, l1, Vector.new0 (), MS.empty)
            val blk0 = MS.bindRhs (rv1, mkMVarRead (cfg, et, mv))
            val blk1 = MS.bindRhs (cmp1, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable rv1, et), (null, et)])
            val blk3 = MS.bindRhs (cv, mkMVarCAS (cfg, et, mv, M.SVariable rv1, null))
            val blk4 = MS.bindRhs (cmp2, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable cv, et), (M.SVariable rv1, et)])
            val ut = M.TThunk et
            val self = TMU.localVariableFresh0 (im, ut)
            val ccCode = M.CcThunk {thunk = self, fvs = Vector.new0 ()}
            val ccType = M.CcThunk {thunk = ut, fvs = Vector.new0 ()}
            val ul = IM.labelFresh im
            val gotoUl = M.TGoto (M.T {block = ul, arguments = Vector.new0 ()})
            val ublk = MS.prependTL (gotoUl, ul, Vector.new0 (), MS.empty)
            val tr = M.TGoto (M.T {block = ul, arguments = Vector.new0 ()})
            val cptr = TMU.mkNamedFunction (state, "undefined_#", ccCode, ccType, true, true,
                                            Vector.new0 (), Vector.new0 (), Vector.new1 et, ublk, tr, Effect.PartialS)
            val uf = SOME cptr
            val rhs =
                M.RhsThunkInit {typ = M.FkRef, thunk = NONE, fx = Effect.PartialS, code = uf, fvs = Vector.new0 ()}
            val blk6 = MS.bindRhs (undefined, rhs)
            val blk8 = tupleSimple ((state, rvar), [(s, st), (M.SVariable suc, suct), (M.SVariable rv2, et)])
            val blk = MS.seqn [blk0, blk1, blk2, blk3, blk4, blk5, blk6, blk7, blk8]
          in blk
          end
        | _ => failMsg("tryTakeMVar", "argument number mismatch")

  fun putMVar ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(mv, mvt), (x, xt), (s, st)] =>
          let
            (*   goto L1()
             * L1():
             *   cv = CAS(mv.0, null, x)
             *   if cv==0 goto L3() else L2()
             * L2():
             *   yield()
             *   goto L1()
             * L3():
             *   rvar = s
             *)
            val (mv, et) =
                case (mv, mvt)
                 of (M.SVariable mv, M.TTuple {fixed, ...}) => (mv, #1 (Vector.sub (fixed, 0)))
                  | _ => failMsg("putMVar", "MVar not variable of MVar type")
            val cv = TMU.localVariableFresh0 (im, et)
            val cmp = TMU.localVariableFresh0 (im, M.TBoolean)
            val l1 = IM.labelFresh im
            val l2 = IM.labelFresh im
            val l3 = IM.labelFresh im
            val goto1 = M.TGoto (M.T {block = l1, arguments = Vector.new0 ()})
            val blk0 = MS.prependTL (goto1, l1, Vector.new0 (), MS.empty)
            val goto3 = M.TGoto (M.T {block = l1, arguments = Vector.new0 ()})
            val blk5 = MS.prependTL (goto3, l3, Vector.new0 (), MS.empty)
            val mkIf2 = 
                let
                  val tt = M.T {block = l3, arguments = Vector.new0 ()}
                  val ft = M.T {block = l2, arguments = Vector.new0 ()}
                  val t = MilUtils.Bool.ifT (cfg, M.SVariable cmp, {trueT = tt, falseT = ft})
                in t
                end
            val blk3 = MS.prependTL (mkIf2, l2, Vector.new0 (), MS.empty)
            val blk1 = MS.bindRhs (cv, mkMVarCAS (cfg, et, mv, null, x))
            val blk2 = MS.bindRhs (cmp, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable cv, et), (null, et)])
            fun pyTyp () = M.TCode {cc = M.CcCode, args = Vector.new0 (), ress = Vector.new0 ()}
            (* prtYield is not actually in pkgName, but it's not in an actual package, and is included *)
            val (py, _) = TMU.externVariable (state, pkgName, "prtYield", pyTyp)
            val call = M.CCode {ptr = py, code = TMU.noCode}
            val blk4 = MU.call (im, cfg, call, Vector.new0 (), TMU.noCut, Effect.Any, Vector.new0 ())
            val blk6 = MS.bindsRhs (rvar, M.RhsSimple s)
            val blk = MS.seqn [blk0, blk1, blk2, blk3, blk4, blk5, blk6]
          in blk
          end
        | _ => failMsg("putMVar", "argument number mismatch")

  fun tryPutMVar ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(mv, mvt), (x, xt), (s, st)] =>
          let
            (* ov = CAS(mv.0, null, x)
             * suc = ov==null
             * return(#s,suc#)
             *)
            val (mv, et) =
                case (mv, mvt)
                 of (M.SVariable mv, M.TTuple {fixed, ...}) => (mv, #1 (Vector.sub (fixed, 0)))
                  | _ => failMsg("tryPutMVar", "MVar not variable of MVar type")
            val ov = TMU.localVariableFresh0 (im, et)
            val blk0 = MS.bindRhs (ov, mkMVarCAS (cfg, et, mv, null, x))
            val suct = M.TBoolean
            val suc = TMU.localVariableFresh0 (im, suct)
            val blk1 = MS.bindRhs (suc, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable ov, et), (null, et)])
            val blk2 = tupleSimple ((state, rvar), [(s, st), (M.SVariable suc, suct)])
            val blk = MS.seqn [blk0, blk1, blk2]
          in blk
          end
        | _ => failMsg("tryPutMVar", "argument number mismatch")

  fun isEmptyMVar ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(mv, mvt), (s, st)] =>
          let
            val (mv, et) =
                case (mv, mvt)
                 of (M.SVariable mv, M.TTuple {fixed, ...}) => (mv, #1 (Vector.sub (fixed, 0)))
                  | _ => failMsg("tryTakeMVar", "MVar not variable of MVar type")
            val uvar = TMU.localVariableFresh0 (im, et)
            val blk0 = MS.bindRhs (uvar, mkMVarRead (cfg, et, mv))
            val rt = intTyp (Config.targetWordSize cfg)
            val r = TMU.localVariableFresh0 (im, rt)
            val rhs = rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable uvar, et), (null, et)]
            val blk1 = MS.bindRhs (r, rhs)
            val blk2 = tupleSimple ((state, rvar), [(s, st), (M.SVariable r, rt)])
            val blk = MS.seqn [blk0, blk1, blk2]
          in blk
          end
        | _ => failMsg("isEmptyMVar", "argument number mismatch")

  (* Delay/wait & async *)

  fun asyncRetTyp cfg =
      let
        val sintp = intTyp (Config.targetWordSize cfg)
        val f = (sintp, M.Vs8, M.FvReadOnly)
        val t = M.TTuple {pok = M.PokNone, fixed = Vector.new2 (f, f), array = (M.TNone, M.Vs8, M.FvReadOnly)}
      in (sintp, t)
      end

  fun asyncRead ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(fd, _), (sock, _), (num, _), (buf, _), (s, st)] =>
          let
            val (sintp, rt) = asyncRetTyp cfg
            val r = TMU.localVariableFresh0 (im, rt)
            val len = TMU.localVariableFresh0 (im, sintp)
            val ec = TMU.localVariableFresh0 (im, sintp)
            fun arTyp () =
                M.TCode {cc = M.CcCode, args = Vector.new4 (sintp, sintp, sintp, stablePtrTyp), ress = Vector.new1 rt}
            val (ar, _) = TMU.externVariable (state, pkgName, "ihrAsyncRead", arTyp)
            val call = M.CCode {ptr = ar, code = TMU.noCode}
            val b0 = MU.call (im, cfg, call, Vector.new4 (fd, sock, num, buf), TMU.noCut, Effect.IoS, Vector.new1 r)
            val fd = M.FD {kind = M.FkBits (FS.wordSize cfg), alignment = M.Vs8, var = M.FvReadOnly}
            val td = M.TD {fixed = Vector.new2 (fd, fd), array = NONE}
            val b1 = MS.bindRhs (len, M.RhsTupleSub (M.TF {tupDesc = td, tup = r, field = M.FiFixed 0}))
            val b2 = MS.bindRhs (ec, M.RhsTupleSub (M.TF {tupDesc = td, tup = r, field = M.FiFixed 1}))
            val b3 = tupleSimple ((state, rvar), [(s, st), (M.SVariable len, sintp), (M.SVariable ec, sintp)])
            val b = MS.seqn [b0, b1, b2, b3]
          in b
          end
        | _ => failMsg("asyncRead", "argument number mismatch")

  fun asyncWrite ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(fd, _), (sock, _), (num, _), (buf, _), (s, st)] =>
          let
            val (sintp, rt) = asyncRetTyp cfg
            val r = TMU.localVariableFresh0 (im, rt)
            val len = TMU.localVariableFresh0 (im, sintp)
            val ec = TMU.localVariableFresh0 (im, sintp)
            fun awTyp () =
                M.TCode {cc = M.CcCode, args = Vector.new4 (sintp, sintp, sintp, stablePtrTyp), ress = Vector.new1 rt}
            val (aw, _) = TMU.externVariable (state, pkgName, "ihrAsyncWrite", awTyp)
            val call = M.CCode {ptr = aw, code = TMU.noCode}
            val b0 = MU.call (im, cfg, call, Vector.new4 (fd, sock, num, buf), TMU.noCut, Effect.IoS, Vector.new1 r)
            val fd = M.FD {kind = M.FkBits (FS.wordSize cfg), alignment = M.Vs8, var = M.FvReadOnly}
            val td = M.TD {fixed = Vector.new2 (fd, fd), array = NONE}
            val b1 = MS.bindRhs (len, M.RhsTupleSub (M.TF {tupDesc = td, tup = r, field = M.FiFixed 0}))
            val b2 = MS.bindRhs (ec, M.RhsTupleSub (M.TF {tupDesc = td, tup = r, field = M.FiFixed 1}))
            val b3 = tupleSimple ((state, rvar), [(s, st), (M.SVariable len, sintp), (M.SVariable ec, sintp)])
            val b = MS.seqn [b0, b1, b2, b3]
          in b
          end
        | _ => failMsg("asyncWrite", "argument number mismatch")

  fun asyncDoProc ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(f, _), (p, _), (s, st)] =>
          let
            val ws = Config.targetWordSize cfg
            val sintp = intTyp ws
            val len = TMU.localVariableFresh0 (im, sintp)
            val ec = TMU.localVariableFresh0 (im, sintp)
            fun adpTyp () =
                M.TCode {cc = M.CcCode, args = Vector.new2 (stablePtrTyp, stablePtrTyp), ress = Vector.new1 sintp}
            val (adp, _) = TMU.externVariable (state, pkgName, "ihrAsyncDoProc", adpTyp)
            val call = M.CCode {ptr = adp, code = TMU.noCode}
            val b0 = MU.call (im, cfg, call, Vector.new2 (f, p), TMU.noCut, Effect.IoS, Vector.new1 ec)
            val zero = TMU.simpleInt (0, SOME (intArbTyp ws))
            val b1 = MS.bindRhs (len, M.RhsSimple zero)
            val b2 = tupleSimple ((state, rvar), [(s, st), (M.SVariable len, sintp), (M.SVariable ec, sintp)])
            val b = MS.seqn [b0, b1, b2]
          in b
          end
        | _ => failMsg("asyncDoProc", "argument number mismatch")

  fun threadStatus ((state as {im, cfg, ...}, rvar), argstyps) =
      case argstyps
       of [(t, _), (s, st)] =>
          let
            val ws = Config.targetWordSize cfg
            val sintp = intTyp ws
            val status = TMU.localVariableFresh0 (im, sintp)
            fun tsTyp () = M.TCode {cc = M.CcCode, args = Vector.new1 threadIdTyp, ress = Vector.new1 sintp}
            val (ts, _) = TMU.externVariable (state, pkgName, "ihrThreadStatus", tsTyp)
            val call = M.CCode {ptr = ts, code = TMU.noCode}
            val b0 = MU.call (im, cfg, call, Vector.new1 t, TMU.noCut, Effect.IoS, Vector.new1 status)
            val zero = TMU.simpleInt (0, SOME (intArbTyp ws))
            val b1 = tupleSimple ((state, rvar), [(s, st), (M.SVariable status, sintp), (zero, sintp), (zero, sintp)])
            val b = MS.seqn [b0, b1]
          in b
          end
        | _ => failMsg("threadStatus", "argument number mismatch")

  fun dataToTag ((state, rvar), argstyps) =
      case argstyps
        of [(tval, ttyp)] =>
         (case (tval, ttyp)
            of (M.SVariable tvar, M.TThunk vtyp) => (* as M.TSum { tag, ... })) => *)
              let
                val { cfg, im, effects, ... } = state
                val ws = Config.targetWordSize cfg
                val tagTyp = tagTyp ws
                val tagNumTyp = tagNumTyp ws
                val intNumTyp = intNumTyp ws
                val fk   = FK.fromTyp (cfg, vtyp)
                val vvar = TMU.localVariableFresh0 (im, vtyp)
                val wvar = TMU.localVariableFresh0 (im, tagTyp)
                val blk0 = TMU.kmThunk (state, Vector.new1 vvar, tvar, TMU.lookupEffect (effects, tvar, false, false))
                val blk1 = MS.bindRhs (wvar, M.RhsSumGetTag { typ = fk, sum = vvar })
                val blk2 = MS.bindsRhs (rvar, convert (tagNumTyp, intNumTyp) [(M.SVariable wvar, tagTyp)])
              in
                MS.seqn [blk0, blk1, blk2]
              end
            | _ => failMsg("dataToTag", "argument is not a thunk"))
         | _ => failMsg("dataToTag", "number of argument mismatch")

  fun tagToEnum ((state, rvar), argstyps) =
      case argstyps
        of [(tval, ttyp)] =>
          let
            val { cfg, im, ... } = state
          in
            MS.bindsRhs (rvar, M.RhsEnum { tag = tval , typ = FK.fromTyp (cfg, ttyp) })
          end
         | _ => failMsg("tagToEnum", "number of argument mismatch")


  (*
   * Stable pointers are remembered in a doubly linked list pointed to by a global
   * variable stableRoot.
   *)
  fun initStableRoot (im, cfg) =
      let
        val ws = Config.targetWordSize cfg
        val wordArbTyp = wordArbTyp ws
        val zero = TMU.simpleInt (0, SOME wordArbTyp)
        val rtyp = M.TTuple { pok = M.PokNone, fixed = stableRootTV, array = noneTF }
        val rvar = IM.variableFresh (im, "stableRoot", M.VI { typ = stableRootTyp, kind = M.VkGlobal })
        val mdd  = M.MDD { pok = M.PokNone, pinned = false, fixed = stableRootFD, array = NONE }
        val rval = M.GTuple { mdDesc = mdd, inits = Vector.new1 null }
      in
        (rvar, rval)
      end

  (*
   * Insert a stable pointer to the linked list pointed to by root: (in pseudo C)
   *   b = new { prev = null, value = v, next = root };
   *   if (root) root->prev = b;
   *   *root = b;
   *)
  fun insertToStableRoot (im, cfg, root, vval) =
      let
        val btyp = M.TTuple { pok = M.PokNone, fixed = stableBoxTV, array = noneTF }
        val isNull = TMU.localVariableFresh0 (im, M.TBoolean)
        val bvar = TMU.localVariableFresh0 (im, btyp)
        val rvar = TMU.localVariableFresh (im, "stableRoot", btyp)
        val blk0 = MS.bindRhs (rvar, M.RhsTupleSub (M.TF { tupDesc = stableRootTD, tup = root, field = M.FiFixed 0 }))
        val mdd  = M.MDD { pok = M.PokNone, pinned = true, fixed = stableBoxFD, array = NONE }
        val blk1 = MS.bindRhs (bvar, M.RhsTuple { mdDesc = mdd, inits = Vector.new3 (null, vval, M.SVariable rvar) })
        val blk2 = MS.bindRhs (isNull, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable rvar, M.TRef), (null, M.TRef)])
        val blkR = MS.doRhs (M.RhsTupleSet { tupField = M.TF { tupDesc = stableBoxTD, tup = rvar, field = M.FiFixed 0 }
                                           , ofVal = M.SVariable bvar })
        val blk3 = MU.whenFalse (im, cfg, M.SVariable isNull, blkR)
        val blk4 = MS.doRhs (M.RhsTupleSet { tupField = M.TF { tupDesc = stableRootTD, tup = root, field = M.FiFixed 0 }
                                           , ofVal = M.SVariable bvar })
      in
        (bvar, MS.seqn [blk0, blk1, blk2, blk3, blk4])
      end

  (*
   * Remove a stable pointer from the linked list pointed to by root: (in pseudo C)
   *   if (root == b) root = b->next;
   *   if (b->next) b->next->prev = b->prev;
   *   if (b->prev) b->prev->next = b->next;
   *   b->next = null;
   *   b->prev = null;
   *)
  fun removeFromStableRoot (im, cfg, root, bvar) =
      let
        val btyp = M.TTuple { pok = M.PokNone, fixed = stableBoxTV, array = noneTF }
        val rvar = TMU.localVariableFresh (im, "stableRoot", btyp)
        val next = TMU.localVariableFresh (im, "next", btyp)
        val prev = TMU.localVariableFresh (im, "prev", btyp)
        val isRoot   = TMU.localVariableFresh (im, "isroot",   M.TBoolean)
        val nextNull = TMU.localVariableFresh (im, "nextNull", M.TBoolean)
        val prevNull = TMU.localVariableFresh (im, "prevNull", M.TBoolean)
        val blk0 = MS.bindRhs (rvar, M.RhsTupleSub (M.TF { tupDesc = stableRootTD, tup = root, field = M.FiFixed 0 }))
        val blk1 = MS.bindRhs (prev, M.RhsTupleSub (M.TF { tupDesc = stableBoxTD, tup = bvar, field = M.FiFixed 0 }))
        val blk2 = MS.bindRhs (next, M.RhsTupleSub (M.TF { tupDesc = stableBoxTD, tup = bvar, field = M.FiFixed 2 }))
        val blk3 = MS.bindRhs (isRoot,   rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable rvar, M.TRef), (M.SVariable bvar, M.TRef)])
        val blk4 = MS.bindRhs (prevNull, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable prev, M.TRef), (null, M.TRef)])
        val blk5 = MS.bindRhs (nextNull, rhsPrim (MP.Prim MP.PPtrEq) [(M.SVariable next, M.TRef), (null, M.TRef)])
        val blkR = MS.doRhs (M.RhsTupleSet { tupField = M.TF { tupDesc = stableRootTD, tup = root, field = M.FiFixed 0}
                                           , ofVal = M.SVariable next })
        val blk6 = MU.whenTrue (im, cfg, M.SVariable isRoot, blkR)
        val blkN = MS.doRhs (M.RhsTupleSet { tupField = M.TF { tupDesc = stableBoxTD, tup = next, field = M.FiFixed 0}
                                           , ofVal = M.SVariable prev })
        val blk7 = MU.whenFalse (im, cfg, M.SVariable nextNull, blkN)
        val blkP = MS.doRhs (M.RhsTupleSet { tupField = M.TF { tupDesc = stableBoxTD, tup = prev, field = M.FiFixed 2}
                                           , ofVal = M.SVariable next })
        val blk8 = MU.whenFalse (im, cfg, M.SVariable prevNull, blkP)
        val blk9 = MS.doRhs (M.RhsTupleSet { tupField = M.TF { tupDesc = stableBoxTD, tup = bvar, field = M.FiFixed 0}
                                           , ofVal = null })
        val blk10= MS.doRhs (M.RhsTupleSet { tupField = M.TF { tupDesc = stableBoxTD, tup = bvar, field = M.FiFixed 2}
                                           , ofVal = null })
      in
        MS.seqn [blk0, blk1, blk2, blk3, blk4, blk5, blk6, blk7, blk8, blk9, blk10]
      end

  (* the following two functions are merely wrappers to ensure correct type for the externs *)
  fun castToAddr ((state, rvar), argstyps) =
      case argstyps
        of [(arg, _)] => extern Effect.Total "pLsrPrimCastToAddrzh" ((state, rvar), [(arg, refTyp)])
         | _ => failMsg("castToAddr", "number of argument mismatch")

  fun castFromAddr ((state, rvar), argstyps) =
      let
        val { im, cfg, ... } = state
        val uvar = TMU.localVariableFresh0 (im, refTyp)
        val (blk0, fx) = extern Effect.Total "pLsrPrimCastFromAddrzh" ((state, Vector.new1 uvar), argstyps)
        val blk1 = MS.bindsRhs (rvar, M.RhsSimple (M.SVariable uvar))
      in
        (MS.seq (blk0, blk1), fx)
      end

  fun newStablePtr ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (sval, styp)] =>
          let
            val { im, cfg, stableRoot, ... } = state
            val (bvar, blk0) = insertToStableRoot (im, cfg, stableRoot, arg)
            val pvar = TMU.localVariableFresh0 (im, stablePtrTyp)
            val (blk1, _) = castToAddr ((state, Vector.new1 pvar), [(M.SVariable bvar, refTyp)])
            val blk2 = tupleSimple ((state, rvar), [(sval, styp), (M.SVariable pvar, stablePtrTyp)])
          in
            MS.seqn [blk0, blk1, blk2]
          end
         | _ => failMsg("newStablePtr", "number of argument mismatch")

  fun readStablePtr ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (sval, styp)] =>
          let
            val { im, cfg, ... } = state
            val bvar = TMU.localVariableFresh0 (im, stableBoxTyp)
            val (blk0, _) = castFromAddr ((state, Vector.new1 bvar), [(arg, typ)])
            val rhstyps = [(M.RhsSimple sval, styp),
                           (M.RhsTupleSub (M.TF {tupDesc = stableBoxTD, tup = bvar, field = M.FiFixed 1}), refTyp)]
            val blk1 = tupleRhs ((state, rvar), rhstyps)
          in
            MS.seq (blk0, blk1)
          end
         | _ => failMsg("readStablePtr", "number of argument mismatch")

  fun freeStablePtr ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (sval, styp)] =>
          let
            val { im, cfg, stableRoot, ... } = state
            val bvar = TMU.localVariableFresh0 (im, stableBoxTyp)
            val (blk0, _) = castFromAddr ((state, Vector.new1 bvar), [(arg, typ)])
            val blk1 = removeFromStableRoot (im, cfg, stableRoot, bvar)
            val blk2 = MS.bindsRhs (rvar, M.RhsSimple sval)
          in
            MS.seqn [blk0, blk1, blk2]
          end
         | _ => failMsg("freeStablePtr", "number of argument mismatch")
  

  fun newWeakPtr ((state, rvar), argstyps) =
      case argstyps
        of [(key, ktyp), (value, vtyp), (M.SVariable finalizer, ftyp), 
            (sval as (M.SVariable svar), styp)] =>
          let
            val { im, cfg, ... } = state
            val wvar = TMU.localVariableFresh0 (im, weakPtrTyp)
            val ttyp = M.TThunk M.TRef
            val tthk = TMU.localVariableFresh0 (im, ttyp)
            val fvar = TMU.localVariableFresh0 (im, M.TRef)
            val isNull = TMU.localVariableFresh0 (im, M.TBoolean)
            val thk = TMU.localVariableFresh0 (im, refTyp)
            val blk0 = TMU.kmThunk (state, Vector.new1 fvar, finalizer, Effect.Heap)
            (* the return type is IO () *)
            val blk1 = MS.bindRhs (isNull, rhsPrim (MP.Prim MP.PPtrEq) 
                        [(M.SVariable fvar, M.TRef), (null, M.TRef)])
            val rTyps = Vector.new2 (M.TRef, styp)
            val blk2 = MU.ifBool (im, cfg, M.SVariable isNull,
                        (MS.empty, Vector.new1 null),
                        (TMU.mkThunk (state, thk, fvar, [svar], rTyps, Effect.Any), Vector.new1 (M.SVariable thk)), 
                        Vector.new1 tthk)
            fun rhfTyp () = M.TCode {cc = M.CcCode, args = Vector.new1 M.TRef, ress = Vector.new0 ()}
            val (rhf, rhft) = TMU.externVariable (state, pkgName, "ihrRunHaskellFinaliser", rhfTyp)
            val (blk3, _) = extern Effect.Heap "pLsrWpoNewWithRun" ((state, Vector.new1 wvar), 
                                [(key, ktyp), (value, vtyp), (M.SVariable tthk, ttyp), (M.SVariable rhf, rhft)])
            val blk4 = tupleSimple ((state, rvar), [(sval, styp), (M.SVariable wvar, weakPtrTyp)])
          in
            MS.seqn [blk0, blk1, blk2, blk3, blk4]
          end
         | _ => failMsg("newWeakPtr", "number of argument mismatch")

  fun newWeakPtrForeignEnv ((state, rvar), argstyps) =
      case argstyps
        of [(key, ktyp), (value, vtyp), (fval, ftyp), (M.SVariable pvar, ptyp), (ival, ityp), (M.SVariable evar, etyp),
            (sval as (M.SVariable svar), styp)] =>
          let
            val { im, cfg, ... } = state
            val ws = Config.targetWordSize cfg
            val intNumTyp = intNumTyp ws
            val intArbTyp = intArbTyp ws
            val intTyp = intTyp ws
            val wvar = TMU.localVariableFresh0 (im, weakPtrTyp)
            val fvar = TMU.localVariableFresh0 (im, ftyp)
            val fthk = TMU.localVariableFresh0 (im, M.TRef)
            (*
            (* closure without env *)
            val gtyp = M.TClosure { args = Vector.new1 ptyp, ress = Vector.new0 () }
            val gvar = TMU.localVariableFresh0 (im, gtyp)
            val gthk = TMU.localVariableFresh0 (im, M.TRef)
            val (blkNoEnv, _) = castFromAddr ((state, gvar), [(fval, ftyp)])
            val blkNoEnv = MS.seq (im, cfg, blkNoEnv, TMU.mkThunk (state, gthk, gvar, [pvar], NONE, Effect.Any))
            (* closure with env *)
            val htyp = M.TClosure { args = Vector.new2 (etyp, ptyp), ress = Vector.new0 () }
            val hvar = TMU.localVariableFresh0 (im, htyp)
            val hthk = TMU.localVariableFresh0 (im, M.TRef)
            val (blkWithEnv, _) = castFromAddr ((state, hvar), [(fval, ftyp)])
            val blkWithEnv = MS.seq (im, cfg, blkWithEnv, TMU.mkThunk (state, hthk, hvar, [evar, pvar], NONE, Effect.Any))
            val hasEnv = TMU.localVariableFresh0 (im, boolTyp)
            val blk0 = MS.bindRhs (im, cfg, hasEnv, compare (intNumTyp, MP.CEq)
                         [(ival, ityp), (TMU.simpleInt (1, intArbTyp), intTyp)])
            val blk1 = MSU.ifTrue (im, cfg, Vector.new1 fthk, M.SVariable hasEnv, 
                         (blkWithEnv, Vector.new1 (M.SVariable hthk)),
                         (blkNoEnv, Vector.new1 (M.SVariable gthk)))
            *)
            val blk1 = MS.bindRhs (fthk, M.RhsSimple null)
            val (blk2, _) = extern Effect.Heap "pLsrWpoNew" ((state, Vector.new1 wvar), 
                         [(key, ktyp), (value, vtyp), (M.SVariable fthk, M.TRef)])
            val blk3 = tupleSimple ((state, rvar), [(sval, styp), (M.SVariable wvar, weakPtrTyp)])
          in
            MS.seqn [ (*blk0,*) blk1, blk2, blk3]
          end
         | _ => failMsg("newWeakPtr", "number of argument mismatch")

  fun readWeakPtr ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (sval, styp)] =>
          let
            val { im, cfg, ... } = state
            val ws = Config.targetWordSize cfg
            val intTyp = intTyp ws
            val intPrec = intPrec ws
            val intNumTyp = intNumTyp ws
            val intArbTyp = intArbTyp ws
            val bvar = TMU.localVariableFresh0 (im, M.TRef)
            val (blk0, _) = extern Effect.Heap "pLsrWpoRead" ((state, Vector.new1 bvar), [(arg, typ)])
            val isNull = TMU.localVariableFresh0 (im, M.TBoolean)
            val blk1 = MS.bindRhs (isNull, rhsPrim (MP.Prim MP.PPtrEq) 
                         [(M.SVariable bvar, M.TRef), (null, M.TRef)])
            val pvar = TMU.localVariableFresh0 (im, intTyp)
            val blk2 = MU.ifBool (im, cfg, M.SVariable isNull, 
                         (MS.empty, Vector.new1 (TMU.simpleInt (0, SOME intArbTyp))),
                         (MS.empty, Vector.new1 (TMU.simpleInt (1, SOME intArbTyp))),
                         Vector.new1 pvar)
            val blk3 = tupleSimple ((state, rvar), [(sval, styp), (M.SVariable pvar, intTyp), (M.SVariable bvar, M.TRef)])
          in
            MS.seqn [blk0, blk1, blk2, blk3]
          end
         | _ => failMsg("readWeakPtr", "number of argument mismatch")

  (*
   * Our finalizeWeak# differs from GHC's in that it always returns a function
   * to run the finalizer (by evaluating the finalizer thunk) regardless of whether 
   * the finalizer has been run or not.
   *)
  fun finalizeWeakPtr ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (sval, styp)] =>
          let
            val { im, cfg, ... } = state
            val ws = Config.targetWordSize cfg
            val tagTyp = tagTyp ws
            val defaultTag = defaultTag ws
            val intTyp = intTyp ws
            val intPrec = intPrec ws
            val intNumTyp = intNumTyp ws
            val intArbTyp = intArbTyp ws
            val fvar = TMU.localVariableFresh0 (im, M.TRef)
            val pvar = TMU.localVariableFresh0 (im, typ)
            val qvar = TMU.localVariableFresh0 (im, styp)
            (* uvar is of type () *)
            val utyp = M.TSum { tag = tagTyp, arms = Vector.new0 () }
            val uvar = TMU.localVariableFresh0 (im, utyp)
            (* vvar is of type (# s, () #) *)
            val vvar = TMU.localVariableFresh0 (im, styp)
            val wvar = TMU.localVariableFresh0 (im, M.TThunk utyp)
            val gtyp = M.TClosure { args = Vector.new1 styp, ress = Vector.new2 (styp, M.TThunk utyp) }
            val gvar = TMU.localVariableFresh0 (im, gtyp)
            val (blk, _) = externDo0 Effect.Any "pLsrWpoFinalize" (state, [(M.SVariable pvar, typ)])
            val blk = MS.seq (blk, MS.bindRhs (uvar, 
                        M.RhsSum { tag = defaultTag , ofVals = Vector.new0 (), typs = Vector.new0 () }))
            val blk = MS.seq (blk, tupleRhs ((state, Vector.new2 (vvar, wvar)), 
                        [(M.RhsSimple (M.SVariable qvar), styp),
                         (M.RhsThunkValue { typ = FK.fromTyp (cfg, utyp)
                                          , thunk = NONE
                                          , ofVal = M.SVariable uvar }, M.TThunk utyp)]))
            val tr = M.TReturn (Vector.new2 (M.SVariable vvar, M.SVariable wvar))
            val afun = TMU.mkClosureFunction (state, fvar, M.TRef, true, false, Vector.new1 pvar, Vector.new1 qvar, 
                                              Vector.new2 (styp, M.TThunk utyp), blk, tr, Effect.Any) 
            val fvs = Vector.new1 (FK.fromTyp (cfg, typ), arg)
            val blk0 = MS.bindRhs (gvar, M.RhsClosureInit { cls = NONE, code = SOME afun, fvs = fvs })
            val blk1 = tupleRhs ((state, rvar), 
                         [(M.RhsSimple sval, styp), 
                          (M.RhsSimple (TMU.simpleInt (1, SOME intArbTyp)), intTyp), 
                          (M.RhsThunkValue { typ = FK.fromTyp (cfg, gtyp)
                                           , thunk = NONE
                                           , ofVal = M.SVariable gvar }, M.TThunk gtyp)])
          in
            MS.seq (blk0, blk1)
          end
         | _ => failMsg("finalizeWeakPtr", "number of argument mismatch")

  fun forceEval ((state, rvar), argstyps) =
      case argstyps
        of [(arg, typ), (sval, styp)] =>
          (case (arg, typ) 
            of (M.SVariable uvar, M.TThunk vtyp) =>
             let
               val { im, cfg, ... } = state
               val vvar = TMU.localVariableFresh0 (im, vtyp)
               val blk0 = TMU.kmThunk (state, Vector.new1 vvar, uvar, Effect.Control)
               val blk1 = tupleSimple ((state, rvar), [(sval, styp), (arg, typ)])
             in
               MS.seq (blk0, blk1)
             end
            | _ => failMsg("forceEval", "argument not a variable of thunk type"))
         | _ => failMsg("forceEval", "number of argument mismatch")

  infix 3 **  fun f ** g = fn x => [f x, g x]
  infix 3 &   fun f & g = fn x => (f x, g x)
  infix 4 |>  fun f |> g = fn (x, y) => f (x, (g y))

  fun prims cfg =
    let
      val ws = Config.targetWordSize cfg
      val wsbits = case ws of Config.Ws32 => 32 | Config.Ws64 => 64
      val intTyp = intTyp ws
      val intPrec = intPrec ws
      val intNumTyp = intNumTyp ws
      val intArbTyp = intArbTyp ws
      val wordTyp = wordTyp ws
      val wordPrec = wordPrec ws
      val wordArbTyp = wordArbTyp ws
      val wordNumTyp = wordNumTyp ws
      fun arith' (x, t) y = (arith x y, t)
      fun simpleIntRhs i argstyps = M.RhsSimple (TMU.simpleInt (i, SOME intArbTyp))
      fun simpleInt' (x, t) y = (simpleIntRhs x y, t)
      fun drop2nd l = List.first l :: tl (tl l)
      fun xt _ = Effect.Total
      fun xr _ = Effect.ReadOnly
      fun xw _ = Effect.Heap
      fun xrw _ = Effect.Heap
      fun xf _ = Effect.Control
      fun xh _ = Effect.Heap
      fun xa _ = Effect.Any
      fun xig _ = Effect.InitGenS
      fun xir _ = Effect.InitReadS
      fun xiw _ = Effect.InitWriteS
      fun xio _ = Effect.IoS
    in
     fn GtCharzh => singleB |> (compare (charNumTyp, MP.CLt) o List.rev) & xt
      | GeCharzh => singleB |> (compare (charNumTyp, MP.CLe) o List.rev) & xt
      | EqCharzh => singleB |> (compare (charNumTyp, MP.CEq)) & xt
      | NeCharzh => singleB |> (compare (charNumTyp, MP.CNe)) & xt
      | LtCharzh => singleB |> (compare (charNumTyp, MP.CLt)) & xt
      | LeCharzh => singleB |> (compare (charNumTyp, MP.CLe)) & xt
      | Ordzh => single |> (convert (charNumTyp, intNumTyp)) & xt
      | Integerzmzh => single |> (arith (integerNumTyp, MP.AMinus)) & xt
      | Integerzpzh => single |> (arith (integerNumTyp, MP.APlus)) & xt
      | Integerztzh => single |> (arith (integerNumTyp, MP.ATimes)) & xt
      | NegateIntegerzh => single |> (arith (integerNumTyp, MP.ANegate)) & xt
      | QuotIntegerzh => single |> (arith (integerNumTyp, MP.ADiv MP.DkT)) & xt
      | RemIntegerzh => single |> (arith (integerNumTyp, MP.AMod MP.DkT)) & xt
      | Integerzezezh => singleB |> (compare (integerNumTyp, MP.CEq)) & xt
      | Integerzszezh => singleB |> (compare (integerNumTyp, MP.CNe)) & xt
      | Integerzgzezh => singleB |> (compare (integerNumTyp, MP.CLe) o List.rev) & xt
      | Integerzgzh => singleB |> (compare (integerNumTyp, MP.CLt) o List.rev) & xt
      | Integerzlzezh => singleB |> (compare (integerNumTyp, MP.CLe)) & xt
      | Integerzlzh => singleB |> (compare (integerNumTyp, MP.CLt)) & xt
      | Int2Integerzh => single |> (convert (intNumTyp, integerNumTyp)) & xt
      | Int64ToIntegerzh => single |> (convert (int64NumTyp, integerNumTyp)) & xt
      | Word2Integerzh => single |> (convert (wordNumTyp, integerNumTyp)) & xt
      | Word64ToIntegerzh => single |> (convert (word64NumTyp, integerNumTyp)) & xt
      | Integer2Intzh => single |> (cast (integerNumTyp, intNumTyp)) & xt
      | Integer2Int64zh => single |> (cast (integerNumTyp, int64NumTyp)) & xt
      | Integer2Wordzh => single |> (cast (integerNumTyp, wordNumTyp)) & xt
      | Integer2Word64zh => single |> (cast (integerNumTyp, word64NumTyp)) & xt
      | Integer2Floatzh => single |> (cast (integerNumTyp, floatNumTyp)) & xt
      | Integer2Doublezh => single |> (cast (integerNumTyp, doubleNumTyp)) & xt
      | IntegerAndzh => single |> (bitwise (integerPrec, MP.BAnd)) & xt
      | IntegerOrzh => single |> (bitwise (integerPrec, MP.BOr)) & xt
      | IntegerXorzh => single |> (bitwise (integerPrec, MP.BXor)) & xt
      | IntegerIShiftLzh => single |> (bitwise (integerPrec, MP.BShiftL)) & xt
      | IntegerIShiftRzh => single |> (bitwise (integerPrec, MP.BShiftR)) & xt
      | IntegerEncodeFloatzh =>  single |> (convert (intNumTyp, floatNumTyp) o tl) & xt
      | IntegerEncodeDoublezh => single |> (convert (intNumTyp, doubleNumTyp) o tl) & xt
      | Zmzh => single |> (arith (intNumTyp, MP.AMinus)) & xt
      | Zpzh => single |> (arith (intNumTyp, MP.APlus)) & xt
      | Ztzh => single |> (arith (intNumTyp, MP.ATimes)) & xt
      | NegateIntzh => single |> (arith (intNumTyp, MP.ANegate)) & xt
      | QuotIntzh => single |> (arith (intNumTyp, MP.ADiv MP.DkT)) & xt
      | RemIntzh => single |> (arith (intNumTyp, MP.AMod MP.DkT)) & xt
      | Zezezh => singleB |> (compare (intNumTyp, MP.CEq)) & xt
      | Zszezh => singleB |> (compare (intNumTyp, MP.CNe)) & xt
      | Zgzezh => singleB |> (compare (intNumTyp, MP.CLe) o List.rev) & xt
      | Zgzh => singleB |> (compare (intNumTyp, MP.CLt) o List.rev) & xt
      | Zlzezh => singleB |> (compare (intNumTyp, MP.CLe)) & xt
      | Zlzh => singleB |> (compare (intNumTyp, MP.CLt)) & xt
      | Chrzh => single |> (cast (intNumTyp, charNumTyp)) & xt
      | Int2Wordzh => single |> (cast (intNumTyp, wordNumTyp)) & xt
      | Int2Word64zh => single |> (cast (intNumTyp, word64NumTyp)) & xt
      | Int2Floatzh => single |> (cast (intNumTyp, floatNumTyp)) & xt
      | Int2Doublezh => single |> (cast (intNumTyp, doubleNumTyp)) & xt
      | UncheckedIShiftLzh => withCast (intNumTyp, wordNumTyp, wordTyp, bitwise (wordPrec, MP.BShiftL)) & xt
      | UncheckedIShiftRAzh => single |> (bitwise (intPrec, MP.BShiftR)) & xt
      | UncheckedIShiftRLzh => withCast (intNumTyp, wordNumTyp, wordTyp, bitwise (wordPrec, MP.BShiftR)) & xt
      | AddIntCzh =>  tupleRhs |> (arith' ((intNumTyp, MP.APlus),  intTyp) ** simpleInt' (1, intTyp)) & xt
      | SubIntCzh =>  tupleRhs |> (arith' ((intNumTyp, MP.AMinus), intTyp) ** simpleInt' (1, intTyp)) & xt
      | MulIntMayOflozh => single |> (simpleIntRhs 1) & xt
      | MinusWordzh => single |> (arith (wordNumTyp, MP.AMinus)) & xt
      | PlusWordzh => single |> (arith (wordNumTyp, MP.APlus)) & xt
      | TimesWordzh => single |> (arith (wordNumTyp, MP.ATimes)) & xt
      | QuotWordzh => single |> (arith (wordNumTyp, MP.ADiv MP.DkT)) & xt
      | RemWordzh => single |> (arith (wordNumTyp, MP.AMod MP.DkT)) & xt
      | Andzh => single |> (bitwise (wordPrec, MP.BAnd)) & xt
      | Orzh => single |> (bitwise (wordPrec, MP.BOr)) & xt
      | Xorzh => single |> (bitwise (wordPrec, MP.BXor)) & xt
      | Notzh => single |> (bitwise (wordPrec, MP.BNot)) & xt
      | Word2Intzh => single |> (cast (wordNumTyp, intNumTyp)) & xt
      | GtWordzh => singleB |> (compare (wordNumTyp, MP.CLt) o List.rev) & xt
      | GeWordzh => singleB |> (compare (wordNumTyp, MP.CLe) o List.rev) & xt
      | EqWordzh => singleB |> (compare (wordNumTyp, MP.CEq)) & xt
      | NeWordzh => singleB |> (compare (wordNumTyp, MP.CNe)) & xt
      | LtWordzh => singleB |> (compare (wordNumTyp, MP.CLt)) & xt
      | LeWordzh => singleB |> (compare (wordNumTyp, MP.CLe)) & xt
      | UncheckedShiftLzh => single |> (bitwise (wordPrec, MP.BShiftL)) & xt
      | UncheckedShiftRLzh => single |> (bitwise (wordPrec, MP.BShiftR)) & xt
      | Narrow8Intzh => narrow (intNumTyp, int8NumTyp) & xt
      | Narrow16Intzh => narrow (intNumTyp, int16NumTyp) & xt
      | Narrow32Intzh => narrow (intNumTyp, int32NumTyp) & xt
      | Narrow8Wordzh => narrow (wordNumTyp, word8NumTyp) & xt
      | Narrow16Wordzh => narrow (wordNumTyp, word16NumTyp) & xt
      | Narrow32Wordzh => narrow (wordNumTyp, word32NumTyp) & xt
      | Zezezhzh => singleB |> (compare (doubleNumTyp, MP.CEq)) & xt
      | Zszezhzh => singleB |> (compare (doubleNumTyp, MP.CNe)) & xt
      | Zgzezhzh => singleB |> (compare (doubleNumTyp, MP.CLe) o List.rev) & xt
      | Zgzhzh => singleB |> (compare (doubleNumTyp, MP.CLt) o List.rev) & xt
      | Zlzezhzh => singleB |> (compare (doubleNumTyp, MP.CLe)) & xt
      | Zlzhzh => singleB |> (compare (doubleNumTyp, MP.CLt)) & xt
      | Zmzhzh => single |> (arith (doubleNumTyp, MP.AMinus)) & xt
      | Zpzhzh => single |> (arith (doubleNumTyp, MP.APlus)) & xt
      | Ztzhzh => single |> (arith (doubleNumTyp, MP.ATimes)) & xt
      | Zszhzh => single |> (arith (doubleNumTyp, MP.ADivide)) & xt
      | NegateDoublezh => single |> (arith (doubleNumTyp, MP.ANegate)) & xt
      | Double2Intzh => single |> (cast (doubleNumTyp, intNumTyp)) & xt
      | Double2Floatzh => single |> (cast (doubleNumTyp, floatNumTyp)) & xt
      | TanhDoublezh => single |> (floatOp (doublePrec, MP.FaTanH)) & xt
      | CoshDoublezh => single |> (floatOp (doublePrec, MP.FaCosH)) & xt
      | SinhDoublezh => single |> (floatOp (doublePrec, MP.FaSinH)) & xt
      | AtanDoublezh => single |> (floatOp (doublePrec, MP.FaATan)) & xt
      | LogDoublezh => single |> (floatOp (doublePrec, MP.FaLn)) & xt
      | ExpDoublezh => single |> (floatOp (doublePrec, MP.FaExp)) & xt
      | AcosDoublezh => single |> (floatOp (doublePrec, MP.FaACos)) & xt
      | AsinDoublezh => single |> (floatOp (doublePrec, MP.FaASin)) & xt
      | TanDoublezh => single |> (floatOp (doublePrec, MP.FaTan)) & xt
      | CosDoublezh => single |> (floatOp (doublePrec, MP.FaCos)) & xt
      | SinDoublezh => single |> (floatOp (doublePrec, MP.FaSin)) & xt
      | SqrtDoublezh => single |> (floatOp (doublePrec, MP.FaSqrt)) & xt
      | Ztztzhzh => single |> (floatOp (doublePrec, MP.FaPow)) & xt
      | DecodeDoublezu2Intzh => extern (xr ()) "pLsrPrimGHCDecodeDouble2Intzh"
      | EqFloatzh => singleB |> (compare (floatNumTyp, MP.CEq)) & xt
      | NeFloatzh => singleB |> (compare (floatNumTyp, MP.CNe)) & xt
      | GeFloatzh => singleB |> (compare (floatNumTyp, MP.CLe) o List.rev) & xt
      | GtFloatzh => singleB |> (compare (floatNumTyp, MP.CLt) o List.rev) & xt
      | LeFloatzh => singleB |> (compare (floatNumTyp, MP.CLe)) & xt
      | LtFloatzh => singleB |> (compare (floatNumTyp, MP.CLt)) & xt
      | MinusFloatzh => single |> (arith (floatNumTyp, MP.AMinus)) & xt
      | PlusFloatzh => single |> (arith (floatNumTyp, MP.APlus)) & xt
      | TimesFloatzh => single |> (arith (floatNumTyp, MP.ATimes)) & xt
      | DivideFloatzh => single |> (arith (floatNumTyp, MP.ADivide)) & xt
      | NegateFloatzh => single |> (arith (floatNumTyp, MP.ANegate)) & xt
      | Float2Intzh => single |> (cast (floatNumTyp, intNumTyp)) & xt
      | Float2Doublezh => single |> (convert (floatNumTyp, doubleNumTyp)) & xt
      | TanhFloatzh => single |> (floatOp (floatPrec, MP.FaTanH)) & xt
      | CoshFloatzh => single |> (floatOp (floatPrec, MP.FaCosH)) & xt
      | SinhFloatzh => single |> (floatOp (floatPrec, MP.FaSinH)) & xt
      | AtanFloatzh => single |> (floatOp (floatPrec, MP.FaATan)) & xt
      | LogFloatzh => single |> (floatOp (floatPrec, MP.FaLn)) & xt
      | ExpFloatzh => single |> (floatOp (floatPrec, MP.FaExp)) & xt
      | AcosFloatzh => single |> (floatOp (floatPrec, MP.FaACos)) & xt
      | AsinFloatzh => single |> (floatOp (floatPrec, MP.FaASin)) & xt
      | TanFloatzh => single |> (floatOp (floatPrec, MP.FaTan)) & xt
      | CosFloatzh => single |> (floatOp (floatPrec, MP.FaCos)) & xt
      | SinFloatzh => single |> (floatOp (floatPrec, MP.FaSin)) & xt
      | SqrtFloatzh => single |> (floatOp (floatPrec, MP.FaSqrt)) & xt
      | PowerFloatzh => single |> (floatOp (floatPrec, MP.FaPow)) & xt
      | DecodeFloatzuIntzh => extern (xr ()) "pLsrPrimGHCDecodeFloatzh"
      | PopCnt8zh => extern (xt ()) "pLsrPrimGHCPopCntzh"
      | PopCnt16zh => extern (xt ()) "pLsrPrimGHCPopCntzh"
      | PopCnt32zh => extern (xt ()) "pLsrPrimGHCPopCntzh"
      | PopCnt64zh => extern (xt ()) "pLsrPrimGHCPopCnt64zh"
      | PopCntzh => extern (xt ()) "pLsrPrimGHCPopCntzh"
      | NewArrayzh => newArray mutableRefFD & xh
      | ReadArrayzh => readArray (NONE, refTyp) & xh
      | WriteArrayzh => writeArray (NONE, refTyp) & xw
      | SameMutableArrayzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | IndexArrayzh => withoutState' (readArray (NONE, refTyp)) & xt
      | SizeofArrayzh => withoutState (sizeOfArray (mutableFD refTyp)) & xt
      | SizeofMutableArrayzh => withoutState (sizeOfArray (mutableFD refTyp)) & xr
      | UnsafeThawArrayzh => withState identityWithTy & xt
      | UnsafeFreezzeArrayzh => withState identityWithTy & xt
      | UnsafeFreezzeByteArrayzh => withState identityWithTy & xt
      | CopyArrayzh => copyArray & xw
      | CopyMutableArrayzh => copyMutableArray & xw
      | CopyByteArrayzh => copyByteArray & xw
      | CopyMutableByteArrayzh => copyMutableByteArray & xw
      | NewImmutableArrayzh => newImmutableArray & xig
      | NewStrictImmutableArrayzh => newStrictImmutableArray & xig
      | InitImmutableArrayzh => initImmutableArray & xiw
      | InitStrictImmutableArrayzh => initStrictImmutableArray & xiw
      | ImmutableArrayInitedzh => arrayInited & xiw
      | StrictImmutableArrayInitedzh => arrayInited & xiw
      | SizzeofImmutableArrayzh => withoutState sizeOfImmutableArray & xt
      | SizzeofStrictImmutableArrayzh => withoutState sizeOfImmutableArray & xt
      | IndexImmutableArrayzh => indexImmutableArray & xir
      | IndexStrictImmutableArrayzh => indexStrictImmutableArray & xir
      | NewUnboxedWordArrayzh => newUnboxedArray2 wordTyp & xig
      | NewUnboxedWord8Arrayzh => newUnboxedArray2 word8Typ & xig
      | NewUnboxedWord16Arrayzh => newUnboxedArray2 word16Typ & xig
      | NewUnboxedWord32Arrayzh => newUnboxedArray2 word32Typ & xig
      | NewUnboxedWord64Arrayzh => newUnboxedArray2 word64Typ & xig
      | NewUnboxedIntArrayzh => newUnboxedArray2 intTyp & xig
      | NewUnboxedInt8Arrayzh => newUnboxedArray2 int8Typ & xig
      | NewUnboxedInt16Arrayzh => newUnboxedArray2 int16Typ & xig
      | NewUnboxedInt32Arrayzh => newUnboxedArray2 int32Typ & xig
      | NewUnboxedInt64Arrayzh => newUnboxedArray2 int64Typ & xig
      | NewUnboxedFloatArrayzh => newUnboxedArray2 floatTyp & xig
      | NewUnboxedDoubleArrayzh => newUnboxedArray2 doubleTyp & xig
      | NewUnboxedCharArrayzh => newUnboxedArray2 charTyp & xig
      | NewUnboxedAddrArrayzh => newUnboxedArray2 addrTyp & xig
      | InitUnboxedWordArrayzh => initUnboxedArray NONE & xiw
      | InitUnboxedWord8Arrayzh => initUnboxedArray (SOME (wordNumTyp, word8NumTyp)) & xiw
      | InitUnboxedWord16Arrayzh => initUnboxedArray (SOME (wordNumTyp, word16NumTyp)) & xiw
      | InitUnboxedWord32Arrayzh => initUnboxedArray (SOME (wordNumTyp, word32NumTyp)) & xiw
      | InitUnboxedWord64Arrayzh => initUnboxedArray NONE & xiw
      | InitUnboxedIntArrayzh => initUnboxedArray NONE & xiw
      | InitUnboxedInt8Arrayzh => initUnboxedArray (SOME (intNumTyp, int8NumTyp)) & xiw
      | InitUnboxedInt16Arrayzh => initUnboxedArray (SOME (intNumTyp, int16NumTyp)) & xiw
      | InitUnboxedInt32Arrayzh => initUnboxedArray (SOME (intNumTyp, int32NumTyp)) & xiw
      | InitUnboxedInt64Arrayzh => initUnboxedArray NONE & xiw
      | InitUnboxedFloatArrayzh => initUnboxedArray NONE & xiw
      | InitUnboxedDoubleArrayzh => initUnboxedArray NONE & xiw
      | InitUnboxedCharArrayzh => initUnboxedArray NONE & xiw
      | InitUnboxedAddrArrayzh => initUnboxedArray NONE & xiw
      | UnboxedWordArrayInitedzh => arrayInited & xiw
      | UnboxedWord8ArrayInitedzh => arrayInited & xiw
      | UnboxedWord16ArrayInitedzh => arrayInited & xiw
      | UnboxedWord32ArrayInitedzh => arrayInited & xiw
      | UnboxedWord64ArrayInitedzh => arrayInited & xiw
      | UnboxedIntArrayInitedzh => arrayInited & xiw
      | UnboxedInt8ArrayInitedzh => arrayInited & xiw
      | UnboxedInt16ArrayInitedzh => arrayInited & xiw
      | UnboxedInt32ArrayInitedzh => arrayInited & xiw
      | UnboxedInt64ArrayInitedzh => arrayInited & xiw
      | UnboxedFloatArrayInitedzh => arrayInited & xiw
      | UnboxedDoubleArrayInitedzh => arrayInited & xiw
      | UnboxedCharArrayInitedzh => arrayInited & xiw
      | UnboxedAddrArrayInitedzh => arrayInited & xiw
      | SizeofUnboxedWordArrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedWord8Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedWord16Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedWord32Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedWord64Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedIntArrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedInt8Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedInt16Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedInt32Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedInt64Arrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedFloatArrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedDoubleArrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedCharArrayzh => withoutState sizeOfImmutableArray & xt
      | SizeofUnboxedAddrArrayzh => withoutState sizeOfImmutableArray & xt
      | IndexUnboxedWordArrayzh => indexUnboxedArray NONE & xir
      | IndexUnboxedWord8Arrayzh => indexUnboxedArray (SOME (word8NumTyp, wordNumTyp)) & xir
      | IndexUnboxedWord16Arrayzh => indexUnboxedArray (SOME (word16NumTyp, wordNumTyp)) & xir
      | IndexUnboxedWord32Arrayzh => indexUnboxedArray (SOME (word32NumTyp, wordNumTyp)) & xir
      | IndexUnboxedWord64Arrayzh => indexUnboxedArray NONE & xir
      | IndexUnboxedIntArrayzh => indexUnboxedArray NONE & xir
      | IndexUnboxedInt8Arrayzh => indexUnboxedArray (SOME (int8NumTyp, intNumTyp)) & xir
      | IndexUnboxedInt16Arrayzh => indexUnboxedArray (SOME (int16NumTyp, intNumTyp)) & xir
      | IndexUnboxedInt32Arrayzh => indexUnboxedArray (SOME (int32NumTyp, intNumTyp)) & xir
      | IndexUnboxedInt64Arrayzh => indexUnboxedArray NONE & xir
      | IndexUnboxedFloatArrayzh => indexUnboxedArray NONE & xir
      | IndexUnboxedDoubleArrayzh => indexUnboxedArray NONE & xir
      | IndexUnboxedCharArrayzh => indexUnboxedArray NONE & xir
      | IndexUnboxedAddrArrayzh => indexUnboxedArray NONE & xir
      | NewByteArrayzh => withState (newByteArray false) & xh
      | NewPinnedByteArrayzh => withState (newByteArray true) & xh
      | NewAlignedPinnedByteArrayzh => withState (newAlignedByteArray true) & xh
      | ByteArrayContentszh => extern (xt ()) "pLsrPrimGHCByteArrayContentszh"
      | SameMutableByteArrayzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | SizzeofByteArrayzh => sizeOfByteArray mutableByteFD & xt
      | SizzeofMutableByteArrayzh => sizeOfByteArray mutableByteFD & xt
      | NewUnboxedArrayzh => withState (newUnboxedArray false) & xh
      | NewPinnedUnboxedArrayzh => withState (newUnboxedArray true) & xh
      | NewAlignedPinnedUnboxedArrayzh => withState (newAlignedUnboxedArray true) & xh
      | IndexWord64Arrayzh => readArray (NONE, word64Typ) & xt
      | IndexWord32Arrayzh => readArray (SOME (word32NumTyp, wordArbTyp), word32Typ) & xt
      | IndexWord16Arrayzh => readArray (SOME (word16NumTyp, wordArbTyp), word16Typ) & xt
      | IndexWord8Arrayzh => readArray (SOME (word8NumTyp, wordArbTyp), word8Typ) & xt
      | IndexInt64Arrayzh => readArray (NONE, int64Typ) & xt
      | IndexInt32Arrayzh => readArray (SOME (int32NumTyp, intArbTyp), int32Typ) & xt
      | IndexInt16Arrayzh => readArray (SOME (int16NumTyp, intArbTyp), int16Typ) & xt
      | IndexInt8Arrayzh => readArray (SOME (int8NumTyp, intArbTyp), int8Typ) & xt
      | IndexWordArrayzh => readArray (NONE, wordTyp) & xt
      | IndexIntArrayzh => readArray (NONE, intTyp) & xt
      | IndexWideCharArrayzh => readArray (NONE, charTyp) & xt
      | IndexCharArrayzh => readArray (SOME (byteNumTyp, charArbTyp), byteTyp) & xt
      | IndexStablePtrArrayzh => readArray (NONE, stablePtrTyp) & xt
      | IndexDoubleArrayzh => readArray (NONE, doubleTyp) & xt
      | IndexFloatArrayzh => readArray (NONE, floatTyp) & xt
      | IndexAddrArrayzh => readArray (NONE, addrTyp) & xt
      | ReadWord64Arrayzh => readArray (NONE, word64Typ) & xr
      | ReadWord32Arrayzh => readArray (SOME (word32NumTyp, wordArbTyp), word32Typ) & xr
      | ReadWord16Arrayzh => readArray (SOME (word16NumTyp, wordArbTyp), word16Typ) & xr
      | ReadWord8Arrayzh => readArray (SOME (word8NumTyp, wordArbTyp), word8Typ) & xr
      | ReadInt64Arrayzh => readArray (NONE, int64Typ) & xr
      | ReadInt32Arrayzh => readArray (SOME (int32NumTyp, intArbTyp), int32Typ) & xr
      | ReadInt16Arrayzh => readArray (SOME (int16NumTyp, intArbTyp), int16Typ) & xr
      | ReadInt8Arrayzh => readArray (SOME (int8NumTyp, intArbTyp), int8Typ) & xr
      | ReadStablePtrArrayzh => readArray (NONE, stablePtrTyp) & xr
      | ReadDoubleArrayzh => readArray (NONE, doubleTyp) & xr
      | ReadFloatArrayzh => readArray (NONE, floatTyp) & xr
      | ReadAddrArrayzh => readArray (NONE, addrTyp) & xr
      | ReadWordArrayzh => readArray (NONE, wordTyp) & xr
      | ReadIntArrayzh => readArray (NONE, intTyp) & xr
      | ReadWideCharArrayzh => readArray (NONE, charTyp) & xr
      | ReadCharArrayzh => readArray (SOME (byteNumTyp, charArbTyp), byteTyp) & xr
      | WriteWord64Arrayzh => writeArray (NONE, word64Typ) & xw
      | WriteWord32Arrayzh => writeArray (SOME (wordNumTyp, word32NumTyp), word32Typ) & xw
      | WriteWord16Arrayzh => writeArray (SOME (wordNumTyp, word16NumTyp), word16Typ) & xw
      | WriteWord8Arrayzh => writeArray (SOME (wordNumTyp, word8NumTyp), word8Typ) & xw
      | WriteInt64Arrayzh => writeArray (NONE, int64Typ) & xw
      | WriteInt32Arrayzh => writeArray (SOME (intNumTyp, int32NumTyp), int32Typ) & xw
      | WriteInt16Arrayzh => writeArray (SOME (intNumTyp, int16NumTyp), int16Typ) & xw
      | WriteInt8Arrayzh => writeArray (SOME (intNumTyp, int8NumTyp), int8Typ) & xw
      | WriteStablePtrArrayzh => writeArray (NONE, stablePtrTyp) & xw
      | WriteDoubleArrayzh => writeArray (NONE, doubleTyp) & xw
      | WriteFloatArrayzh => writeArray (NONE, floatTyp) & xw
      | WriteAddrArrayzh => writeArray (NONE, addrTyp) & xw
      | WriteWordArrayzh => writeArray (NONE, wordTyp) & xw
      | WriteIntArrayzh => writeArray (NONE, intTyp) & xw
      | WriteWideCharArrayzh => writeArray (NONE, charTyp) & xw
      | WriteCharArrayzh => writeArray (SOME (charNumTyp, byteNumTyp), byteTyp) & xw
      | NullAddrzh => extern (xt ()) "pLsrPrimGHCNullAddrzh"
      | PlusAddrzh => extern (xt ()) "pLsrPrimGHCPlusAddrzh"
      | MinusAddrzh => extern (xt ()) "pLsrPrimGHCMinusAddrzh"
      | RemAddrzh => extern (xt ()) "pLsrPrimGHCRemAddrzh"
      | Addr2Intzh => extern (xt ()) "pLsrPrimGHCAddr2Intzh"
      | Int2Addrzh => extern (xt ()) "pLsrPrimGHCInt2Addrzh"
      | GtAddrzh => externB (xt ()) "pLsrPrimGHCGtAddrzh"
      | GeAddrzh => externB (xt ()) "pLsrPrimGHCGeAddrzh"
      | LtAddrzh => externB (xt ()) "pLsrPrimGHCLtAddrzh"
      | LeAddrzh => externB (xt ()) "pLsrPrimGHCLeAddrzh"
      | EqAddrzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | CastToAddrzh => castToAddr
      | CastFromAddrzh => castFromAddr
      | IndexWord64OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexUInt64OffAddrzh"
      | IndexWord32OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexUInt32OffAddrzh"
      | IndexWord16OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexUInt16OffAddrzh"
      | IndexWord8OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexUInt8OffAddrzh"
      | IndexInt64OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexInt64OffAddrzh"
      | IndexInt32OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexInt32OffAddrzh"
      | IndexInt16OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexInt16OffAddrzh"
      | IndexInt8OffAddrzh => extern (xt ()) "pLsrPrimGHCIndexInt8OffAddrzh"
      | IndexWordOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexUIntOffAddrzh"
      | IndexIntOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexIntOffAddrzh"
      | IndexWideCharOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexUIntOffAddrzh"
      | IndexStablePtrOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexAddrOffAddrzh"
      | IndexDoubleOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexDoubleOffAddrzh"
      | IndexFloatOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexFloatOffAddrzh"
      | IndexAddrOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexAddrOffAddrzh"
      | IndexCharOffAddrzh => extern (xt ()) "pLsrPrimGHCIndexUInt8OffAddrzh"
      | ReadWord64OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexUInt64OffAddrzh" , word64Typ)
      | ReadWord32OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexUInt32OffAddrzh" , wordTyp)
      | ReadWord16OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexUInt16OffAddrzh" , wordTyp)
      | ReadWord8OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexUInt8OffAddrzh"  , wordTyp)
      | ReadInt64OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexInt64OffAddrzh"  , int64Typ)
      | ReadInt32OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexInt32OffAddrzh"  , intTyp)
      | ReadInt16OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexInt16OffAddrzh"  , intTyp)
      | ReadInt8OffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexInt8OffAddrzh"   , intTyp)
      | ReadWordOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexUIntOffAddrzh"   , wordTyp)
      | ReadIntOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexIntOffAddrzh"    , intTyp)
      | ReadWideCharOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexUIntOffAddrzh"   , charTyp)
      | ReadStablePtrOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexAddrOffAddrzh"   , stablePtrTyp)
      | ReadDoubleOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexDoubleOffAddrzh" , doubleTyp)
      | ReadFloatOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexFloatOffAddrzh"  , floatTyp)
      | ReadAddrOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexAddrOffAddrzh"   , addrTyp)
      | ReadCharOffAddrzh => externWithState (xr ()) ("pLsrPrimGHCIndexUInt8OffAddrzh"  , charTyp)
      | WriteWord64OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteUInt64OffAddrzh"
      | WriteWord32OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteUInt32OffAddrzh"
      | WriteWord16OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteUInt16OffAddrzh"
      | WriteWord8OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteUInt8OffAddrzh"
      | WriteInt64OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteInt64OffAddrzh"
      | WriteInt32OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteInt32OffAddrzh"
      | WriteInt16OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteInt16OffAddrzh"
      | WriteInt8OffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteInt8OffAddrzh"
      | WriteWordOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteUIntOffAddrzh"
      | WriteIntOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteIntOffAddrzh"
      | WriteWideCharOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteUIntOffAddrzh"
      | WriteStablePtrOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteAddrOffAddrzh"
      | WriteDoubleOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteDoubleOffAddrzh"
      | WriteFloatOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteFloatOffAddrzh"
      | WriteAddrOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteAddrOffAddrzh"
      | WriteCharOffAddrzh => externWithStateDo (xw ()) "pLsrPrimGHCWriteUInt8OffAddrzh"
      | NewMutVarzh => withState newMutVar & xh
      | ReadMutVarzh => withState readMutVar & xr
      | WriteMutVarzh => withStateDo writeMutVar & xw
      | SameMutVarzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | CasMutVarzh => casMutVar & xrw
      | AtomicModifyMutVarzh => atomicModifyMutVar & xrw
      | NewTVarzh => withState newMutVar & xh
      | ReadTVarzh => withState readMutVar & xr
      | ReadTVarIOzh => withState readMutVar & xr
      | WriteTVarzh => withStateDo writeMutVar & xw
      | SameTVarzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | Atomicallyzh => applyFirst
      | Catchzh => catchzh & xa
      | Raisezh => raisezh & xf
      | RaiseIOzh => raiseIOzh & xf
      | MaskAsyncExceptionszh => applyFirst
      | MaskUninterruptiblezh => applyFirst
      | UnmaskAsyncExceptionszh => applyFirst
      | GetMaskingStatezh => withStateAndTy (simpleIntRhs 0, intTyp) & xt
      | NewMVarzh => withState newMVar & xh
      | TakeMVarzh => takeMVar & xrw
      | TryTakeMVarzh => tryTakeMVar & xrw
      | PutMVarzh => putMVar & xrw
      | TryPutMVarzh => tryPutMVar & xrw
      | SameMVarzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | IsEmptyMVarzh => isEmptyMVar & xr
      | Delayzh => externWithStateDo (xio ()) "ihrDelay"
      | WaitReadzh => externWithStateDo (xio ()) "ihrWaitRead"
      | WaitWritezh => externWithStateDo (xio ()) "ihrWaitWrite"
      | AsyncReadzh => asyncRead & xio
      | AsyncWritezh => asyncWrite & xio
      | AsyncDoProczh => asyncDoProc & xio
      | Forkzh => externWithState (xio ()) ("ihrFork", threadIdTyp)
      | ForkOnzh => externWithState (xio ()) ("ihrForkOn", threadIdTyp)
      | KillThreadzh => externWithStateDo (xio ()) "ihrKillThread"
      | Yieldzh => externWithStateDo (xio ()) "ihrYield"
      | MyThreadIdzh => externWithState (xio ()) ("ihrMyThreadId", threadIdTyp)
      | LabelThreadzh => externWithStateDo (xio ()) "ihrLabelThread"
      | IsCurrentThreadBoundzh => externWithState (xio ()) ("ihrIsCurrentThreadBound", intTyp)
      | NoDuplicatezh => externWithStateDo (xio ()) "ihrNoDuplicate"
      | ThreadStatuszh => threadStatus & xio
      | MkWeakzh => newWeakPtr & xh
      | MkWeakForeignEnvzh => newWeakPtrForeignEnv & xh
      | DeRefWeakzh => readWeakPtr & xr
      | FinalizzeWeakzh => finalizeWeakPtr & xa
      | Touchzh =>     externWithStateDo (xt ()) "pLsrPrimGHCTouchzh"
      | MakeStablePtrzh => newStablePtr & xh
      | DeRefStablePtrzh => readStablePtr & xt
      | FreeStablePtrzh => freeStablePtr & xh
      | EqStablePtrzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | ReallyUnsafePtrEqualityzh => singleB |> (rhsPrim (MP.Prim MP.PPtrEq)) & xt
      | Seqzh => forceEval & xf
      | DataToTagzh => dataToTag & (fn _ => Effect.Control)
      | TagToEnumzh => tagToEnum & xr
  end

  fun primOp (state, v, rvar, argstyps) =
      let 
        val { cfg, ...} = state
      in
        prims cfg v ((state, rvar), argstyps)
      end
end

