#include "InstrumentationPlan.h"
#include "instrumentation.pb.h"
#include "ControlDependency.h"

extern EventGraph eventGraph;

using namespace llvm;
using namespace ca::uoft::drsg::bminstrument::communication;

// Instrumentation plan will not only print to console, but also organize each
// instrumentation rule into the following data structure for serialization. We
// shall perform these two events simoutanously
extern std::vector<InstrumentationRule> instrumentationRules;

void extractSubprogramInfo(Function* func, InstrumentationRule& instrumentationRule) {
  DISubprogram *subProgram = func->getSubprogram();
  if (!subProgram) return;
  dbgs() << "At function entry " << subProgram->getName() << "(";
  instrumentationRule.set_methodname(subProgram->getName().str());
  instrumentationRule.set_location("entry");

  std::vector<std::string> types = getTypes(subProgram);
  for (const auto& type : types) {
    auto newParameterTypes = instrumentationRule.add_parametertypes();
    *newParameterTypes = type;
    dbgs() << type << ", ";
  }
  dbgs() << ")\n";

  StringRef file = subProgram->getFile()->getFilename();
  StringRef dir = subProgram->getFile()->getDirectory();
  std::size_t extensionIndex = file.str().find(".java");
  std::string result = file.str();
  if (extensionIndex != std::string::npos) {
    result = file.str().substr(0, extensionIndex);
  }
  instrumentationRule.set_classname(Java::convertJavaFormat(dir.str() + "/" + result));
}

void printDebugLocForInstruction(Instruction &I, InstrumentationRule& instrumentationRule) {
  if (DebugLoc loc = I.getDebugLoc()) {
    DISubprogram *subProgram = I.getFunction()->getSubprogram();
    unsigned line = loc.getLine();
    if (subProgram != NULL) {
      StringRef funcName = subProgram->getName();
      StringRef file = subProgram->getFile()->getFilename();
      StringRef dir = subProgram->getFile()->getDirectory();
      dbgs() << dir << "/" << file << " " << funcName << ":" << line << "\n";
      std::vector<std::string> types = getTypes(subProgram);
      dbgs() << "The parameters are: ";
      for (const auto& type : types) {
        auto newParameterTypes = instrumentationRule.add_parametertypes();
        *newParameterTypes = type;
        dbgs() << type << ", ";
      }
      dbgs() << "\n";
      
      instrumentationRule.set_classname(Java::convertJavaFormat(dir.str() + "/" + Java::stripJavaSuffix(file)));
      instrumentationRule.set_methodname(funcName.str());
      instrumentationRule.set_linenumber(line);
    }
  }

  if (auto bciMetadata = I.getMetadata("bci")) {
    for (unsigned i = 0; i < bciMetadata->getNumOperands(); ++i) {
      Metadata *operand = bciMetadata->getOperand(i).get();
      if (MDString *mdString = dyn_cast<MDString>(operand)) {
        // Extract the string from the operand
        std::string bciString = mdString->getString().str();
        dbgs() << "The bci for the source location is: "
               << bciString << "\n";
        if (!bciString.empty())
          instrumentationRule.set_bytecodeindex(std::stoi(bciString));
      }
    }
  }
}

bool instrIsInGivenLoop(llvm::Loop *loop, llvm::Instruction *instr,
                        std::vector<Loop *> &loopsAlreadySeen) {
  if (vectorContains(loopsAlreadySeen, loop)) {
    return false;
  }
  loopsAlreadySeen.push_back(loop);
  if (loop->contains(instr)) {
    return true;
  } else {
    for (auto subLoop : loop->getSubLoops()) {
      if (instrIsInGivenLoop(loop, instr, loopsAlreadySeen))
        return true;
    }

    return false;
  }
}

bool isInstrInLoop(Instruction *instr, FunctionAnalysisManager &FAM) {
  LoopInfo &loopInfo = FAM.getResult<LoopAnalysis>(*instr->getFunction());
  std::vector<Loop *> loopsAlreadySeen;
  for (auto loop : loopInfo)
    if (instrIsInGivenLoop(loop, instr, loopsAlreadySeen))
      return true;

  return false;
}

