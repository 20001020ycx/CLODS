#include "Utility.h"
#include "ControlDependency.h"
#include <unordered_set>


#include <unordered_set>

using namespace llvm;

extern int clientSocket;
extern bool manualOverride;
bool debugFlag = 0;
int debugLevel = 0;


static SMDiagnostic err;
static LLVMContext context;

CLODSDataManager CLODSManager;


static const std::string emptyString = "";
static constexpr int invalidInt = -12369; // magic number for invalid input to conf


std::string Java::stripJavaSuffix(StringRef file) {
  std::size_t extensionIndex = file.str().find(".java");
  std::string result = file.str();
  if (extensionIndex != std::string::npos) {
    result = file.str().substr(0, extensionIndex);
  }
  return result;
}

std::string Java::convertJavaFormat(std::string className) {
  std::replace(className.begin(), className.end(), '/', '.');
  return className;
}


std::vector<std::string> getTypes(DISubprogram *subProgram) {
  std::vector<std::string> result;

  if (auto *Type = subProgram->getType()) {
    auto Types = Type->getTypeArray();
    for (unsigned i = 1; i < Types.size(); ++i) {
      if (auto *ParamType = llvm::dyn_cast<llvm::DIType>(Types[i])) {
        result.push_back(ParamType->getName().str());
      }
    }
  }

  return result;
}

StringRef getArgName(Argument *arg) {
  for (auto &I : arg->getParent()->getEntryBlock()) {
    Instruction *U = &I;
    if (IntrinsicInst *call = llvm::dyn_cast<llvm::IntrinsicInst>(U)) {
      if (call->getIntrinsicID() == llvm::Intrinsic::dbg_declare) {
        int op_index = 0;
        for (auto &op : call->operands()) {
          if (op_index == 1) {
            auto var = cast<DILocalVariable>(
                (cast<MetadataAsValue>(op))->getMetadata());
            if (var->getArg() == (arg->getArgNo() + 1)) {
              return var->getName();
            }
          }
          op_index++;
        }
      }
    }
  }
  return "";
}

Instruction *getBlockCondition(BasicBlock &BB) {
  Instruction *Term = BB.getTerminator();
  // Term->print(errs());
  if (BranchInst *BI = dyn_cast<BranchInst>(Term)) {
    if (BI->isConditional()) {
      return BI;
    }
  }
  return NULL;
}

void debugSetUp() {
  debugLevel = CLODSManager.getDebugLevel();
  CLODSManager.getDebugPasses();
  if (CLODSManager.debugOnlyPasses.size() != 0) debugFlag = true;

  // convert vector into C-styled const char** in order to use LLVM utility
  const char** charArr = new const char*[CLODSManager.debugOnlyPasses.size()];
  // Copy each string from the vector to the char* array
  for (size_t i = 0; i < CLODSManager.debugOnlyPasses.size(); ++i) {
    const char* cStr = CLODSManager.debugOnlyPasses[i].c_str();
    charArr[i] = cStr;
  }


  // internal signal flags used by LLVM to turn on debug statement producion
  EnableDebugBuffering = true;
  DebugFlag = true;

  // setCurrentDebugTypes will clear all existing debug type and add
  // the input debug type to it. Note that empty\debug type array
  // will turn on all debug type for all inovking passes since
  // isCurrentDebugType returns true if there is an empty debug only type array
  setCurrentDebugType("dummy debug type");
  if (debugFlag) {
    setCurrentDebugTypes(charArr, CLODSManager.debugOnlyPasses.size());
  }
}

void CLODSDataManager::cleanFunction(Function *function) {
  FunctionPassManager FPM;
  for (int i = 0; i < DeleteRedundentFunc.size(); i++) {
    FPM.addPass(
        DeleteNullPtrExceptionPass(DeleteRedundentFunc[i], *function));
  }
  FPM.run(*function, this->FAM);
  dbgs() << "\n Function cleaned:" << function->getName() << "\n\n";
}

