#include "Optimization.h"

#define DEBUG_TYPE "OptimizationPass"

using namespace llvm;

extern std::vector<Value *> instrumentationValues;
extern std::map<Value *, std::vector<Value *>> instrumentationBranches;

// Same logic as optimizeAwayCheck but using z3 SAT solver
// Note: using SAT solver is an overkill,
bool optimizeAwaySATCheck(
  CmpInst::Predicate CmpType, int constantValue, int constInsertedValue, bool isHappened
) {
  z3::context ctx;

  // Assign values to variables (example values)
  z3::expr isHappenedSAT = ctx.bool_val(isHappened);
  z3::expr constInsertedValueSAT = ctx.int_val(constInsertedValue);
  z3::expr constantValueSAT = ctx.int_val(constantValue);

  // Build Z3 expression
  z3::expr expr(ctx);
  if (CmpType == CmpInst::Predicate::ICMP_SLT) {
     expr = (!isHappenedSAT && (constInsertedValueSAT >= constantValueSAT)) ||
                  (isHappenedSAT && (constInsertedValueSAT < constantValueSAT));
  } else if (CmpType == CmpInst::Predicate::ICMP_EQ) {
     expr = (!isHappenedSAT && (constInsertedValueSAT != constantValueSAT)) ||
            (isHappenedSAT && (constInsertedValueSAT == constantValueSAT));
  }

  // Create Z3 solver
  z3::solver solver(ctx);
  solver.add(expr);

  switch (solver.check()) {
      case z3::sat:
          return true;
      case z3::unsat:
          return false;
      case z3::unknown:
          return false;
  }

  return false;
}

// true means to optimize the instruction as it cannot constitute to the bug
bool optimizeAwayCheck(
  CmpInst::Predicate CmpType, int constantValue, int constInsertedValue, bool isHappened
) {
  if (CmpType == CmpInst::Predicate::ICMP_SLT) {
    return (!isHappened && (constInsertedValue >= constantValue)) ||
            (isHappened && (constInsertedValue < constantValue));
  } else if (CmpType == CmpInst::Predicate::ICMP_EQ) {
     return (!isHappened && (constantValue != constInsertedValue)) ||
            (isHappened && (constantValue == constInsertedValue));
  }

  return false;
}


// This function perform data flow analysis on LLVM register for which is used
// in the compare instruction. 
// isQualifyOptimization is passed in as a reference to symbolize whether the 
// optimization is performed or given up. We voluntarily give up the chance of 
// optimization in the following two cases:
//  1. There is no constant found - we couldn't determine the value of register
//     during static code analysis
//  2. There are multiple definition - TODO: we shall check them one by one to 
//     see if they reach consensus with one another. For now, we just give up
//     the optimization for simplicity
int optDataFlowAnalysis(Value* val, FunctionAnalysisManager &FAM, bool &isQualifyOptimization){
  std::stack<Value* > s;
  std::vector<int> reachableConstants;
  std::unordered_set<Value* > visitedValues;
  s.push(val);

  while (!s.empty()) {
    Value* top = s.top();
    s.pop();
    if (visitedValues.count(top)) continue;
    visitedValues.insert(top);
    

    LLVM_DEBUG(debug(3) << "Opt data flow is processing: " << *top << '\n');

    // TODO: this shall be further generalized once we proceed with other bugs
    if (auto returnInst = dyn_cast<ReturnInst>(top)) {
      s.push(returnInst->getReturnValue());
    } else if (auto insertValueInst = dyn_cast<InsertValueInst>(top)) {
      s.push(insertValueInst->getInsertedValueOperand());
    } else if ((isa<CallInst>(top)) || (isa<InvokeInst>(top))) {
      Function *calledFunction = getCalledFunction(top);
      // Ignore null functions or functions with no name
      if (!calledFunction || !calledFunction->hasName()) {
        continue;
      }
      LLVM_DEBUG(debug(3) << "Opt data flow: Function being called "
                          << calledFunction->getName() << "\n");
      //cleanFunction(calledFunction, FAM);
      std::vector<Value *> returnVals = getReturnInstructionsOfFunction(*calledFunction);
      for (auto returnVal : returnVals)
        s.push(returnVal);
    } else if (auto extractValueInst = dyn_cast<ExtractValueInst>(top)) {
      s.push(extractValueInst->getAggregateOperand());
    } else if (ConstantInt* constantInt = dyn_cast<ConstantInt>(top)) {
      reachableConstants.push_back(constantInt->getValue().getSExtValue());
    } else if (Instruction *instr = dyn_cast<Instruction>(top)) {
      // general instruction:
      for (auto &U : instr->operands()) {
        // Constant used in general instruction shall not be permitted; they are
        // used for instruction itself rather than variable definition
        // such as add %1, -1
        if (isa<Constant>(U)) {
          continue;
        }

        s.push(U);
      }
    }
  }

  if (reachableConstants.empty()) {
    // return value is not important, setting optimization qualification to false
    isQualifyOptimization = false;
    return 0; 
  }
  for (auto reachableConstant : reachableConstants) {
    LLVM_DEBUG(debug(1) << "Reachable constants are: " << reachableConstant << "\n");
  }

  // check if all elements are same. 
  if (std::adjacent_find(
      reachableConstants.begin(), reachableConstants.end(), 
      std::not_equal_to<int>()) == reachableConstants.end()
     ) {
    return reachableConstants[0];
  } else {
    isQualifyOptimization = false;
    return 0;
  }

}

