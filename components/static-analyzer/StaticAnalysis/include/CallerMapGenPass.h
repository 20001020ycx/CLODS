#ifndef BE654C25_9B56_45D6_83A5_22C625635AD6
#define BE654C25_9B56_45D6_83A5_22C625635AD6

#include "llvm/Analysis/CallGraph.h"
#include "llvm/Analysis/DependenceAnalysis.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/PassManager.h"

using namespace llvm;

class CallerMapGenPass : public PassInfoMixin<CallerMapGenPass> {
public:
  CallerMapGenPass(){};
  void CallerMapInitialization(CallGraph *CG);
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);
};

#endif /* BE654C25_9B56_45D6_83A5_22C625635AD6 */
