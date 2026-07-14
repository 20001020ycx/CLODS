#ifndef CONTROLDEPENDENCY_H
#define CONTROLDEPENDENCY_H

#include "llvm/Analysis/DependenceAnalysis.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/PassManager.h"

namespace llvm {

class ControlDependency : public llvm::AnalysisInfoMixin<ControlDependency>{

private:
  Instruction *analysisInstr;

  std::vector<BasicBlock *> dominatingBlocks;

public:
  using Result = std::vector<BasicBlock *>;

  // The identification key for pass registration
  static AnalysisKey Key;

  Result run(Function& F, FunctionAnalysisManager& FAM);

  ControlDependency() { };
  void printDebugLocForInstruction(Instruction &I);
  std::vector<BasicBlock *>
  getPostDominanceFrontier(BasicBlock &BB, Function &F, PostDominatorTree &PDT);
  BranchInst *getBlockCondition(BasicBlock &BB);
  void getDominatingConditions(BasicBlock &BB, Function &F,
                               PostDominatorTree &PDT,
                               std::vector<BasicBlock *> &alreadyVisited);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_UTILS_HELLOWORLD_H
