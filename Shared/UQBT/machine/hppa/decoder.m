/*==============================================================================
 * FILE:       decoder.m
 * OVERVIEW:   Implementation of the HP pa-risc specific parts of the
 *             NJMCDecoder class.
 *
 * Copyright (C) 2001, The University of Queensland, BT group
 *============================================================================*/

/* $Revision: 1.27 $
 *    Apr 01 - Simon: Created
 * 04 May 01 - Mike: Create RTLs not strings; moved addressing mode functions
 *                      here (from decoder_low.m)
 * 08 May 01 - Mike: New addressing modes for dis_addr handles "modify"
 * 09 May 01 - Mike: Match several logues; add idReg where needed; fixed ma
 *              addressing mode
 * 11 May 01 - Mike: Match branches as high level jumps
 * 13 May 01 - Mike: Fixed problems with B.l.n
 * 14 May 01 - Mike: Added some early code for cmpib_all
 * 17 May 01 - Mike: Added gcc frameless logues; handle non anulled CMPIB
 * 27 Jun 01 - Mike: B.l -> BL (1.1 opcode) etc; addressing modes too
 * 19 Jul 01 - Simon: Updated dis_addr(). Added dis_x_addr_shift().
 * 19 Jul 01 - Simon: Also got cmpibf working with various conditions.
 * 23 Jul 01 - Simon: Added cmpb_all and addr_ldisp_17_old
 * 01 Aug 01 - Mike: BL with no target register treated as branch, not call
 * 06 Aug 01 - Mike: Added ADD[I]B; removed getBump()
 * 07 Aug 01 - Mike: Added bare_ret, bare_ret_anulled patterns; some patterns
 *              are type DU now; fixed SCDAN cases
 * 07 Aug 01 - Simon: dis_addr() gone completely - [addr] => [xd,s,b]
 * 10 Aug 01 - Simon: added dis_c_bit(); added BB/BVB High Level Branches
 * 20 Aug 01 - Mike: Check for param_reloc1 pattern
 */

#include "global.h"
#include "proc.h"
#include "prog.h"
#include "decoder.h"
#include "ss.h"
#include "rtl.h"
#include "csr.h"
#include "hppa.pat.h"      // generated from `sparc.pat'
#include "hppa-names.h"    // generated by 'tools -fieldnames' - has
                            //   arrays of names of fields
#include "BinaryFile.h"     // For SymbolByAddress()


static const JCOND_TYPE hl_jcond_type[] = {
    HLJCOND_JNE, // no 'jump_never' enumeration for JCOND_TYPE
    HLJCOND_JE,
    HLJCOND_JSL,
    HLJCOND_JSLE,
    HLJCOND_JUL,
    HLJCOND_JULE,
    HLJCOND_JOF,
    HLJCOND_JNE, // no 'jump_if_odd' enumeration for JCOND_TYPE
    HLJCOND_JE,
    HLJCOND_JNE,
    HLJCOND_JSGE,
    HLJCOND_JSG,
    HLJCOND_JUGE,
    HLJCOND_JUG,
    HLJCOND_JNOF,
    HLJCOND_JE  // no 'jump_if_even' enumeration for JCOND_TYPE
};

// Handle the completer for the addr addressing mode
void c_addr(ADDRESS hostpc, SemStr* ssb, SemStr* ssx);

bool is_null(ADDRESS hostPC)
{
    bool res;
    match hostPC to
        | c_br_nnull() => {
            res = false;
        }
        | c_br_null() => {
            res = true;
        }
    endmatch

    return res;
}