Function *getCalledFunction(Value *instr) {
  if (CallInst *funcCall = dyn_cast<CallInst>(instr)) {
    return funcCall->getCalledFunction();
  } else if (InvokeInst *funcCall = dyn_cast<InvokeInst>(instr)) {
    return funcCall->getCalledFunction();
  } else {
    return NULL;
  }
}

std::vector<Value *> getReturnInstructionsOfFunction(Function &F) {
  std::vector<Value *> returnInstructions;
  for (auto &B : F) {
    for (auto &I : B) {
      if (isa<ReturnInst>(&I)) {
        returnInstructions.push_back(&I);
      }
    }
  }
  return returnInstructions;
}

bool isFunctionReflectInvoke(const Function *func) {
  DISubprogram *subProgram = func->getSubprogram();
  if (subProgram != NULL) {
    return subProgram->getName().equals("invoke") ? true : false;
  }
  return false;
}

std::vector<Instruction *> getCallInstructions(Function *caller,
                                               Function *callee) {
  std::vector<Instruction *> callInstructions;
  for (auto &BB : *caller) {
    for (auto &I : BB) {
      // TODO: See if it should be both invoke and call or just call
      if ((isa<CallInst>(I)) || (isa<InvokeInst>(I))) {
        // if ((isa<CallInst>(I)) || (isa<InvokeInst>(I))) {
        if (getCalledFunction(&I) == callee) {
          callInstructions.push_back(&I);
        }
      }
    }
  }
  return callInstructions;
}

Value *getCallerArgument(Instruction *call, Argument *arg) {
  return call->getOperand(arg->getArgNo());
}

Function *getCallerNonConst(const Function *caller) {
  for (auto &F : *CLODSManager.getLLVMModule()) {
    if (&F == caller) {
      return &F;
    }
  }
  return NULL;
}

// TODO: Right now it's ignoring if we cannot find an argument but we
// actually need it to ignore if the argument is not a source argument
DILocalVariable *getClassIfObject(Argument *arg) {
  Function *func = arg->getParent();
  for (auto &I : arg->getParent()->getEntryBlock()) {
    Instruction *U = &I;
    if (IntrinsicInst *call = llvm::dyn_cast<llvm::IntrinsicInst>(U)) {
      if (call->getIntrinsicID() == llvm::Intrinsic::dbg_declare) {
        auto var = cast<DILocalVariable>(
            (cast<MetadataAsValue>(call->getOperand(1)))->getMetadata());
        if (var->getArg() == (arg->getArgNo() + 1)) {
          if (var->getName().equals("this")) {
            return var;
          }
        }
      }
    }
  }
  return NULL;
}

Function *getFunctionOfValue(Value *val) {
  if (Instruction *instr = dyn_cast<Instruction>(val)) {
    return instr->getFunction();
  } else if (Argument *arg = dyn_cast<Argument>(val)) {
    return arg->getParent();
  } else {
    __builtin_unreachable();
  }
}

std::string getLineMetadata(Value* val) {
  if (!isa<Instruction>(val)) return "";
  auto inst = cast<Instruction>(val);
  if (auto bciMetadata = inst->getMetadata("line")) {
    for (unsigned i = 0; i < bciMetadata->getNumOperands(); ++i) {
      Metadata *operand = bciMetadata->getOperand(i).get();
      if (MDString *mdString = dyn_cast<MDString>(operand)) {
        // Extract the string from the operand
        return mdString->getString().str();
      }
    }
  }
  return "";
}

void runControlDependency(Instruction *instrToAnalyze,
                          FunctionAnalysisManager &FAM) {
  // Function *functionToAnalyze = getFunctionOfValue(instrToAnalyze);
  // FunctionPassManager FPM;
  // FPM.addPass(ControlDependency(instrToAnalyze));
  // FPM.run(*functionToAnalyze, FAM);
}

