#ifndef DATADEPENDENCY_H
#define DATADEPENDENCY_H

#include "llvm/Analysis/DependenceAnalysis.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/PassManager.h"

using namespace llvm;

class DataDependency : public llvm::AnalysisInfoMixin<DataDependency>{
private:
  Value *analysisValue;

public:
  using Result = std::vector<Value *>;

  static AnalysisKey Key;

  Result run(Function &F, FunctionAnalysisManager &AM);

  DataDependency() { };
};

#endif