DecodeResult& NJMCDecoder::decodeInstruction (ADDRESS pc, int delta,
    UserProc* proc /* = NULL */)
{ 
    static DecodeResult result;
    ADDRESS hostPC = pc+delta;

    // Clear the result structure;
    result.reset();

    // The actual list of instantiated RTs
    list<RT*>* RTs = NULL;
    preInstSem = NULL;          // No semantics before the instruction yet
    postInstSem = NULL;         // No semantics after the instruction yet

    ADDRESS nextPC;

    // Try matching a logue first.
    ADDRESS saveHostPC = hostPC;
    int addr, locals, libstub;
    Logue* logue;

    if ((logue = InstructionPatterns::std_call(csr,hostPC,addr)) != NULL) {
        /*
         * Ordinary call to fixed dest
         */
        HLCall* newCall = new HLCall(pc, 0, RTs);
        // Set the fixed destination. Note that addr is (at present!!) just
        // the offset in the instruction, so we have to add native pc
        newCall->setDest(addr + pc);
        result.numBytes = hostPC - saveHostPC;
        // See if this call is to a special symbol
        const char* dest = prog.pBF->SymbolByAddress((ADDRESS)(addr + pc));
        if (dest && (strcmp(dest, "__main") == 0)) {
            // Treat this as a NOP
        } else {

            result.rtl = newCall;
            result.type = SD;

            // Record the prologue of this caller
            newCall->setPrologue(logue);

            SHOW_ASM("std_call 0x" << hex << addr-delta)
        }
    }

    //
    // Callee prologues
    //
    else if ((logue = InstructionPatterns::gcc_frame(csr,hostPC, locals))
      != NULL) {
        /*
         * Standard prologue for gcc: sets up frame in %r3; optionally saves
         * several registers to the stack
         */
        if (proc != NULL) {

            // Record the prologue of this callee
            assert(logue->getType() == Logue::CALLEE_PROLOGUE);
            proc->setPrologue((CalleePrologue*)logue);
        }

        result.numBytes = hostPC - saveHostPC;
        result.rtl = new RTL(pc,RTs);
        result.type = NCT;
        SHOW_ASM("gcc_frame " << dec << locals)
    }
    else if ((logue = InstructionPatterns::gcc_frameless(csr,hostPC, locals))
      != NULL) {
        /*
         * Gcc prologue where optimisation is on, and no frame pointer is needed
         */
        if (proc != NULL) {

            // Record the prologue of this callee
            assert(logue->getType() == Logue::CALLEE_PROLOGUE);
            proc->setPrologue((CalleePrologue*)logue);
        }

        result.numBytes = hostPC - saveHostPC;
        result.rtl = new RTL(pc,RTs);
        result.type = NCT;
        SHOW_ASM("gcc_frameless " << dec << locals)
    }
    else if ((locals=8, logue = InstructionPatterns::param_reloc1(csr,hostPC,
      libstub, locals)) != NULL) {
        /*
         * Parameter relocation stub common when passing a double as the second
         * parameter to printf
         */
        if (proc != NULL) {
            // Record the prologue of this callee
            assert(logue->getType() == Logue::CALLEE_PROLOGUE);
            proc->setPrologue((CalleePrologue*)logue);
        }

        // The semantics of the first 3 instructions are difficult to translate
        // However, they boil down to these three, and the parameter analysis
        // should be able to use these:
        // *64* m[%afp + 0] = r[39];
        SemStr* ssSrc = new SemStr;
        SemStr* ssDst = new SemStr;
        *ssSrc << idRegOf << idIntConst << 39;
        *ssDst << idMemOf << idAFP;
        RTs = new list<RT*>;
        RTAssgn* pRt = new RTAssgn(ssDst, ssSrc, 64); RTs->push_back(pRt);
        // *32* r[23] := m[%afp    ];
        ssSrc = new SemStr; ssDst = new SemStr;
        *ssSrc << idMemOf << idAFP;
        *ssDst << idRegOf << idIntConst << 23;
        pRt = new RTAssgn(ssDst, ssSrc, 32);
        RTs->push_back(pRt);
        // *32* r[24] := m[%afp + 4];
        ssSrc = new SemStr; ssDst = new SemStr;
        *ssSrc << idMemOf << idPlus << idAFP << idIntConst << 4;
        *ssDst << idRegOf << idIntConst << 24;
        pRt = new RTAssgn(ssDst, ssSrc, 32); RTs->push_back(pRt);

        // Find the destination of the final jump. It starts 12 bytes later than
        // the pc of the whole pattern
        ADDRESS dest = pc + 12 + libstub;
        // Treat it like a call, followed by a return
        HLCall* newCall = new HLCall(pc, 0, RTs);
        // Set the fixed destination.
        newCall->setDest(dest);
        newCall->setReturnAfterCall(true);
        result.numBytes = hostPC - saveHostPC;
        result.rtl = newCall;
        result.type = SU;

        // Record the prologue of this caller (though it's the wrong type)
        newCall->setPrologue(logue);
        SHOW_ASM("param_reloc1 " << hex << dest)
    }

    //
    // Callee epilogues
    //
    else if ((logue = InstructionPatterns::gcc_unframe(csr, hostPC)) != NULL) {
        /*
         * Standard removal of current frame for gcc; optional restore of
         * several registers from stack
         */
        result.numBytes = hostPC - saveHostPC;
        result.rtl = new HLReturn(pc,RTs);
        result.type = DU;

        // Record the epilogue of this callee
        if (proc != NULL) {
            assert(logue->getType() == Logue::CALLEE_EPILOGUE);
            proc->setEpilogue((CalleeEpilogue*)logue);
        }
    
        SHOW_ASM("gcc_unframe");
    }
    else if ((logue = InstructionPatterns::gcc_unframeless1(csr, hostPC)) !=
      NULL) {
        /*
         * Removal of current frame for gcc (where no frame pointer was used)
         */
        result.numBytes = hostPC - saveHostPC;
        result.rtl = new HLReturn(pc,RTs);
        // Although the actual return instruction is a DD (Dynamic Delayed
        // branch), we call it a DU so the delay slot instruction is not decoded
        result.type = DU;

        // Record the epilogue of this callee
        if (proc != NULL) {
            assert(logue->getType() == Logue::CALLEE_EPILOGUE);
            proc->setEpilogue((CalleeEpilogue*)logue);
        }
    
        SHOW_ASM("gcc_unframeless1");
    }
    else if ((logue = InstructionPatterns::gcc_unframeless2(csr, hostPC)) !=
      NULL) {
        /*
         * Removal of current frame for gcc (where no frame pointer was used)
         */
        result.numBytes = hostPC - saveHostPC;
        result.rtl = new HLReturn(pc,RTs);
        result.type = DU;

        // Record the epilogue of this callee
        if (proc != NULL) {
            assert(logue->getType() == Logue::CALLEE_EPILOGUE);
            proc->setEpilogue((CalleeEpilogue*)logue);
        }
    
        SHOW_ASM("gcc_unframeless2");
    }
    else if ((logue = InstructionPatterns::bare_ret(csr, hostPC)) != NULL) {
        /*
         * Just a bare (non anulled) return statement
         */
        result.numBytes = 8;        // BV and the delay slot instruction
        result.rtl = new HLReturn(pc, RTs);
        // This is a DD instruction; the front end will decode the delay slot
        // instruction
        result.type = DD;

        // Record the epilogue of this callee
        if (proc != NULL) {
            assert(logue->getType() == Logue::CALLEE_EPILOGUE);
            proc->setEpilogue((CalleeEpilogue*)logue);
        }
    
        SHOW_ASM("bare_ret");
    }
    else if ((logue = InstructionPatterns::bare_ret_anulled(csr, hostPC))
      != NULL) {
        /*
         * Just a bare (anulled) return statement
         */
        result.numBytes = 4;        // BV only
        result.rtl = new HLReturn(pc, RTs);
        result.type = DU;       // No delay slot to decode

        // Record the epilogue of this callee
        if (proc != NULL) {
            assert(logue->getType() == Logue::CALLEE_EPILOGUE);
            proc->setEpilogue((CalleeEpilogue*)logue);
        }
    
        SHOW_ASM("bare_ret_anulled");
    }

    else {
        // Branches and other high level instructions
        match [nextPC] hostPC to
        | BL (nulli, ubr_target, t_06) => {
            HLJump* jump;
            // The return registers are 2 (standard) or 31 (millicode)
            if ((t_06 == 2) || (t_06 == 31))
                jump = new HLCall(pc, 0, RTs);
            if ((t_06 != 2) && (t_06 != 31))    // Can't use "else"
                jump = new HLJump(pc, RTs);
            result.rtl = jump;
            bool isNull = is_null(nulli);
            if (isNull)
                result.type = SU;
            if (!isNull)                        // Can't use "else"
                result.type = SD;
            jump->setDest(ubr_target + pc);     // This may change
            result.numBytes = 4;
        }
        
        | bb_all(c_cmplt, null_cmplt, r, bit_cmplt, target) => {
            int condvalue;
            SemStr* cond_ss = c_c(c_cmplt, condvalue);
            HLJcond* jump = new HLJcond(pc, RTs);
            jump->setDest(dis_Num(target + pc + 8));
            SemStr* reg = dis_Reg(r);
            SemStr* mask = dis_c_bit(bit_cmplt);
            SemStr* exp = new SemStr;
            *exp << idBitAnd << *mask << *reg;
            substituteCallArgs("c_c", cond_ss, mask, reg, exp);
            jump->setCondExpr(cond_ss);
            bool isNull = is_null(null_cmplt);
            result.type = isNull ? (((int)target >= 0) ? SCDAT : SCDAN) : SCD;
            result.rtl = jump;
            result.numBytes = 4;
        }
        
        | cmpib_all(c_cmplt, null_cmplt, im5_11, r_06, target) => {
            int condvalue;
            SemStr* cond_ss = c_c(c_cmplt, condvalue);
            HLJcond* jump = new HLJcond(pc, RTs);
            jump->setCondType(hl_jcond_type[condvalue]);
            jump->setDest(dis_Num(target + pc + 8));
            SemStr* imm = dis_Num(im5_11);
            SemStr* reg = dis_Reg(r_06);
            reg->prep(idRegOf);
            SemStr* exp = new SemStr;
            *exp << idMinus << *imm << *reg;
            substituteCallArgs("c_c", cond_ss, imm, reg, exp);
            jump->setCondExpr(cond_ss);
            bool isNull = is_null(null_cmplt);
            // If isNull, then taken forward or failing backwards anull
            result.type = isNull ? (((int)target >= 0) ? SCDAT : SCDAN) : SCD;
            result.rtl = jump;
            result.numBytes = 4;
        }

        | cmpb_all(c_cmplt, null_cmplt, r1, r2, target) => {
            int condvalue;
            SemStr* cond_ss = c_c(c_cmplt, condvalue);
            HLJcond* jump = new HLJcond(pc, RTs);
            jump->setCondType(hl_jcond_type[condvalue]);
            jump->setDest(dis_Num(target + pc + 8));
            SemStr* reg1 = dis_Reg(r1);
            SemStr* reg2 = dis_Reg(r2);
            reg1->prep(idRegOf);
            reg2->prep(idRegOf);
            SemStr* exp = new SemStr;
            *exp << idMinus << *reg1 << *reg2;
            substituteCallArgs("c_c", cond_ss, reg1, reg2, exp);
            jump->setCondExpr(cond_ss);
            bool isNull = is_null(null_cmplt);
            // If isNull, then taken forward or failing backwards anull
            result.type = isNull ? (((int)target >= 0) ? SCDAT : SCDAN) : SCD;
            result.rtl = jump;
            result.numBytes = 4;
        }
        | addib_all(c_cmplt, null_cmplt, im5_11, r_06, target)[name] => {
            int condvalue;
            SemStr* cond_ss = c_c(c_cmplt, condvalue);
            // Get semantics for the add part (only)
            RTs = instantiate(pc, name, dis_Num(im5_11), dis_Reg(r_06));
            HLJcond* jump = new HLJcond(pc, RTs);
            jump->setCondType(hl_jcond_type[condvalue]);
            jump->setDest(dis_Num(target + pc + 8));
            SemStr* imm = dis_Num(im5_11);
            SemStr* reg = dis_Reg(r_06);
            reg->prep(idRegOf);
            SemStr* tgt = new SemStr(*reg);      // Each actual is deleted
            substituteCallArgs("c_c", cond_ss, imm, reg, tgt);
            jump->setCondExpr(cond_ss);
            bool isNull = is_null(null_cmplt);
            // If isNull, then taken forward or failing backwards anull
            result.type = isNull ? (((int)target >= 0) ? SCDAT : SCDAN) : SCD;
            result.rtl = jump;
            result.numBytes = 4;
        }
        | MOVB (c_cmplt, null_cmplt, r1, r2, target)[name] => {
            int condvalue;
            SemStr* cond_ss = c_c(c_cmplt, condvalue);
            RTs = instantiate(pc, name, dis_Reg(r1), dis_Reg(r2));
            HLJcond* jump = new HLJcond(pc, RTs);
            jump->setCondType(hl_jcond_type[condvalue]);
            jump->setDest(dis_Num(target + pc + 8));
            SemStr* reg1 = dis_Reg(r1);
            SemStr* reg2 = dis_Reg(r2);
            reg1->prep(idRegOf);
            reg2->prep(idRegOf);
            SemStr* tgt = new SemStr(*reg2);
            substituteCallArgs("c_c", cond_ss, reg1, reg2, tgt);
            jump->setCondExpr(cond_ss);
            bool isNull = is_null(null_cmplt);
            result.type = isNull ? (((int)target >= 0) ? SCDAT : SCDAN) : SCD;
            result.rtl = jump;
            result.numBytes = 4;
        }
        | MOVIB (c_cmplt, null_cmplt, i, r, target)[name] => {
            int condvalue;
            SemStr* cond_ss = c_c(c_cmplt, condvalue);
            RTs = instantiate(pc, name, dis_Num(i), dis_Reg(r));
            HLJcond* jump = new HLJcond(pc, RTs);
            jump->setCondType(hl_jcond_type[condvalue]);
            jump->setDest(dis_Num(target + pc + 8));
            SemStr* imm = dis_Reg(i);
            SemStr* reg = dis_Reg(r);
            imm->prep(idIntConst);
            reg->prep(idRegOf);
            SemStr* tgt = new SemStr(*reg);
            substituteCallArgs("c_c", cond_ss, imm, reg, tgt);
            jump->setCondExpr(cond_ss);
            bool isNull = is_null(null_cmplt);
            result.type = isNull ? (((int)target >= 0) ? SCDAT : SCDAN) : SCD;
            result.rtl = jump;
            result.numBytes = 4;
        }
        | addb_all(c_cmplt, null_cmplt, r1, r2, target)[name] => {
            int condvalue;
            SemStr* cond_ss = c_c(c_cmplt, condvalue);
            // Get semantics for the add part (only)
            RTs = instantiate(pc, name, dis_Reg(r1), dis_Reg(r2));
            HLJcond* jump = new HLJcond(pc, RTs);
            jump->setCondType(hl_jcond_type[condvalue]);
            jump->setDest(dis_Num(target + pc + 8));
            SemStr* reg1 = dis_Reg(r1);
            SemStr* reg2 = dis_Reg(r2);
            reg1->prep(idRegOf);
            reg2->prep(idRegOf);
            SemStr* tgt = new SemStr(*reg2);      // Each actual is deleted
            substituteCallArgs("c_c", cond_ss, reg1, reg2, tgt);
            jump->setCondExpr(cond_ss);
            bool isNull = is_null(null_cmplt);
            // If isNull, then taken forward or failing backwards anull
            result.type = isNull ? (((int)target >= 0) ? SCDAT : SCDAN) : SCD;
            result.rtl = jump;
            result.numBytes = 4;
        }
        // The following two groups of instructions may or may not be anulling
        // (NCTA). If not, let the low level decoder take care of it.
        | arith(cmplt, r_11, r_06, t_27) => {
            // Decode the instruction
            low_level(RTs, hostPC, pc, result, nextPC);
            int condvalue;
            c_c(cmplt, condvalue);
            if (condvalue != 0)
                // Anulled. Need to decode the next instruction, and make each
                // RTAssgn in it conditional on !r[tmpNul]
                // We can't do this here, so we just make result.type equal to
                // NCTA, and the front end will do this for us
                result.type = NCTA;
            not_used(r_11); not_used(r_06); not_used(t_27);
        }
        | arith_imm(cmplt, imm11, r_06, t_11) => {
            // Decode the instruction
            low_level(RTs, hostPC, pc, result, nextPC);
            int condvalue;
            c_c(cmplt, condvalue);
            if (condvalue != 0)
                // Anulled. Need to decode the next instruction, and make each
                // RTAssgn in it conditional on !r[tmpNul]
                result.type = NCTA;
            not_used(imm11); not_used(r_06); not_used(t_11);
        } 
        else {
            // Low level instruction
            low_level(RTs, hostPC, pc, result, nextPC);
        }
        endmatch
    }
    return result;
}

