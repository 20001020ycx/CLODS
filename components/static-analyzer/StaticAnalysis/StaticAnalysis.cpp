#include "CallerMapGenPass.h"
#include "Compare.h"
#include "ControlDependency.h"
#include "DataDependency.h"
#include "EventGraph/EventGraph.h"
#include "Helloworld.h"
#include "InstrumentationPlan.h"
#include "Optimization.h"
#include "ProtocBuf.h"
#include "Utility.h"
#include <fstream>
#include <iostream>

using namespace llvm;
extern std::vector<BasicBlock *> dominatingBlocks;
extern std::vector<Value *> instrumentationValues;
std::map<Value *, std::vector<Value *>> instrumentationBranches;
EventGraph eventGraph;


extern std::vector<Value *> branchIDToStartPointMap;
std::vector<Instruction *> conditionsIdentified;
extern std::map<unsigned, std::vector<Value *>> BrInstrIDToValueMap;
bool additionalDataAnalysisRequired = false;
unsigned instrumentationID = 0;
bool continuedDataAnalysis = false;
int clientSocket = -1;

// Initializing LLVM Registration Framework
static void
LLVMRegistration()
{ 
  // Create the new pass manager builder.
  // Take a look at the PassBuilder constructor parameters for more
  // customization, e.g. specifying a TargetMachine or various debugging
  // options.
  static llvm::PassBuilder PB;

  static LoopAnalysisManager LAM;
  static FunctionAnalysisManager FAM;
  static CGSCCAnalysisManager CGAM;
  static ModuleAnalysisManager MAM;

  // Register all the basic analyses with the managers.
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

  // Lambda callback for pass registration
  PB.registerAnalysisRegistrationCallback(
    [](llvm::FunctionAnalysisManager& FAM) {
      FAM.registerPass([&]() { return ControlDependency(); });
      FAM.registerPass([&]() { return DataDependency(); });
    });

  // register customized passes
  PB.registerFunctionAnalyses(CLODSManager.getFAM());

  static ModulePassManager MPM;
  MPM.addPass(CallerMapGenPass());
  MPM.run(*CLODSManager.getLLVMModule(), MAM);
}


static bool handleControlFlow(Value *instrToAnalyze){
  bool userInputRequired = false;
  // finding the selected location event
  // TODO: ask user/compare algorithm to provide whether the event has
  // happend or not
  EventNode *selectedLocationEvent = eventGraph.findNode(instrToAnalyze);
  eventGraph.setCurrEvent(selectedLocationEvent);

  CLODSManager.setInstrToAnalyze(instrToAnalyze);

  auto* inst = cast<Instruction>(instrToAnalyze);

  std::vector<BasicBlock *> dominatingBlocks = 
    CLODSManager.getFAM().getResult<ControlDependency>(*inst->getFunction());
  CLODSManager.getFAM().clear();

  if (dominatingBlocks.empty()) {
    dbgs() << "There are no dominating conditions in the current "
              "function, looking at the caller function\n";
    userInputRequired = true;
    return 0;
    // TODO
  } else if (dominatingBlocks.size() == 1) {
    dbgs() << "Only a single dominating condition, no instrumentation "
              "required\n";
    conditionsIdentified.push_back(
        getBlockCondition(*(dominatingBlocks[0])));
    instrumentationID = 0;
  } else {
    dbgs() << "Multiple dominating conditions, instrumentation required \n";
    for (auto B : dominatingBlocks) {
      conditionsIdentified.push_back(getBlockCondition(*B));
    }
    printInstrumentationPlan(conditionsIdentified, CLODSManager.getFAM());
    // the optimization will disable execution to here
    // some refactor needed to delete these codes away
    //assert(false && "This shouldn't happen due to optimization");

    // The would only be run if the first instruction leads to 
    // multiple dominating conditions
    std::vector<llvm::Value*> values(conditionsIdentified.begin(), conditionsIdentified.end());
    BrInstrIDToValueMap.insert(make_pair(0, values));
    instrumentationValues.insert(instrumentationValues.end(), conditionsIdentified.begin(), conditionsIdentified.end());
    userInputRequired = true;
  }

  // add all possible condition events into the event graph
  for (auto condition : conditionsIdentified) {
    if (condition == nullptr) continue;
    eventGraph.addNodeWithEdge(
      selectedLocationEvent, condition, 
      EventNode::EventKind::ConditionEvent, EventEdge::EdgeKind::CoarseGrain
    );
  }

  eventGraph.printEventGraphCoraseGrain();
  return userInputRequired;
}