std::vector<Value *> valsAlreadySeen;
void printVariablesForInstruction(Instruction *cond) {
  for (auto &op : cond->operands()) {
    if (vectorContains(valsAlreadySeen, dyn_cast<Value>(op))) {
      continue;
    }
    valsAlreadySeen.push_back(op);
    dbgs() << "For register: " << *op << "\n";
    if (Argument *arg = dyn_cast<Argument>(op)) {
      dbgs() << getArgName(arg) << "\n";
    } else if (PHINode *phi = dyn_cast<PHINode>(op)) {
      MDNode *MD = phi->getMetadata("varName");
      if (MD) {
        dbgs() << "Local var name is : "
               << cast<MDString>(MD->getOperand(0))->getString() << "\n";
        continue;
      }
      printVariablesForInstruction(phi);
    } else if (Instruction *instr = dyn_cast<Instruction>(op)) {
      MDNode *MD = instr->getMetadata("varName");
      if (MD) {
        dbgs() << "Local var name is : "
               << cast<MDString>(MD->getOperand(0))->getString() << "\n";
        continue;
        // If it is a call instruction and we don't have varName then probably
        // just stop.
      } else if (CallInst *call = dyn_cast<CallInst>(instr)) {
        dbgs() << "Function call" << *call << "\n";
        if (call->getCalledFunction()) {
          dbgs() << "Function name is " << call->getCalledFunction()->getName()
                 << "\n";
        } else if (Instruction *inst =
                       dyn_cast<Instruction>(call->getOperand(0))) {
          dbgs() << "Going to :" << *inst << "\n";
          printVariablesForInstruction(inst);
        }
        continue;
      }
      dbgs() << "Going to :" << *instr << "\n";
      printVariablesForInstruction(instr);
    }
  }
}

void printInstrumentationPlan(std::vector<Instruction *> instructions,
                              FunctionAnalysisManager &FAM, int start_id) {
  dbgs() << "\n\n\n\n Condition Instrumentations \n\n\n";
  int ID = start_id;
  for (auto I : instructions) {
    if (!I) {
      ID++;
      continue;
    }

    InstrumentationRule instrumentationRule;
    instrumentationRule.set_id(ID);
    dbgs() << "\n\nID: " << ID << "\n";
    std::string blockName = "";
    if (I->getParent()) {
      blockName = I->getParent()->getName();
    }
    dbgs() << "Block number is " << blockName << "\n";
    dbgs() << "Instruction is " << *I << "\n";

    if (BranchInst *BI = dyn_cast<BranchInst>(I)) {
      valsAlreadySeen.clear();
    }
    dbgs() << "Print before the following source location \n";
    printDebugLocForInstruction(*I, instrumentationRule);
    if (isInstrInLoop(I, FAM)) {
      dbgs() << "Instruction is in a loop\n";
    }
    // TODO Print variables that need to be instrumented as well.
    ID++;
    instrumentationRules.push_back(instrumentationRule);
  }
}

