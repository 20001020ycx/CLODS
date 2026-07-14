#ifndef A1D779DC_3C79_4219_8415_930CEFB9CB19
#define A1D779DC_3C79_4219_8415_930CEFB9CB19

#include <regex>

#include "Utility.h"
#include "EventGraph/EventGraph.h"
#include "Compare.h"
#include <string>


using namespace llvm;
void printDebugLocForInstruction(Instruction &I);
void printVariablesForInstruction(Instruction *cond);
void printInstrumentationPlan(std::vector<Instruction *> instructions,
                              FunctionAnalysisManager &FAM, int start_id = 0);
void printInstrumentationPlanForDataDeps(std::vector<Value *> values,
                                         FunctionAnalysisManager &FAM,
                                         std::vector<Value *> &instrIDToValue);
void printInstrumentationPlanAfterDataFlow(
    std::map<Value *, std::vector<Value *>> instrumentationBranches,
    FunctionAnalysisManager &FAM);
int compareAlgorithm(int &branchID);

#endif /* A1D779DC_3C79_4219_8415_930CEFB9CB19 */
