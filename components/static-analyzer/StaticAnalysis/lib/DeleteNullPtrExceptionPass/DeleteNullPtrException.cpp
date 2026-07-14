/*
 * Authors: ChenXing Yang
 * Descriptions:
 * Delete all uncatched basic block that throws NullPtrException
 * Considering the following java source code:
 * if (condition2) {
 *  if (condition 1) {
 *    Log.log()
 *  }
 *  throw ExceptionThatWeCare
 * }
 * When we convert the above java code into the LLVM IR, the following CFG is
 * established as Java will check the the pointer is null or not and throw the
 * NullPtrException if it is during run time.
 *                          BB1: cmp condition2
 *                                  |
 *                          BB2: cmp condition1
 *                              /        \
 *          BB3: check if log is Null     \
 *              /           \              \
 *  BB4: print log   BB5: NullPtrException  \
 *             \                           /
 *            BB6: throw ExceptionThatWeCare
 *
 * Depending on the condition of BB3, the program will either go to BB6 through
 * Bb4 or terminate the program through BB5. According to the static analysis
 * performed by Pensieve, we shall consider BB3 as the dominating block of BB6.
 *
 * HOWEVER, if we look closely at what BB4 and BB5 are doing, they are simply
 * NullPtrCheck that has nothing to do with our static anlaysis for bug
 * diagnosis. Therefore, it is better delete them for the sake of efficiency.
 */

#include "DeleteNullPtrException.h"

using namespace llvm;

#define DEBUG_TYPE "DeleteNullPtrExceptionPass"

// Currently, we only need to worry about the intra-procedural analysis.
// It is unlikely for a nullptrexception happens in a inter-procedural anaysis
// Note that we don't even need to look at the catch block for the intra-
// procedrual analysis as the exception throw name already convey the semantic
// Therefore, this pass can be extend beyond the DeleteNullPtrException, but
// delete general redundent function call
// #define ENABLE_INTERPROCEDURAL

namespace {

// utility function for printing
void PrintNullPtrExceptionBBToFuncMap(
    DenseMap<const BasicBlock *, const Function *>
        &NullPtrExceptionBBToFuncMap) {
  for (auto &NullPtrExceptionBBToFunc : NullPtrExceptionBBToFuncMap) {
    LLVM_DEBUG(debug(1) << "NullPtrException containing basic block: "
                      << *NullPtrExceptionBBToFunc.first << "\n");

    LLVM_DEBUG(debug(1) << "The basic block is within function: "
                      << NullPtrExceptionBBToFunc.second->getName() << "\n");
  }
}

}; // namespace

// Initialize the caller map for the entire module. This data structure is
// designed to answer question: given a specific function, who are its callers?
// void DeleteNullPtrExceptionPass::CallerMapInitialization(CallGraph *CG) {
//   assert(CG && "Call Graph is empty!");

//   for (auto &FuncMap : *CG) {
//     // FuncMap maps the function to call graph node
//     const Function *CurrFunc = FuncMap.first;
//     if (!CurrFunc) {
//       // skip external callers which are represented by nullptr
//       continue;
//     }

//     CallGraphNode *CGNode = FuncMap.second.get();
//     assert(CGNode && "CGNode is nullptr!");
//     for (auto &CallRecord : *CGNode) {
//       // callee of CurrFunc
//       if (Function *CalleeFunc = CallRecord.second->getFunction()) {
//         auto It = CallerMap.find(CalleeFunc);
//         if (It != CallerMap.end()) {
//           // Function FI is called by multiple caller
//           It->second.emplace_back(CurrFunc);
//           continue;
//         }
//         SmallVector<const Function *, 8> Callers;
//         Callers.emplace_back(CurrFunc);
//         CallerMap.try_emplace(CalleeFunc, Callers);
//       } else {
//         // external node
//       }
//     }
//   }
// }

// find all NullPtrExceptions -
// ImplicitExceptions_throwNewNullPointerException
// Note this include three possible scenarios:
// 1. uncatched NullPtrException contained in method with no caller such that
// there's no delegate for exception catch
// 2. uncatched NullPtrException contained in method whose caller chain has
// no catch block for the exception thrown
// 3. catched NullPtrException contained in method whose caller chain has
// catch block for the exception thrown