std::vector<Value *> branchIDToStartPointMap;
// Key is the branch ID
std::map<unsigned, std::vector<Value *>> BrInstrIDToValueMap;
void printInstrumentationPlanAfterDataFlow(
    std::map<Value *, std::vector<Value *>> instrumentationBranches,
    FunctionAnalysisManager &FAM) {
  unsigned branch_id = 0;
  branchIDToStartPointMap.clear();
  BrInstrIDToValueMap.clear();
  instrumentationRules.clear();
  for (auto branch : instrumentationBranches) {
    dbgs() << "\n-------------------------------\n";
    dbgs() << "Branch ID: " << branch_id << "\n";
    branchIDToStartPointMap.push_back(branch.first);
    dbgs() << "For: " << *(branch.first) << "\n\n";
    std::vector<Value *> instrIDToValue;
    printInstrumentationPlanForDataDeps(branch.second, FAM, instrIDToValue);
    BrInstrIDToValueMap.insert(make_pair(branch_id, instrIDToValue));
    if (Argument *arg = dyn_cast<Argument>(branch.first)) {
      if (auto *var = getClassIfObject(arg)) {
        dbgs() << "Accessing field member of a class "
               << var->getType()->getName() << ". So print variable\n";
        dbgs() << "current event is: " << *eventGraph.getCurrEvent() << "\n";
        std::vector<Value *> gepInsts = eventGraph.getGepInOrdersFineGrain();
        for (auto gepInst : gepInsts) {
          InstrumentationRule instrumentationRule;
          dbgs() << "gep inst is: " << *gepInst << "\n";
          unsigned CurrID = instrIDToValue.size();
          dbgs() << "ID: " << CurrID << "\n";
          instrumentationRule.set_id(CurrID);
          instrumentationRule.set_strategy(Strategy::LOG_CUTTING);
          Function *accessorFunc = cast<GetElementPtrInst>(gepInst)->getParent()->getParent();
          extractSubprogramInfo(accessorFunc, instrumentationRule);
          instrumentationRules.push_back(instrumentationRule);
        }
        
      } else {
        InstrumentationRule instrumentationRule;
        dbgs() << "Print or use an existing stacktrace to point to the correct "
                  "caller function of"
               << arg->getParent()->getName() << "\n";

        dbgs() << "Subprogram -> \n" ;
        dbgs() << "name: " << arg->getParent()->getSubprogram()->getName() << "\n";
        dbgs() << "line: " << arg->getParent()->getSubprogram()->getLine() << "\n";
        dbgs() << "<- Subprogram\n";

        int ID = 0;
        for (InstrumentationRule &rule : instrumentationRules){
          // dbgs() << "rule " << rule.id() << " set " << "\n";
          if(rule.id()>ID){
            ID = rule.id();
          }
        }
        ID += 1;
        
        std::string name = arg->getParent()->getName().str();
        // std::string name = arg->getParent()->getSubprogram()->getName().str();
        
        std::string::size_type temp_id = name.find("_");
        // dbgs() << "///////////////////////////////////////////////////////////////////////////////" << "\n";
        // dbgs() << "name: " << name << "\n";
        
        std::string method_name; std::string class_name;
        if(temp_id != std::string::npos){
          class_name = name.substr(0, temp_id);
          method_name = name.substr(temp_id+1);
          temp_id = method_name.find("_");
          // dbgs() << "in if(); temp_id: " << temp_id << "\n";
          if(temp_id != std::string::npos){
            method_name = method_name.substr(0, temp_id);
          }
        }else{
          method_name = name;
        }
        class_name = class_name + ".java";
        dbgs() << "method_name " << method_name << "\n";
        dbgs() << "class_name " << class_name << "\n";
        InstrumentationRule rule;
        rule.set_id(ID); //
        // rule.set_methodname(method_name);
        rule.set_methodname(arg->getParent()->getSubprogram()->getName().str());
        rule.set_linenumber(arg->getParent()->getSubprogram()->getLine());
        rule.set_classname(class_name);
        rule.set_strategy(Strategy::STACK_TRACE);
        instrumentationRules.push_back(rule); ////////////////////////////////////////////
      }
    }
    branch_id++;
  }
}


extern std::vector<Instruction *> conditionsIdentified;
// TODO: we make this global in order to enable compare algorithm to track it
// However, we shall develop a generic interface for this communication
// this vector contains all line number associated with instrumentation plan
std::vector<std::string> instrumentationLineNumberVector;

