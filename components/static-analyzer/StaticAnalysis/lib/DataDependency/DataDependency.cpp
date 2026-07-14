#include "DataDependency.h"
#include "DeleteNullPtrException.h"
#include "EventGraph/EventGraph.h"
#include "Utility.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/DDG.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include <algorithm>

#define DEBUG_TYPE "DataDependencyPass"

extern std::vector<Instruction *> conditionsIdentified;
extern unsigned instrumentationID;
extern DenseMap<const Function *, SmallVector<const Function *, 8>> CallerMap;
extern bool continuedDataAnalysis;
extern std::map<Value *, std::vector<Value *>> instrumentationBranches;
extern EventGraph eventGraph;

std::vector<Value *> allVisitedInstructions;

AnalysisKey DataDependency::Key;

int fieldOffsetUsed(Argument *arg) {
  // check the most recent gep in the eventgraph:
  std::vector<Value *> gepInsts = eventGraph.getGepInOrdersFineGrain();
  if (gepInsts.empty())
    assert(false && "Missing geps in the event graph");
  auto mostRecentGepInst = cast<GetElementPtrInst>(gepInsts.back());

  for (auto U : arg->users()) {
    if (GetElementPtrInst *I = dyn_cast<GetElementPtrInst>(U)) {
      if (mostRecentGepInst != I)
        continue;
      LLVM_DEBUG(debug(1) << "GEP instruction is: " << *I << "\n");
      LLVM_DEBUG(debug(1) << "Field offset is: " << *(I->getOperand(1))
                          << "\n");

      if (ConstantInt *CI = dyn_cast<ConstantInt>(I->getOperand(1))) {
        LLVM_DEBUG(debug(1)
                   << "Got the offset val: " << CI->getZExtValue() << "\n");
        return CI->getZExtValue();
      }
    }
  }

  assert(false && "Problem with getting the field offset\n");
  return -1;
}

void printSearchFrontier(std::vector<Value *> searchFrontier) {
  for (auto it = searchFrontier.begin(); it < searchFrontier.end(); it++)
    LLVM_DEBUG(debug(3) << *(*it) << "\n");
}

std::vector<Value *>
getAllReachingValuesForPHI(PHINode *phiInstr,
                           std::vector<Value *> &valsAlreadySeenForPhi) {
  std::vector<Value *> reachingValues;
  for (auto &U : phiInstr->incoming_values()) {
    if (isa<Constant>(U)) {
      continue;
    }
    if (vectorContains(valsAlreadySeenForPhi, dyn_cast<Value>(U))) {
      continue;
    }
    valsAlreadySeenForPhi.push_back(dyn_cast<Value>(U));
    if (Instruction *operand = dyn_cast<Instruction>(U)) {
      LLVM_DEBUG(debug(1) << "Instruction in PHI :" << *operand << "\n");
      if (isInsertZeroInitializer(operand)) {
        continue;
      }
      if (PHINode *phi_operand = dyn_cast<PHINode>(operand)) {
        std::vector<Value *> childValues =
            getAllReachingValuesForPHI(phi_operand, valsAlreadySeenForPhi);
        reachingValues.insert(reachingValues.end(), childValues.begin(),
                              childValues.end());
      } else {
        reachingValues.push_back(operand);
      }
    } else if (Argument *arg = dyn_cast<Argument>(U)) {
      LLVM_DEBUG(debug(1) << "arg in PHI :" << *arg << "\n");
      reachingValues.push_back(arg);
      // I think I would have to add it to the dependent instructions list
      // even though it is an argument.
      // TODO: Add function entry to the instrumentation plan
    }
  }
  return reachingValues;
}

// TODO: A single function can have multiple store instances on the same field
// TODO: It is likely that the GEP won't be immediately followed by a store or a
// bitcast. E.g.: There could be a read before store
Value *getValueStored(GetElementPtrInst *I) {
  Instruction *curInst = dyn_cast<Instruction>(I);
  while (curInst != NULL) {
    for (auto U : curInst->users()) {
      if (isa<StoreInst>(U)) {
        LLVM_DEBUG(debug(1) << "Is a writer to this field: " << *U << "\n");
        // TOASK: should we change this to just return U;
        return (U);
      } else if (isa<BitCastInst>(U)) {
        curInst = dyn_cast<Instruction>(U);
        break;
      } else {
        LLVM_DEBUG(debug(1) << "Not a writer to this field \n");
        return NULL;
      }
    }
  }
  assert(false);
}

