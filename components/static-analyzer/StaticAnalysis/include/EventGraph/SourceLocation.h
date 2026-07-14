#ifndef B4C03D4E_D84B_4FAD_AE65_F32091D7D59C
#define B4C03D4E_D84B_4FAD_AE65_F32091D7D59C

#include "Event.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Pass.h"
#include <fstream>
#include <string>

using namespace llvm;

class SourceLocation {
  unsigned lineNum = -1;
  StringRef fileName = "";
  StringRef dir = "";
  StringRef methodName = "";

public:
  SourceLocation(Instruction I) {
    if (DebugLoc loc = I.getDebugLoc()) {
      DISubprogram *subProgram = I.getFunction()->getSubprogram();
      lineNum = loc.getLine();
      if (subProgram != NULL) {
        methodName = subProgram->getName();
        fileName = subProgram->getFile()->getFilename();
        dir = subProgram->getFile()->getDirectory();
      }
    }
  }
};

#endif /* B4C03D4E_D84B_4FAD_AE65_F32091D7D59C */
