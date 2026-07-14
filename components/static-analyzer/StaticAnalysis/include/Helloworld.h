#ifndef LLVM_TRANSFORMS_UTILS_YOURHELLOWORLD_H
#define LLVM_TRANSFORMS_UTILS_YOURHELLOWORLD_H
#include "llvm/IR/Function.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Pass.h"

using namespace llvm;

class HelloWorldPass : public PassInfoMixin<HelloWorldPass> {
public:
  HelloWorldPass(){};
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);
};

#endif