void CLODSDataManager::networkBootstrap() {
  if (!getEnableNetwork()) return;
  // I like the format of protobuf, even though we do not use network to connect, we still want to 
  // see it printed
  bool connected = true;

  std::cout << "Waiting instrumentation tool to be connected ... " << std::endl;
  do {
    // Create a socket: use IPV4, TCP
    clientSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (clientSocket == -1) {
      assert(false && "Failed to create socket");
    }

    // Connect to the server
    sockaddr_in serverAddress{};
    serverAddress.sin_family = AF_INET;
    serverAddress.sin_port = htons(12345);  // Port number
    serverAddress.sin_addr.s_addr = inet_addr("127.0.0.1");  // IP address

    if (connect(clientSocket, reinterpret_cast<sockaddr*>(&serverAddress), sizeof(serverAddress)) == -1) {
      close(clientSocket);
    } else {
      connected = true;
    }
  } while(!connected);

  std::cout << "Connected to instrumentation tool!" << std::endl;

}

// detect whether it is potentially that we can reach from the "fromBB" to 
// "toBB" according to the control flow graph
bool isReachable(BasicBlock* fromBB, BasicBlock* toBB) {

  std::unordered_set<BasicBlock *> visited;
  std::queue<BasicBlock *> q;
  q.push(fromBB);

  while (!q.empty()) {
    auto top = q.front();
    q.pop();

    for (auto succ : successors(top)) {
      if (succ == toBB) return true;
      if (visited.find(succ) == visited.end()) {
        q.push(succ);
        visited.insert(succ);
      }
    }
  }

  return false;

}


// determine whether the "targetBB" is a basic block that resides in a catch 
// block. 
bool isResideInCatchBlock(Function *startingFunction, BasicBlock* targetBB) {
  // By LLVM documentation:
  // 1. A landing pad basic block is the location where the exception lands. 
  // When an invoke instruction decides the control flow must transfer to the 
  // exception label(Please see more detail about how the decision is made in 
  // LLVM documentation), the very first basic block must be the landing pad BB
  // 2. A landing pad basic block is requires by a landing pad instruction which
  // branch to the handler that corresponds to the catch block in the source code

  // collect all landingPad basic blocks in the procedure
  std::vector<BasicBlock *> landingPadBlocks;
  for (auto& BB : *startingFunction) {
    for (auto& Instr : BB) {
      if (isa<LandingPadInst>(Instr)) {
        landingPadBlocks.push_back(&BB);
      }
    }
  }

  // The catch block must be reachable by all landingPad basic blocks
  // One may wonder: What if there's multiple catch block?
  // Still, all catch blocks shall be reachable by all landingPad basic blocks
  // statically as determining which catch block to proceed is determined at 
  // the runtime. 
  for (auto& BB : *startingFunction) {
    bool allDominated = true;
    for (auto& landingPadBlock : landingPadBlocks) {
      // If BB does not potentially reachable from one of the landingpad blocks, 
      // then BB must not be a BB in catch block
      if (!isReachable(landingPadBlock, &BB)) {
        allDominated = false;
      }
    }
    if (allDominated) {
      if (&BB == targetBB) return true;
    }
  }

  return false;

}

int CLODSDataManager::getIntFromBugInfoMap(const std::string& key)
{
  int result = invalidInt;
  if (bugInfo.count(key)) {
    try {
      result = stoi(bugInfo[key]);
    } catch (...) {
      assert(false && "string to integer conversion failed, invalid argument");
    }
  }

  return result;
}

std::string
CLODSDataManager::getIRPath()
{
  std::string key("IRFilePath");
  if (bugInfo.count(key)) {
    return bugInfo[key];
  }

  return emptyString;
}

std::string
CLODSDataManager::getFuncName()
{
  std::string key("funcName");
  if (bugInfo.count(key)) {
    return bugInfo[key];
  }

  return emptyString;
}