// Let the low level decoder handle this instruction
void NJMCDecoder::low_level(list<RT*>*& RTs, ADDRESS hostPC, ADDRESS pc,
  DecodeResult& result, ADDRESS& nextPC)
{
    RTs = decodeLowLevelInstruction(hostPC, pc, result);
    if (preInstSem && RTs)
        RTs->insert(RTs->begin(), preInstSem->begin(), preInstSem->end());
    if (postInstSem && RTs)
        RTs->insert(RTs->end(), postInstSem->begin(), postInstSem->end());
    result.rtl = new RTL(pc, RTs);
    nextPC = hostPC + 4;        // 4 byte instruction
    result.numBytes = 4;
}

SemStr* NJMCDecoder::dis_c_bit(ADDRESS hostpc)
{
    SemStr* result;
    match hostpc to
        | c_bitpos_w(p) => {
            result = instantiateNamedParam( "bitpos_fix", dis_Num(p));
        }
        | c_bitsar() => {
            result = instantiateNamedParam( "bitpos_sar", dis_Num(0));
        }
    endmatch
    return result;
}

SemStr* NJMCDecoder::dis_xd(ADDRESS hostpc)
{
    SemStr* result;
    match hostpc to
      | x_addr_nots(x)   => {
            result = instantiateNamedParam( "x_addr_nots"   , dis_Reg(x));
      }
      | x_addr_s_byte(x) => {
            result = instantiateNamedParam( "x_addr_s_byte" , dis_Reg(x));
      }
      | x_addr_s_hwrd(x) => {
            result = instantiateNamedParam( "x_addr_s_hwrd" , dis_Reg(x));
      }
      | x_addr_s_word(x) => {
            result = instantiateNamedParam( "x_addr_s_word" , dis_Reg(x));
      }
      | x_addr_s_dwrd(x) => {
            result = instantiateNamedParam( "x_addr_s_dwrd" , dis_Reg(x));
      }
      | s_addr_im_r(i)   => {
            result = instantiateNamedParam( "s_addr_im_r"   , dis_Num(i));
      }
      | s_addr_r_im(i)   => {
            result = instantiateNamedParam( "s_addr_r_im"   , dis_Num(i));
      }
      | l_addr_16_old(i) => {
            result = instantiateNamedParam( "l_addr_16_old" , dis_Num(i));
      }
      | l_addr_17_old(i) => {
            result = instantiateNamedParam( "l_addr_17_old" , dis_Num(i));
      }
    endmatch
    return result;
}

