#include "CallerMapGenPass.h"

DenseMap<const Function *, SmallVector<const Function *, 8>> CallerMap;

void CallerMapGenPass::CallerMapInitialization(CallGraph *CG) {
  assert(CG && "Call Graph is empty!");

  for (auto &FuncMap : *CG) {
    // FuncMap maps the function to call graph node
    const Function *CurrFunc = FuncMap.first;
    if (!CurrFunc) {
      // skip external callers which are represented by nullptr
      continue;
    }

    CallGraphNode *CGNode = FuncMap.second.get();
    assert(CGNode && "CGNode is nullptr!");
    for (auto &CallRecord : *CGNode) {
      // callee of CurrFunc
      if (Function *CalleeFunc = CallRecord.second->getFunction()) {
        auto It = CallerMap.find(CalleeFunc);
        if (It != CallerMap.end()) {
          // Function FI is called by multiple caller
          It->second.emplace_back(CurrFunc);
          continue;
        }
        SmallVector<const Function *, 8> Callers;
        Callers.emplace_back(CurrFunc);
        CallerMap.try_emplace(CalleeFunc, Callers);
      } else {
        // external node
      }
    }
  }
}

PreservedAnalyses CallerMapGenPass::run(Module &M, ModuleAnalysisManager &MAM) {

  CallGraph *CG = &MAM.getResult<CallGraphAnalysis>(M);
  CallerMapInitialization(CG);
  return PreservedAnalyses::all();
}