std::string
CLODSDataManager::getFileName()
{
  std::string key("FileName");
  if (bugInfo.count(key)) {
    return bugInfo[key];
  }

  return emptyString;
}

void
CLODSDataManager::getDebugPasses()
{
  std::string key("debug");
  if (bugInfo.count(key)) {
    std::string debugValues = bugInfo[key];
    // Use a stringstream to split the string by the comma and space
    std::stringstream ss(debugValues);
    std::string item;

    while (std::getline(ss, item, ',')) {
        // Remove any leading or trailing spaces
        item.erase(0, item.find_first_not_of(" \t\n\r\f\v"));
        item.erase(item.find_last_not_of(" \t\n\r\f\v") + 1);
        
        // Add the trimmed item to the vector
        debugOnlyPasses.push_back(item);
    }
  }

  return;
}

int
CLODSDataManager::getLineNumber()
{
  std::string key("LineNumber");
  int result = getIntFromBugInfoMap(key);
  if (result == invalidInt) {
    return 0; // default option of network is disabled
  }

  return result;
}

int
CLODSDataManager::getDebugLevel()
{
  std::string key("debugLevel");
  int result = getIntFromBugInfoMap(key);
  if (result == invalidInt) {
    return 0; // default option of network is disabled
  }

  return result;
}

int
CLODSDataManager::getManualOverride()
{
  std::string key("manualOverride");
  int result = getIntFromBugInfoMap(key);
  if (result == invalidInt) {
    return 0; // default option of network is disabled
  }

  return result;
}

bool
CLODSDataManager::getEnableNetwork()
{
  std::string key("enableNetwork");
  int result = getIntFromBugInfoMap(key);
  if (result == invalidInt) {
    return 0; // default option of network is disabled
  }

  return result;
}


// Utility function to trim whitespace from both ends of a string
static std::string
trim(const std::string& str)
{
  size_t start = str.find_first_not_of(" \t");
  size_t end = str.find_last_not_of(" \t");

  if (start == std::string::npos || end == std::string::npos) {
    return "";
  }

  return str.substr(start, end - start + 1);
}

static bool
readConfig(const std::string& conf, llvm::StringMap<std::string>& map){
  std::ifstream infoConf(conf);
  if (!infoConf.is_open()) {
    std::cerr << "Could not open the configuration file: " << conf
              << std::endl;
    return false;
  }

  bool isParseSuccess = true;
  std::string line;
  while (std::getline(infoConf, line)) {
    // this is a comment
    if (line[0] == '#') continue;

    if (line.empty()) {
      continue;
    }

    std::istringstream lineStream(line);
    std::string key, value;

    if (std::getline(lineStream, key, ':') && std::getline(lineStream, value)) {
      map.try_emplace(trim(key), trim(value));
    } else {
      std::cerr << "Parsing error: Invalid line - " << line << std::endl;
      isParseSuccess = false;
    }
  }

  return isParseSuccess;
}

bool
CLODSDataManager::readConfigs()
{
  return readConfig(confName, bugInfo) && readConfig(jumpTableName, jumpInfo);
}

bool
CLODSDataManager::bootstrapCLODSStaticAnalyzer()
{ 
  // read configuration pertaining to the bug information
  if (!CLODSManager.readConfigs()) {
    return false;
  }

  networkBootstrap();

  // debug bootstrap set up
  debugSetUp();

  std::cout << "\nProcessing source files as a monolithic IR, this process may take a while ...\n";

  std::string IRPath = getIRPath();
  if (IRPath == emptyString) return false;



  std::unique_ptr<llvm::Module> module = parseIRFile(IRPath, err, context);
  if (module == NULL) {
    errs() << "Could not parse the IR file provided \n";
    return false;
  }

  setLLVMModule(module);

  assert(!module); // ensure ownership is transferred

  return true;
}