// Note that we do NOT need to concern catched NullPtrException contained in
// method with caller as it will raise another exception call -
// ImplicitExceptions_createNullPointerException
void DeleteNullPtrExceptionPass::FindAllNullPtrException(const Function &F) {

  for (const auto &BB : F) {
    for (const auto &I : BB) {
      if (auto *CallInstruction = dyn_cast<const CallInst>(&I)) {
        auto CallFunc = CallInstruction->getCalledFunction();
        if (!CallFunc || !CallFunc->hasName()) {
          // we don't care indirect invocation, or no name function
          continue;
        }

        StringRef CalledFuncName = CallFunc->getName();
        if (CalledFuncName.contains(RemoveFuncName)) {
          NullPtrExceptionBBToFuncMap.try_emplace(&BB, &F);
        }
      }
    }
  }
}

// Trace the call graph to examine if the NullPtrException are catched
// in the caller. That is we shall strip out the 2nd type we found on the
// above step
// bool DeleteNullPtrExceptionPass::StripCatchedExceptionInCaller(
//     const BasicBlock *ExceptionThrownBB, const Function *ExceptionThrownFunc)
//     {

//   auto It = CallerMap.find(ExceptionThrownFunc);
//   if (It == CallerMap.end()) {
//     // there is no caller, we can conclude that there is no catch block
//     // associated with the NullPtrException
//     return false;
//   }

//   // traverse all callers of the exception thrown function
//   bool isStrip = false;
//   for (const auto &Caller : It->second) {
//     for (const auto &BB : *Caller) {
//       for (const auto &I : BB) {
//         // Invoke inst in LLVM IR will interrupt the control and continue
//         // at the dynamically nearest exception label if the callee returns
//         // via the exception handling mechanism
//         if (auto *InvokeInstruction = dyn_cast<const InvokeInst>(&I)) {
//           if (InvokeInstruction->getCalledFunction() != ExceptionThrownFunc)
//           {
//             continue;
//           }
//           LLVM_DEBUG(dbgs() << "The invoked instruction is: "
//                             << *InvokeInstruction << "\n");

//           // check if the invoke_handler leads to an LLVMExceptionUnwind call
//           const BasicBlock *InvokeHandler =
//           InvokeInstruction->getUnwindDest(); const BasicBlock
//           *LLVMExceptionHandler =
//               InvokeHandler->getSingleSuccessor();
//           for (const auto &I : *LLVMExceptionHandler) {
//             if (const auto *CallInstruction = dyn_cast<const CallInst>(&I)) {
//               auto CallFunc = CallInstruction->getCalledFunction();
//               if (!CallFunc || !CallFunc->hasName()) {
//                 // we don't care indirect invocation, or no name function
//                 continue;
//               }

//               StringRef CalledFuncName = CallFunc->getName();
//               if (CalledFuncName.contains("LLVMExceptionUnwind")) {
//                 return true;
//               }
//             }
//           }
//         }
//       }
//     }

// if we don't find the catch block, we shall recursively check the
// chains of caller to examine whether the exception is catched.
// Note that we shall track the root BB which contains the original
// NullPtrExceptions rather than any other BB along the path. This helps
// us decide whether we can strip out it in the end or not
// Note, this look up should be conservative as this is an any-path
// problem: as long as there exists one instance of catch block, we say
// the exception is catched.

// isStrip |= StripCatchedExceptionInCaller(ExceptionThrownBB, Caller);
// }

// return isStrip;
// }

