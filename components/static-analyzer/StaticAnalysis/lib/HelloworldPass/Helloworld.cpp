
#include "Helloworld.h"
using namespace llvm;

PreservedAnalyses HelloWorldPass::run(Module &M, ModuleAnalysisManager &MAM) {
  errs() << "Functions in the module:\n";
  for (Function &F : M) {
    errs() << "- " << F.getName() << "\n";
  }
  return PreservedAnalyses::all();
}