// In generated IR, there's always two instructions after a function call, one with the debug info and one without
// %184 = extractvalue { i64, i8 addrspace(1)* } %183, 0, !dbg !2149
// %185 = extractvalue { i64, i8 addrspace(1)* } %183, 1, !dbg !2149, !bci !2148, !line !2145, !funcName !2083
// we use %185 to locate the line number and trace back to the %183 which is a function call
static bool
isExtractValueInstIndexOne(Instruction *inst) {
  if (auto *extractValueInst = llvm::dyn_cast<llvm::ExtractValueInst>(inst)) {
    // Check if the index is exactly '1'
    const auto &indices = extractValueInst->getIndices();
    if (indices.size() == 1 && indices[0] == 1) {
        return true;
    }
  }

  return false;
}

static Instruction*
fineGrainedMapLocationToInst(Function* func) {
  CLODSManager.cleanFunction(func);

  DISubprogram *subProgram = func->getSubprogram();
  StringRef dir = subProgram->getFile()->getDirectory();
  StringRef file = subProgram->getFile()->getFilename();
  StringRef funcName = subProgram->getName();

  unsigned linenum = CLODSManager.getLineNumber();

  // after cleanning - fine-grain look up
  for (BasicBlock &B : *func) {
    for (Instruction &I : B) {

      if (!I.getDebugLoc()) continue;

      DebugLoc loc = I.getDebugLoc();
      unsigned line = loc.getLine();

      // if developer gives us the function name that triggers the failure, start with that function
      // else find the general instruction
      std::string symptomFuncName = CLODSManager.getFuncName();
      if (symptomFuncName != emptyString) {
        // skip all non-extract functions
        if (!isExtractValueInstIndexOne(&I)) continue;

        // check if extrac corrspond to the function we are interested
        auto* calledInst = cast<ExtractValueInst>(&I)->getOperand(0);
        Function *calledFunction = getCalledFunction(calledInst);
        if (!calledFunction) continue;
        if (calledFunction->getName().str().find(symptomFuncName) == std::string::npos) continue;
        
        dbgs() << "Function triggered failure is: " << *calledInst << "\n";

      }

      if (line == linenum) {
        dbgs() << dir << "/" << file << " " << funcName << ":" << line
                << "\n";
        dbgs() << "Starting instruction is " << I << "\n";

        return &I;
      }
      
    }
  }

  return nullptr;
}

Instruction* CLODSDataManager::mapLocationToInstruction() {
  // TODO: What to do when one location maps to multiple IR instruction?
  std::string filename = getFileName();
  unsigned linenum = getLineNumber();

  // clean function first - coarse-grain look up
  for (Function &F : *getLLVMModule()) {
     // skip function declaration
    if (F.isDeclaration()) continue;

    DISubprogram *subProgram = F.getSubprogram();
    if (!subProgram) continue;
    StringRef file = subProgram->getFile()->getFilename();

    if (file.equals(filename)) {
      if (auto* result = fineGrainedMapLocationToInst(&F)) return result;
    }
  }

  return nullptr;
}

bool isInsertZeroInitializer(Instruction *operand) {
  if (auto *insertValueInst = dyn_cast<InsertValueInst>(operand)) {
    // During the Static Analysis, noticed that there are many insertValue 
    // like %27 which is useless
    // %27 = insertvalue { i64, i64 } zeroinitializer, i64 %15, 0, !dbg !1368
    // %28 = insertvalue { i64, i64 } %27, i64 %67, 1, !dbg !1368
    // ret { i64, i64 } %28, !dbg !1368, !bci !1369, !line !1363
    // we can skip them
    llvm::Constant* insertedValue = 
      llvm::dyn_cast<llvm::Constant>(insertValueInst->getAggregateOperand());
    // skipping condition: zero initializer + insert value at index 0
    if (insertValueInst->getIndices()[0] == 0 &&
        insertedValue && insertedValue->isNullValue()
      ) {
        return true;
    }
  }

  return false;
}

