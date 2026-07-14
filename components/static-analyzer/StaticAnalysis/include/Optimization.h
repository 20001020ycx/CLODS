#ifndef OPTIMIZATION_H
#define OPTIMIZATION_H

#include <z3++.h>
#include "llvm/IR/InstrTypes.h"
#include "Utility.h"
#include "llvm/IR/PassManager.h"
#include "EventGraph/EventGraph.h"
#include "unordered_set"



void instrumentationOpt(llvm::EventNode* conditionEvent, llvm::FunctionAnalysisManager &FAM);


#endif