/*==============================================================================
 * FUNCTION:        c_addr
 * OVERVIEW:        Processes completers for various addressing modes
 * NOTE:            I think we need to pass the base register to this function
 * PARAMETERS:      hostpc - the instruction stream address of the dynamic
 *                    address
 *                  ssb - SemStr* for the base register that gets modified
 *                  ssx - SemStr* for the amount to be added to ssb
 * RETURNS:         the SemStr representation of the given address
 *============================================================================*/
SemStr* NJMCDecoder::dis_c_addr(ADDRESS hostPC)
{
    SemStr* result = NULL;
    match hostPC to
        | c_s_addr_mb() =>
		 { result = instantiateNamedParam( "c_s_addr_mb" ); }
        | c_s_addr_ma() =>
	     { result = instantiateNamedParam( "c_s_addr_ma" ); }
        | c_s_addr_notm() =>
	     { result = instantiateNamedParam( "c_s_addr_notm" ); }
        | c_x_addr_m() =>
         { result = instantiateNamedParam( "c_x_addr_m" ); }
        | c_x_addr_notm() =>
         { result = instantiateNamedParam( "c_x_addr_notm" ); }
        | c_y_addr_e() =>
         { result = instantiateNamedParam( "c_y_addr_e" ); }
        | c_y_addr_m() =>
         { result = instantiateNamedParam( "c_y_addr_m" ); }
        | c_y_addr_me() =>
         { result = instantiateNamedParam( "c_y_addr_me" ); }
        | c_y_addr_none() =>
         { result = instantiateNamedParam( "c_y_addr_none" ); }
        | c_l_addr_none() =>
		 { result = instantiateNamedParam( "c_l_addr_none" ); }
    endmatch
    return result;
}