void printInstrumentationPlanForDataDeps(std::vector<Value *> values,
                                         FunctionAnalysisManager &FAM,
                                         std::vector<Value *> &instrIDToValue) {
  int ID = 0;
  instrumentationLineNumberVector.clear();
  // we will change the current event in the following for loop, cache the old
  // event here for processing collected information during data flow analysis
  EventNode* currEventNode = eventGraph.getCurrEvent();
  // TODO: Fix this, hacky implementation
  std::vector<Instruction *> conditionsAlreadySeen;
  for (auto val : values) {
    InstrumentationRule instrumentationRule;
    instrumentationRule.set_id(ID);
    instrumentationRule.set_strategy(Strategy::NORMAL);
    if (Argument *arg = dyn_cast<Argument>(val)) {
      instrIDToValue.push_back(val);
      dbgs() << "\n\nID: " << ID << "\n";
      dbgs() << getArgName(arg) << "\n";
      dbgs() << "Print argument: " << arg->getArgNo() - 1 << "\n";
      extractSubprogramInfo(arg->getParent(), instrumentationRule);
    } else if (Instruction *instr = dyn_cast<Instruction>(val)) {
      dbgs() << "Running control depenency pass on instr: " << *instr << "\n";

      CLODSManager.setInstrToAnalyze(instr);
      std::vector<BasicBlock *> dominatingBlocks = 
        CLODSManager.getFAM().getResult<ControlDependency>(*instr->getFunction());
      CLODSManager.getFAM().clear();

      for (auto B : dominatingBlocks) {
        if (!(vectorContains(conditionsAlreadySeen, getBlockCondition(*B)))) {
          conditionsIdentified.push_back(getBlockCondition(*B));
          conditionsAlreadySeen.push_back(getBlockCondition(*B));
        }
      }
      // Here is the optimization we are making: proceed analyzing dominating 
      // condition of possible location events. Therefore, we shall also 
      // connect these pre-computed dominating condition to the event chain
      // TODO: shouold we delete the location event (in which instr reside) from
      // the instrumentation plan
      EventNode* selectedLocationEvent = eventGraph.findNode(
        instr
      );
      eventGraph.setCurrEvent(selectedLocationEvent);
      // For this optimization. let's say its a combination of both
      for(auto condition : conditionsIdentified) {
        eventGraph.addNodeWithEdge(
          selectedLocationEvent, condition, 
          EventNode::EventKind::ConditionEvent, EventEdge::EdgeKind::CoarseGrain
        );
        eventGraph.addNodeWithEdge(
          selectedLocationEvent, condition, 
          EventNode::EventKind::ConditionEvent, EventEdge::EdgeKind::FineGrain
        );
      }
      printInstrumentationPlan(conditionsIdentified, FAM, ID);
      instrIDToValue.insert(instrIDToValue.end(), conditionsIdentified.begin(),
                            conditionsIdentified.end());
      ID = ID + conditionsIdentified.size();
      instrumentationRule.set_id(ID);
      instrIDToValue.push_back(val);
      dbgs() << "\n\nID: " << ID << "\n";
      dbgs() << "Instruction is " << *val << "\n";
      if (isInstrInLoop(instr, FAM)) {
        dbgs() << "Instruction is in a loop\n";
        instrumentationRule.set_loopid(1);
      }
      if (isa<ReturnInst>(instr)) {
        dbgs() << "Print before the following source location \n";
      } else {
        dbgs() << "Print after the following source location \n";
      }
      printDebugLocForInstruction(*instr, instrumentationRule);
    } else if (isa<Constant>(val)) {
      dbgs() << "\n\nID: " << ID << "\n";
      dbgs() << "Constant value: " << *val << "\n";
    }
    auto it = currEventNode->eventInfoQuery.find(val);
    if (it != currEventNode->eventInfoQuery.end()) {
      std::queue<std::string>& callLineNumbersQ = it->second.callLineNumbers;
      if (!callLineNumbersQ.empty()){
        std::string lineNumber = callLineNumbersQ.front();
        dbgs() << "The above function is called at the line number: " << lineNumber << "\n";
        instrumentationLineNumberVector.push_back(lineNumber);
        if (!lineNumber.empty())
          instrumentationRule.set_linenumber(std::stoi(lineNumber));
        callLineNumbersQ.pop();
      }
    }
    ID++;
    instrumentationRules.push_back(instrumentationRule); /////////////
  }
}

int selectIDFromStackTrace(std::string fileName) {
  std::string file_path = "../logs/";
  file_path += fileName;   

  std::ifstream logFile(file_path);
  dbgs() << "file path: " << file_path << "\n";

  if (!logFile.is_open()) {
      return ENOOPEN;
  }

  // extract invocation line number 217 if a log file line is
  // org...chooseTarget(BlockPlacementPolicyDefault.java:217)
  std::regex pattern(R"(:(\s*-?\d+))");
  std::smatch match;

  std::string line;
  // TODO: remove this hard coded string look up for failure execution finding
  std::string stackTraceIndicator = "Start Stack Trace";
  std::string failureIndicator = "BlockManager$ReplicationMonitor"; // using thread name for now
  bool traceStackTraceLineNumber = false;
  std::vector<std::string> stackTraceLineNumbers;
  while(std::getline(logFile, line)){
    // TODO: we temporarily hard-code the look up of failure run
    if (line.find(stackTraceIndicator) != std::string::npos &&
        line.find(failureIndicator) != std::string::npos) {
      traceStackTraceLineNumber = true; // start tracking for the failure run stack frame
    }
    if (traceStackTraceLineNumber && std::regex_search(line, match, pattern)) {
      // Extract the digit from the first capturing group
      std::string digitStr = match[1].str();
      dbgs() << "stack line number is: " << digitStr << "\n";
      stackTraceLineNumbers.push_back(digitStr);
    }
  }

  dbgs() << "stackTraceLineNumbers: " << "\n";
  for (auto stackTraceLineNumber : stackTraceLineNumbers) {
    dbgs() << stackTraceLineNumber << " ";
  } dbgs() << "\n";
  dbgs() << "instrumentationLineNumberVector" << "\n";
  for (auto instrumentationLineNumber : instrumentationLineNumberVector) {
    dbgs() << instrumentationLineNumber << " ";
  } dbgs() << "\n";

  // find the first instrumentation value that appears in the stack frame
  for (auto stackTraceLineNumber : stackTraceLineNumbers) {
    auto it = std::find(
      instrumentationLineNumberVector.begin(), 
      instrumentationLineNumberVector.end(), 
      stackTraceLineNumber
    );

    if (it != instrumentationLineNumberVector.end()) {
      return std::distance(instrumentationLineNumberVector.begin(), it);
    }
  }

  // did not find function call of instrumentation plan in stack frame
  // something went horribly wrong
  return ECOMPARE;
}