// transform function:
// delete all basic block contained the uncatched NullPtrException and edit the
// branch condition so that it will not direct the control flow to the deleting
// basic block
void DeleteNullPtrExceptionPass::DeleteNullPtrExceptionBB(Function &F) {
  DenseSet<BasicBlock *> DeleteBBs;
  DenseMap<BranchInst *, BranchInst *> UpdateBranchInsts;
  for (auto &BB : F) {
    if (NullPtrExceptionBBToFuncMap.find(&BB) != NullPtrExceptionBBToFuncMap.end()) {
      // coalesced nullptr exception, let's be conservative and not delete them.
      if (!BB.hasNPredecessors(1)) {
        continue;
      }
      // assert(isa<const UnreachableInst>(BB.getTerminator()) &&
      //        "NullPtrException is not unreachable");

      BasicBlock *PredecessorBB = BB.getSinglePredecessor();
      bool isDelete = false;
      for (auto &Inst : *PredecessorBB) {
        if (auto *BranchInstruction = dyn_cast<BranchInst>(&Inst)) {
          LLVM_DEBUG(debug(2)
                     << "the branch inst that leads to the deleting BB is: "
                     << *BranchInstruction << "\n");

          // TODO: this post-asssertion of null checking condition and branch
          // Instruction derivation before deleting it is NOT ELEGANT, hoist
          // this logic to where we examine the whether a BB is a
          // NullPtrException

          // The branch condition should be a null checking condition
          // we can release this contraint as we extend its generiosity

          // if (
          //   auto CmpInstruction = dyn_cast<const CmpInst>(
          //     BranchInstruction->getCondition()
          //   )
          // ) {
          //   auto CmpType = CmpInstruction->getPredicate();
          //   auto Operand = CmpInstruction->getOperand(1);
          //   assert(
          //     CmpType == CmpInst::ICMP_EQ &&
          //     isa<ConstantPointerNull>(Operand) &&
          //     "The dominating condition is not: \"EQUAL NULL\""
          //   );

          // }

          // update the branch condition from conditional to unconditional
          // since we will delete its true branch
          // Note that we don't need to worry about the cmp instruction as
          // it will be optimized away by deadcode elimination
          
          if ((BranchInstruction->getNumSuccessors()) == 1) {
            // Direct branch - don't delete, do nothing
            continue;
          }
          BasicBlock *NoExceptionBranch = BranchInstruction->getSuccessor(
              BranchInstruction->getSuccessor(0) == &BB);
          assert(NullPtrExceptionBBToFuncMap.find(NoExceptionBranch) == NullPtrExceptionBBToFuncMap.end() &&
                "The other branch cannot be an about to delete BB");
          BranchInst *DirectBranch = BranchInst::Create(NoExceptionBranch);
          UpdateBranchInsts.try_emplace(BranchInstruction, DirectBranch);
          LLVM_DEBUG(debug(2) << "the branch inst after updating: "
                            << *DirectBranch << "\n");
          isDelete = true;
        }
      }
      LLVM_DEBUG(debug(2) << "deleting BB is: " << BB << "\n");
      if (isDelete) DeleteBBs.insert(&BB);
    }
  }

  for (auto &UpdateBranchInst : UpdateBranchInsts)
    ReplaceInstWithInst(UpdateBranchInst.first, UpdateBranchInst.second);

  for (auto &DeleteBB : DeleteBBs)
    DeleteBB->eraseFromParent();
}

void DeleteNullPtrExceptionPass::IRDump(Function &F, bool IO) {
  bool dumpIR = false;
  for (size_t i = 0; i < CLODSManager.debugOnlyPasses.size(); ++i) {
    if (CLODSManager.debugOnlyPasses[i] == "DeleteNullPtrExceptionPass") {
      dumpIR = true;
    }
  }
  if (!dumpIR) return;

  // Access the module's IR
  std::string IRString;
  raw_string_ostream OS(IRString);
  F.print(OS, nullptr);

  // Output the IR to a file
  std::ofstream outputFile(std::string("Remove_") + RemoveFuncName.str() +
                           (IO ? "Out" : "In") + ".ll");
  outputFile << IRString;
  outputFile.close();
}

// Module Pass Execution Entry.
PreservedAnalyses
DeleteNullPtrExceptionPass::run(Function &F, FunctionAnalysisManager &FAM) {
  // create a call graph for inter-procedural analysis
#ifdef ENABLE_INTERPROCEDURAL
  CallGraph *CG = &MAM.getResult<CallGraphAnalysis>(M);
  CallerMapInitialization(CG);
#endif

  // find all NullPtrException in the given module (which ideally should be
  // linked as a monolithic module)
  if (this->runOnFunc->isDeclaration()) {
    return PreservedAnalyses::all();
  }

  // push BB that throws NullPtrException into the map
  // (BB to containing method) within this procedure
  // (an intra-procedural analysis)
  FindAllNullPtrException(*(this->runOnFunc));

  PrintNullPtrExceptionBBToFuncMap(NullPtrExceptionBBToFuncMap);

  // Analyze NullPtrExceptionBBToFuncMap and strip out that exception that is
  // catched by the caller (an inter-procedural analysis)
#ifdef ENABLE_INTERPROCEDURAL
  for (auto &NullPtrExceptionBBToFunc : NullPtrExceptionBBToFuncMap) {
    if (StripCatchedExceptionInCaller(NullPtrExceptionBBToFunc.first,
                                      NullPtrExceptionBBToFunc.second)) {
      NullPtrExceptionBBToFuncMap.erase(NullPtrExceptionBBToFunc.first);
    }
  }

  LLVM_DEBUG(
      dbgs() << "Stripping out catched exception in caller finished\n\n");

  PrintNullPtrExceptionBBToFuncMap(NullPtrExceptionBBToFuncMap);
#endif

  // Transformation: delete all BB that contains NullPtrException without a
  // catch block.
  DeleteNullPtrExceptionBB(*(this->runOnFunc));

  IRDump(F, OUTPUT);

  return PreservedAnalyses::all();
}