void instrumentationOpt(EventNode* conditionEvent, FunctionAnalysisManager &FAM) {
  LLVM_DEBUG(debug(1) << "Optimization Bootstrap\n");
  if (!isa<BranchInst>(conditionEvent->getValue())) {
    // condition event does not necessarily be a branch statement as we may 
    // continue the data flow analysis if there's no divergent point
    LLVM_DEBUG(debug(3) << "Condition event does not contain a branch instruction!\n");
    return;
  }
  BranchInst* branchInst = cast<BranchInst>(conditionEvent->getValue());
  Value* condition = branchInst->getCondition();
  CmpInst* cmpInst = cast<CmpInst>(condition);
  LLVM_DEBUG(debug(2) << "Compare inst is: " << *cmpInst << "\n");

  // extract compare constant
  Value* cmpOperand = cmpInst->getOperand(1);
  int constantValue;
  if (ConstantInt* constantInt = dyn_cast<ConstantInt>(cmpOperand)) {
    constantValue = constantInt->getValue().getSExtValue();
    LLVM_DEBUG(debug(3) << "Constant Value: " << constantValue << "\n");
  } else {
    LLVM_DEBUG(debug(3) << "Handling variable comparing operand: " << *cmpOperand << "\n");
    // We are comparing the variable: we shall provide best-effort look up
    // to see if there's a deterministic constant associated with the register
    // using the function mentioned above
    bool isQualifyOptimization = true;
    constantValue = optDataFlowAnalysis(cmpOperand, FAM, isQualifyOptimization);
    if (!isQualifyOptimization) {
      // if we can't determine the comparing value at the compile time, simply
      // give up the opportunity
      LLVM_DEBUG(debug(3) << "Such condition instruction does not qualify for optimization for now \n");
      return;
    }
  }
  
  LLVM_DEBUG(debug(3) << "Optimizing location event generated\n");
  std::vector<llvm::Value *> optimzedAwayInstructions;
  for (auto branch : instrumentationBranches) {
    // iterating the location events collected after the data flow analysis
    for (auto locVal : branch.second) {
      bool isQualifyOptimization = true;
      int reachableConstant = optDataFlowAnalysis(locVal, FAM, isQualifyOptimization);

      if (
        isQualifyOptimization &&
        optimizeAwaySATCheck(cmpInst->getPredicate(), constantValue, reachableConstant, conditionEvent->getIsHappend())
      ) {
        optimzedAwayInstructions.push_back(locVal);
        LLVM_DEBUG(debug(1) << "removed val is: " << *locVal << '\n');
      }
    }
  }

  // delete useless options for instrumentation
  for (auto deleteInst : optimzedAwayInstructions) {
    for (auto& branch : instrumentationBranches) {
      auto position = std::find(branch.second.begin(), branch.second.end(), deleteInst);
      if (position != branch.second.end()) {
        LLVM_DEBUG(debug(2) << "deleting from instrumentationBranches: " << *(*position) << "\n");
        branch.second.erase(position);
      }
    }
  }

  // also need to clean up instrumentationValues as it is coupled with instrumentationBranches,
  // TODO: these two data structure should be aggregated rather to sync with each other independently
  for (auto deleteInst : optimzedAwayInstructions) {
    auto position = std::find(instrumentationValues.begin(), instrumentationValues.end(), deleteInst);
    if (position != instrumentationValues.end()) {
      LLVM_DEBUG(debug(2) <<  "deleting from instrumentationValues: " << *(*position) << "\n" );
      instrumentationValues.erase(position);
    }
  }

  
}