// TODO: integrate branchID and instrumentationID in an aggregated structure
// Input: branchID is passed in as reference so that it can be determined according
// to the name of the log file we put in
// return: instrumentation ID derived after comparing all instrumentation
int compareAlgorithm(int &branchID) {
  int instrumentationID;
  do {
    // TODO: we should attach the interface to instrumentation tool at this point
    dbgs() << "What is the file name that stores the log file \n";
    std::string fileName;
    std::cin >> fileName;
    dbgs() << "HERE! file name: " << fileName << "\n";
    // Regular expression pattern to extract branch id N if the file name is
    // stepM_bN.log
    std::regex pattern(R"(_b(\d+)\.log)");

    // Match object to store the matched results
    std::smatch match;

    // Perform the regex search
    if (std::regex_search(fileName, match, pattern)) {
      // Extract the digit from the first capturing group
      std::string digitStr = match[1].str();

      // Convert the extracted digit to an integer
      if (!digitStr.empty()) {
        branchID = std::stoi(digitStr);
        dbgs() << "Branch ID selected is: " << branchID << "\n";
      } else {
        dbgs() << "Branch ID invalid\n";
      }
    }

    int failure_id = 99;
    std::string failureIndicator = "ID=" + std::to_string(failure_id); 
    std::string file_path = "../logs/" + fileName;

    // convert into c style as argument parsing
    char* cStringFileName = new char[fileName.length() + 1];
    std::strcpy(cStringFileName, fileName.c_str());

    // // std::string failureIndicator = "BlockManager$ReplicationMonitor";
    // Strategy {
    //     NORMAL = 0;
    //     FUNCTION_START = 1;
    //     STACK_TRACE = 2;
    //     LOG_CUTTING
    // }
    // bool field_member = false; int target_id = -1;

    dbgs() << "rules: " << "\n";
    bool stack = false; int target_line = -1;
    for (const InstrumentationRule &rule : instrumentationRules){
        // dbgs() << "strategy: " << rule.strategy() << "\n";
        if(rule.strategy() == Strategy::STACK_TRACE){ // if finding the caller with stacktrace
          dbgs() << "stack trace ID selection\n"; 
          // instrumentationID = selectIDFromStackTrace(fileName);
          stack = true;
	  target_line = rule.linenumber();
	  dbgs() << "FIND CALLER: \n";
	  dbgs() << "name: " << rule.methodname() << "\n";
	  dbgs() << "line: " << target_line << "\n";
        }
        else if(rule.strategy() == Strategy::LOG_CUTTING){ // accessing field member
          // field_member = true; target_id = rule.id();
          dbgs() << "access field member of ID " << rule.id() << "\n";
          int read_ID = rule.id();
          instrumentationID = find_value(file_path, failureIndicator, read_ID);
          return instrumentationID;
        }
    }

    if(stack){
      std::string caller_for;
      std::vector<FuncCall> rules;
      for (const InstrumentationRule &rule : instrumentationRules){
        if(rule.strategy() == Strategy::STACK_TRACE){
          caller_for = rule.methodname();
        }else{
          FuncCall call; call.ID = rule.id();
          call.name = rule.methodname(); call.line_number = rule.linenumber();
          rules.push_back(call);
        }
      }
      instrumentationID = find_caller(file_path, failureIndicator, caller_for, rules, target_line);
      dbgs() << "Instrumentation ID selected is: " << instrumentationID << "\n";
      return instrumentationID;
    }else{
      instrumentationID = find_divergence(file_path, failureIndicator, "Method Entry");
    }

    dbgs() << "Instrumentation ID selected is: " << instrumentationID << "\n";

    // compare algorithm can't give us the answer as there's no divergent
    // using stack trace to determine the ID
    if (instrumentationID == ENODIV) {
      dbgs() << "stack trace ID selection\n";
      instrumentationID = selectIDFromStackTrace(fileName);
      dbgs() << "Instrumentation ID selected is: " << instrumentationID << "\n";
    }

    if (instrumentationID == ECOMPARE) {
      assert(false && "Failure in comparison algorithm");
    }


  } while(instrumentationID == ENOOPEN);

  return instrumentationID;
}
