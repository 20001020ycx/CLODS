#ifndef B7D41679_F2C9_4C8C_878D_2D519F00A5E5
#define B7D41679_F2C9_4C8C_878D_2D519F00A5E5
#include "DeleteNullPtrException.h"
#include "llvm/Analysis/CGSCCPassManager.h"
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Pass.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"
#include <arpa/inet.h>
#include <iostream>
#include <stdlib.h>
#include <vector>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <sstream>

using namespace llvm;

enum EventType {
  LocationEvent,
  ConditionEvent,
  InvocationEvent,
  Location_InvocationEvent
};

class CLODSDataManager
{

private:
  using BugInfoMap = llvm::StringMap<std::string>;
  using JumpInfoMap = llvm::StringMap<std::string>;

  static constexpr int invalidInt = -1;

  const std::string confName;
  const std::string jumpTableName;

  BugInfoMap bugInfo;
  JumpInfoMap jumpInfo;


  // LLVM Native Data Structure
  std::unique_ptr<llvm::Module> LLVMModule;
  llvm::FunctionAnalysisManager FAM;

  llvm::Value* instrToAnalyze = nullptr;

  public:
  // passes for which we allow debug message to be shown
  // define the passes for which the debug messages you wish to see
  // Availble passes are: 
  //"DeleteNullPtrExceptionPass",
  //"DataDependencyPass",
  //"OptimizationPass"
  //"EventGraph"
  //"ControlDependencyPass",
  //"ProtocBuf"
  std::vector<std::string> debugOnlyPasses;

  CLODSDataManager() : 
    confName("../CLODS.conf"),
    jumpTableName("../jumpTable.conf")
  {

  }

  // Utility functions for database manager
  inline llvm::Module* getLLVMModule()
  {
    // return the raw pointer, ownership is preserved
    return LLVMModule.get();
  }

  inline void setLLVMModule(std::unique_ptr<llvm::Module>& M)
  {
    // enforcing the transfer of ownership to be explicit to the database
    LLVMModule = std::move(M);
  }

  inline llvm::FunctionAnalysisManager& getFAM() { return FAM; }


  inline llvm::Value* getInstrToAnalyze() { return instrToAnalyze; }
  inline void setInstrToAnalyze(llvm::Value* val) {assert(!instrToAnalyze); instrToAnalyze = val;}
  inline void clearInstrToAnalyzer() {instrToAnalyze = nullptr;}

  // Utility functions for processing configuration file
  bool readConfigs();
  int getIntFromBugInfoMap(const std::string& key);

  bool bootstrapCLODSStaticAnalyzer();
  void networkBootstrap();

  // utility functions for extracting conf information
  std::string getIRPath();
  std::string getFuncName();
  std::string getFileName();
  void getDebugPasses();
  int getDebugLevel();
  int getLineNumber();
  int getManualOverride();
  bool getEnableNetwork();

  // helper functions
  Instruction* mapLocationToInstruction();

  // Graal generated IR are subject to noise, following functions runs noise-cancelling pass on IR
  const std::vector<std::string> DeleteRedundentFunc = {
    "ImplicitExceptions_throwNewNullPointerException",
    "ImplicitExceptions_createNullPointerException",
    "StackOverflowCheckSnippets_throwNewStackOverflowError",
    "ImplicitExceptions_throwNewOutOfBoundsExceptionWithArgs",
    "ImplicitExceptions_throwNewClassCastExceptionWithArgs",
    "Safepoint_enterSlowPathSafepointCheck"
  };
  void cleanFunction(Function *function);

  // control-data flow communication data structure
  std::vector<BasicBlock *> dominatingBlocks;
};

extern CLODSDataManager CLODSManager;

// The level of detail of the printing debug information
extern int debugLevel;

template <class T> bool vectorContains(std::vector<T *> vec, T *compVal);
template <class T> bool vectorContains(std::vector<T *> vec, T *compVal) {
  if (vec.size() == 0) {
    return false;
  }
  for (auto elem : vec) {
    if (elem == compVal) {
      return true;
    }
  }
  return false;
}
namespace Java {
  std::string stripJavaSuffix(StringRef file);
  std::string convertJavaFormat(std::string className);
};
std::vector<std::string> getTypes(DISubprogram *subProgram);
StringRef getArgName(Argument *arg);
Instruction *getBlockCondition(BasicBlock &BB);
void debugSetUp();
Function *getCalledFunction(Value *instr);
Function *getCallerNonConst(const Function *caller);
Value *getCallerArgument(Instruction *call, Argument *arg);
std::vector<Instruction *> getCallInstructions(Function *caller,
                                               Function *callee);
bool isFunctionReflectInvoke(const Function *func);
Function *getCalledFunction(Value *instr);
std::vector<Value *> getMethodsAccessingObject(int fieldOffset,
                                               StringRef className);
inline llvm::raw_ostream &debug(const unsigned level) {
  unsigned currDebugLevel = debugLevel;
  return level <= currDebugLevel ? llvm::dbgs() : llvm::nulls();
}
DILocalVariable *getClassIfObject(Argument *arg);
Function *getFunctionOfValue(Value *val);
std::string getLineMetadata(Value* val);
void runControlDependency(Instruction *instrToAnalyze,
                          FunctionAnalysisManager &FAM);

std::vector<Value *> getReturnInstructionsOfFunction(Function &F);

bool isInsertZeroInitializer(Instruction *operand);

#endif /* B7D41679_F2C9_4C8C_878D_2D519F00A5E5 */
