#ifndef DELETENULLPTREXCEPTION_H
#define DELETENULLPTREXCEPTION_H

#include "llvm/ADT/StringRef.h"
#include "llvm/Analysis/CallGraph.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include "llvm/Pass.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "Utility.h"

#include <fstream>

using namespace llvm;

class DeleteNullPtrExceptionPass
    : public PassInfoMixin<DeleteNullPtrExceptionPass> {
private:
  // Function name we are about to delete
  StringRef RemoveFuncName;

  // Function that we are running the pass on
  Function *runOnFunc;

  // Map between basic block that throws null ptr exception and the function
  // it is contained
  DenseMap<const BasicBlock *, const Function *> NullPtrExceptionBBToFuncMap;

  // Map between a given function within the module and its callers

  enum { INPUT, OUTPUT };

  void CallerMapInitialization(CallGraph *CG);

  void FindAllNullPtrException(const Function &F);

  bool StripCatchedExceptionInCaller(const BasicBlock *ExceptionThrownBB,
                                     const Function *ExceptionThrownFunc);

  void DeleteNullPtrExceptionBB(Function &F);

  void IRDump(Function &M, bool IO);

public:
  // TODO, rename the pass to be RemoveUnreachableBB as its functionality can
  // be extended if we only target at intra-procedural analysis of NullPtr-
  // Exception deletion
  DeleteNullPtrExceptionPass(StringRef FuncName, Function &runOnFunc)
      : RemoveFuncName(FuncName) {
    this->runOnFunc = &runOnFunc;
  };
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

#endif