static bool handleDataFlow(bool &userInputRequired, int branchID){
  dbgs() << "Running the data dependency pass \n";

  Value *valueToAnalyze = nullptr;
  if (userInputRequired) {
    valueToAnalyze =
        BrInstrIDToValueMap.find(branchID)->second[instrumentationID];
  } else {
    if (continuedDataAnalysis) {
      valueToAnalyze =
          (instrumentationBranches.find(branchIDToStartPointMap[branchID]))
              ->second[instrumentationID];
    } else {
      valueToAnalyze = conditionsIdentified[instrumentationID];
    }
  }
  dbgs() << "value to analyze is: " << *valueToAnalyze << "\n";
  EventNode *selectedConditionEvent = eventGraph.findNode(valueToAnalyze);
  dbgs() << "Selected condition event is: " << *selectedConditionEvent
          << "\n";
  eventGraph.setCurrEvent(selectedConditionEvent);
  
  CLODSManager.setInstrToAnalyze(valueToAnalyze);

  Function* instrToAnalyzeFunc = nullptr;
  if (auto* arg = dyn_cast<Argument>(valueToAnalyze)) {
    instrToAnalyzeFunc = arg->getParent();
  } else if (auto* inst = dyn_cast<Instruction>(valueToAnalyze)) {
    instrToAnalyzeFunc = inst->getFunction();
  } else {
    assert(false && "Unsupported data flow input");
  }
  CLODSManager.getFAM().getResult<DataDependency>(*instrToAnalyzeFunc);
  CLODSManager.getFAM().clear();

  // TODO: Optimization aiming to reduce the number of instrumentation using static 
  // code analysis
  // Disabled as interface is still under development
  // Confirmed the functionality of optimization solely for numOfReplicas bug
  // Need more refine for other bugs
  //instrumentationOpt(selectedConditionEvent, FAM);

  // promote fine-grained node into the location event node for coarse-grain
  // search
  for (auto branch : instrumentationBranches) {
    for (auto val : branch.second) {
      // delete fine grain node as we will promote it to location node
      if (auto *destNode = eventGraph.findNode(val)) {
        eventGraph.promoteFineGrainNode(val, selectedConditionEvent);
      }
    }
  }
  eventGraph.printEventGraphFineGrain();

  if (instrumentationValues.size() == 0) {
    dbgs() << "The condition variables don't have defining instructions \n";
  } else if (instrumentationValues.size() == 1) {
    dbgs() << "Only a single operand definition \n";
    instrumentationID = 0;
    userInputRequired = false;
  } else {
    dbgs() << "Multiple variable definitions, instrumentation required \n";
    printInstrumentationPlanAfterDataFlow(instrumentationBranches, CLODSManager.getFAM());
    protocBufSerialization();
    userInputRequired = true;
  }

  return userInputRequired;
}

// The tool integrates static analysis tool with the compare alogorithm
// the input shall be two following possible cases:
// 1. error of the bug appeared in the log file as static text. This happens at
// the very first round of the tool
// 2. A series of logs that contain multiple run of sucess run and failure run
// for our compare algorithm to analyze
// The output should be the insturmentation plan
int main() {

  if (!CLODSManager.bootstrapCLODSStaticAnalyzer()) {
    return -1;
  }
  
  LLVMRegistration();

  // Starting Point 
  EventType event_type = LocationEvent;
  Instruction *startingInstruction = CLODSManager.mapLocationToInstruction();
  if (startingInstruction == NULL) {
    errs() << "Cannot map provided location information to an instruction in "
              "the LLVM IR\n";
    return -1;
  }

  // Graph bootstrap: connect root node with the location event that points
  // to the exception thrown
  eventGraph.eventGraphBootstrap(startingInstruction);

  instrumentationValues.push_back(startingInstruction);
  instrumentationBranches.insert(
      std::make_pair(startingInstruction, instrumentationValues));
  branchIDToStartPointMap.push_back(startingInstruction);

  bool userInputRequired = false;
  int branchID = 0;
  // Change this to: while the search frontier has elements in it
  while (true) {
    // In non-optmized SA, LocationEvent and ConditionEvent alternates
    if (event_type == LocationEvent) {
      Value *instrToAnalyze =
          (instrumentationBranches.find(branchIDToStartPointMap[branchID]))
              ->second[instrumentationID];

      userInputRequired = handleControlFlow(instrToAnalyze);
      event_type = ConditionEvent;
    } else if (event_type == ConditionEvent) {
      userInputRequired = handleDataFlow(userInputRequired, branchID);
      event_type = LocationEvent;
    }

    branchID = 0;
    if (userInputRequired) {
      // TODO: We should add interface to instrumentation tool.
      // Note that branchID is passed in as reference so that it will be modified
      // accordingly as we input the log file name which is decorated
      // with the respective branchID
      if (CLODSManager.getManualOverride()) {
        if (branchIDToStartPointMap.size() > 1) {
          std::cout << "What is the branch ID to continue \n";
          std::cin >> branchID;
        }
        std::cout << "What is the ID to continue \n";
        std::cin >> instrumentationID;
      } else {
        instrumentationID = compareAlgorithm(branchID);
      }

      // testing purpose
      if (branchID == -520 || instrumentationID == -520) return 0;

      Value *valToAnalyze =
          BrInstrIDToValueMap.find(branchID)->second[instrumentationID];
      if (isa<BranchInst>(valToAnalyze)) {
        event_type = ConditionEvent;
      } else {
        event_type = LocationEvent;
      }

      // TODO: extremely ad-hoc, re-think this approach for later
      if ((event_type == LocationEvent) &&
          (isa<Argument>(valToAnalyze))) {
        dbgs() << "Continuing Data flow analysis\n";
        continuedDataAnalysis = true;
      } else if (event_type == LocationEvent) {
        dbgs() << "Was there a divergence point? \n";
        int divergentPoint;
        std::cin >> divergentPoint;
        if (divergentPoint == 0) {
          dbgs() << "Continuing Data flow analysis\n";
          continuedDataAnalysis = true;
        }
      } else {
        continuedDataAnalysis = false;
      }
    }

    if (continuedDataAnalysis) {
      event_type = ConditionEvent;
    }

    dbgs() << "\n-------------------------------\n\n";
    eventGraph.printEventGraphCoraseGrain();
  }
}