Value *fieldWriter(Argument *arg, int fieldOffset) {
  for (auto U : arg->users()) {
    if (GetElementPtrInst *I = dyn_cast<GetElementPtrInst>(U)) {
      if (ConstantInt *CI = dyn_cast<ConstantInt>(I->getOperand(1))) {
        if (CI->getZExtValue() == fieldOffset) {
          LLVM_DEBUG(debug(1) << "Same offset GEP found \n");
          return getValueStored(I);
        }
      }
    }
  }
  return NULL;
}

// TODO: Rename this to a better name since we are not returning methods
std::vector<Value *> getMethodsAccessingObject(int fieldOffset,
                                               StringRef className
                                               ) {
  std::vector<Value *> objectsAsArguments;
  LLVM_DEBUG(debug(1) << "Finding methods of this class \n");
  for (auto &F : *CLODSManager.getLLVMModule()) {
    // skip contentless function
    if (F.isDeclaration()) continue;
    if (F.isIntrinsic()) continue;

    llvm:BasicBlock &BB = F.getEntryBlock();
    for (llvm::Instruction &I : BB) {
      if (IntrinsicInst *call = llvm::dyn_cast<llvm::IntrinsicInst>(&I)) {
        if (call->getIntrinsicID() == llvm::Intrinsic::dbg_declare) {
          auto var = cast<DILocalVariable>(
              (cast<MetadataAsValue>(call->getOperand(1)))->getMetadata());
          if (var->getName().equals("this")) {
            if (var->getType()->getName().equals(className)) {
              LLVM_DEBUG(debug(1) << "Method is " << F.getName() << "\n");
              Argument *object = F.getArg(var->getArg() - 1);
              if (Value *fieldWritten = fieldWriter(object, fieldOffset)) {
                LLVM_DEBUG(debug(1) << "Method writes to field:" << *fieldWritten << "\n");
                if (Argument *arg = dyn_cast<Argument>(fieldWritten)) {
                  objectsAsArguments.push_back(arg);
                } else if (Instruction *instr =
                                dyn_cast<Instruction>(fieldWritten)) {
                  objectsAsArguments.push_back(instr);
                } else if (Constant *constant =
                                dyn_cast<Constant>(fieldWritten)) {
                  objectsAsArguments.push_back(constant);
                }
              }
            }
          }
        }
      }
    }
  }
  return objectsAsArguments;
}

void callerInstInfoQuery(
  Instruction* &callerInst, Value *callerArgument
) {
  LLVM_DEBUG(debug(1)
              << "Caller inst is: " << *callerInst << "\n");
  LLVM_DEBUG(debug(1)
              << "Caller argument is: " << *callerArgument << "\n");

  for (User *U : callerInst->users()) {
    if (auto* extractVal = dyn_cast<ExtractValueInst>(U)) {
      // caller line locates at index 1 of extract value inst, skip all extract
      // value inst with inex 0
      if (extractVal->getIndices()[0] == 0) continue;
      std::string lineMetadata = getLineMetadata(U);
      EventNode::EventUtil eventUtil;
      eventUtil.callLineNumbers.push(lineMetadata);
      EventNode* currEventNode = eventGraph.getCurrEvent();
      auto result = currEventNode->eventInfoQuery.emplace(callerArgument, eventUtil);
      if (!result.second) {
        result.first->second.callLineNumbers.push(lineMetadata);
      }
    }
  }
}