SemStr* NJMCDecoder::dis_c_wcr(unsigned hostPC)
{
    return 0;
}

SemStr* NJMCDecoder::dis_ct(unsigned hostPC)
{
    return 0;
}

SemStr* NJMCDecoder::dis_Freg(int regNum, int fmt)
{
    int r;          // Final register number
    switch (fmt) {
        case 0:     // SGL
            r = regNum + 64;
            break;
        case 1:     // DBL
            r = regNum + 32;
            break;
        case 2:     // QUAD
            r = regNum + 128;
            break;
        default:
            printf("Error decoding floating point register %d with format %d\n",
              regNum, fmt);
            r = 0;
    }
    SemStr* ss = new SemStr;
    *ss << idIntConst << r;
    return ss;
}

SemStr* NJMCDecoder::dis_Creg(int regNum)
{
    SemStr* ss = new SemStr;
    *ss << idIntConst << (regNum + 256);
    return ss;
}

SemStr* NJMCDecoder::dis_Sreg(int regNum)
{
    SemStr* ss = new SemStr;
    *ss << idIntConst << regNum;
    return ss;
}

/*==============================================================================
 * FUNCTION:      isFuncPrologue()
 * OVERVIEW:      Check to see if the instructions at the given offset match
 *                  any callee prologue, i.e. does it look like this offset
 *                  is a pointer to a function?
 * PARAMETERS:    hostPC - pointer to the code in question (native address)
 * RETURNS:       True if a match found
 *============================================================================*/
bool isFuncPrologue(ADDRESS hostPC)
{
#if 0
    int hiVal, loVal, reg, locals;
    if ((InstructionPatterns::new_reg_win(prog.csrSrc,hostPC, locals)) != NULL)
            return true;
    if ((InstructionPatterns::new_reg_win_large(prog.csrSrc, hostPC,
        hiVal, loVal, reg)) != NULL)
            return true;
    if ((InstructionPatterns::same_reg_win(prog.csrSrc, hostPC, locals))
        != NULL)
            return true;
    if ((InstructionPatterns::same_reg_win_large(prog.csrSrc, hostPC,
        hiVal, loVal, reg)) != NULL)
            return true;
#endif

    return false;
}