std::vector<Value *> instrumentationValues;
void getDependentInstructions(Value *startPoint, FunctionAnalysisManager &FAM) {
  std::vector<Value *> searchFrontier;
  searchFrontier.push_back(startPoint);

  while (!(searchFrontier.empty())) {
    std::vector<Value *> possibleForkValues;
    Value *startPoint = searchFrontier[searchFrontier.size() - 1];
    LLVM_DEBUG(debug(3) << "\nThe start point of this iteration is: "
                        << *startPoint << "\n");
    searchFrontier.pop_back();
    printSearchFrontier(searchFrontier);

    // For functions we want to look at the return instructions rather than
    // the function operands which are arguments
    // Since there can be multiple return values such that a fork is necessary
    if ((isa<CallInst>(startPoint)) || (isa<InvokeInst>(startPoint))) {
      if (vectorContains(allVisitedInstructions, dyn_cast<Value>(startPoint))) {
        continue;
      }
      allVisitedInstructions.push_back(startPoint);

      Function *calledFunction = getCalledFunction(startPoint);
      // Ignore null functions or functions with no name
      if (!calledFunction || !calledFunction->hasName()) {
        continue;
      }
      LLVM_DEBUG(debug(1) << "Function being called "
                          << calledFunction->getName() << "\n");
      CLODSManager.cleanFunction(calledFunction);
      possibleForkValues = getReturnInstructionsOfFunction(*calledFunction);

      // Phi node means possible fork
    } else if (PHINode *phiInstr = dyn_cast<PHINode>(startPoint)) {
      if (vectorContains(allVisitedInstructions, dyn_cast<Value>(phiInstr))) {
        continue;
      }
      LLVM_DEBUG(debug(1) << "Analyzing PHI Node : " << *phiInstr << "\n");
      allVisitedInstructions.push_back(dyn_cast<Value>(phiInstr));

      std::vector<Value *> valsAlreadySeenForPhi;
      valsAlreadySeenForPhi.push_back(dyn_cast<Value>(phiInstr));
      possibleForkValues =
          getAllReachingValuesForPHI(phiInstr, valsAlreadySeenForPhi);

      // General instruction handling: trace the use-def chain
    } else if (Instruction *instr = dyn_cast<Instruction>(startPoint)) {
      if (vectorContains(allVisitedInstructions, dyn_cast<Value>(instr))) {
        continue;
      }
      allVisitedInstructions.push_back(instr);

      for (auto &U : instr->operands()) {
        if (isa<Constant>(U)) {
          continue;
        }
        if (Instruction *operand = dyn_cast<Instruction>(U)) {
          LLVM_DEBUG(debug(1) << "Instruction :" << *operand << "\n");
          eventGraph.addNodeWithEdge(eventGraph.findNode(startPoint), operand,
                                     EventNode::EventKind::GenericEvent,
                                     EventEdge::EdgeKind::FineGrain
                                     );
          searchFrontier.push_back(operand);
        } else if (Argument *arg = dyn_cast<Argument>(U)) {
          LLVM_DEBUG(debug(1) << "Argument : " << *arg << "\n");
          eventGraph.addNodeWithEdge(eventGraph.findNode(startPoint), arg,
                                     EventNode::EventKind::GenericEvent,
                                     EventEdge::EdgeKind::FineGrain
                                     );
          searchFrontier.push_back(arg);
        }
      }

      // Argument means that we have multiple caller which means a fork is
      // possible
    } else if (Argument *arg = dyn_cast<Argument>(startPoint)) {
      // TODO: The %0 is usually a reserved instruction, so ignore it for now.
      if (arg->getArgNo() == 0) {
        continue;
      }
      if (vectorContains(allVisitedInstructions, dyn_cast<Value>(arg))) {
        continue;
      }
      allVisitedInstructions.push_back(arg);
      LLVM_DEBUG(debug(2) << "Analyzing argument: " << *arg
                          << " which is in function: "
                          << arg->getParent()->getName() << " \n");

      // If the field of an class instance is accessed
      if (DILocalVariable *dVar = getClassIfObject(arg)) {
        LLVM_DEBUG(debug(1) << "This argument is actually an object \n");
        // TODO: Filed offset used gets the first GEP instruction offset, but
        // there could be multiple GEP offsets, we want the want that is used in
        // the data flow.
        // For this we would have to have the correct event graph
        possibleForkValues = getMethodsAccessingObject(
            fieldOffsetUsed(arg), dVar->getType()->getName());
      } else {
        Function *surroundingFunction = arg->getParent();
        LLVM_DEBUG(debug(1)
                     << "Callee inst is: " << surroundingFunction->getName() << "\n");
        // First resolve the caller by looking at the stack trace derived from 
        // the event graph. Only if we fail to extract the caller from the stack
        // trace, we ask the caller map to provide potential callers, which 
        // could be expensive for instrumentation tool
        SmallVector<const Function *, 8> callers;
        Function* lastCaller = eventGraph.getLastCaller(arg);
        if (lastCaller != nullptr) {
          callers.push_back(lastCaller);
        } else {
          LLVM_DEBUG(debug(1) << "Finding caller in the caller map\n");
          auto It = CallerMap.find(surroundingFunction);
          if (It == CallerMap.end()) {
            // there is no caller
            errs() << "Error: Function call with argument has no callers in the "
                      "module\n";
            return;
          }
          callers = It->second;
        }

        std::vector<Instruction *> callerInstructions;
        for (const auto &caller : callers) {
            if (surroundingFunction == caller) {
              continue;
            }
            if (isFunctionReflectInvoke(caller)) {
              continue;
            }
            LLVM_DEBUG(debug(1)
                      << "Caller exists: " << caller->getName() << "\n");
            // caller map returns a pointer that points to the function with const
            // modifier, we need to convert it to non constant in order to clean
            // its noise
            // TODO: this logic should be encapsulated in cleanFunction
            Function *Caller = getCallerNonConst(caller);
            CLODSManager.cleanFunction(Caller);

            // locate all call instructions in the caller
            std::vector<Instruction *> callInstructionsForThisCaller =
                getCallInstructions(Caller, surroundingFunction);
            for (auto call : callInstructionsForThisCaller) {
              if (!(vectorContains(callerInstructions, call))) {
                callerInstructions.push_back(call);
              }
            }
          }

        // follow the def-use chain of the argument used in caller and continue
        // the data flow analysis unless there's multiple possible values need
        // to be instrumented
        for (auto callerInst : callerInstructions) {
          Value *callerArgument = getCallerArgument(callerInst, arg);
          callerInstInfoQuery(callerInst, callerArgument);
          if (isa<Argument>(callerArgument)) {
            possibleForkValues.push_back(dyn_cast<Argument>(callerArgument));
          } else if (isa<Instruction>(callerArgument)) {
            possibleForkValues.push_back(dyn_cast<Instruction>(callerArgument));
          } else if (isa<Constant>(callerArgument)) {
            possibleForkValues.push_back(callerArgument);
          } else {
            __builtin_unreachable();
          }
        }
      }
    } else if (isa<Constant>(startPoint)) {
      LLVM_DEBUG(debug(1) << "Ignoring analysing the constant : " << *startPoint
                          << "\n");
      continue;
    } else {
      __builtin_unreachable();
    }

    for (auto possibleForkValue : possibleForkValues) {
      eventGraph.addNodeWithEdge(
            eventGraph.findNode(startPoint), possibleForkValue,
            EventNode::EventKind::GenericEvent, EventEdge::EdgeKind::FineGrain
            
      );
    }

    // If there are numerous possible values when performing the above data
    // flow analysis, we insert them into instrumentationValues to ask
    // instrumentation tool to guide us on which execution path we
    // should proceed with data flow analysis
    // (we can continue the static analysis if only there's only one value in
    // possibleForkValues since the execution path is deterministic)
    if (possibleForkValues.size() > 1) {
      LLVM_DEBUG(debug(1)
                 << "Insert the following fork values for instrumentation: \n");
      for (auto possibleForkValue : possibleForkValues) {
        LLVM_DEBUG(debug(1)
                   << "fork value inserted: " << *possibleForkValue << "\n");
      }
      instrumentationValues.insert(instrumentationValues.end(),
                                   possibleForkValues.begin(),
                                   possibleForkValues.end());
      instrumentationBranches.insert(
          std::make_pair(startPoint, instrumentationValues));
      instrumentationValues.clear();
    } else {
      searchFrontier.insert(searchFrontier.end(), possibleForkValues.begin(),
                            possibleForkValues.end());
    }
  }
}

DataDependency::Result 
DataDependency::run(Function &F, FunctionAnalysisManager &FAM) {
  std::vector<Value *> temp;
  Value *startPoint = CLODSManager.getInstrToAnalyze();
  dbgs() << "Running control depenency pass on instr: " << *startPoint << "\n";
  allVisitedInstructions.clear();
  instrumentationValues.clear();
  instrumentationBranches.clear();
  getDependentInstructions(startPoint, FAM);
  for (auto branch : instrumentationBranches) {
    auto valsToInstrument = branch.second;
    instrumentationValues.insert(instrumentationValues.end(),
                                 valsToInstrument.begin(),
                                 valsToInstrument.end());
  }
  CLODSManager.clearInstrToAnalyzer();
  return temp;
}