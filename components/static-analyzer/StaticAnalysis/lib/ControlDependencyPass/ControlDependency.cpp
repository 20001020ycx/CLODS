//===-- HelloWorld.cpp - Example Transformations --------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "ControlDependency.h"
#include "Utility.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Pass.h"
#include "llvm/Support/CommandLine.h"

using namespace llvm;

AnalysisKey ControlDependency::Key;


void ControlDependency::getDominatingConditions(
    BasicBlock &BB, Function &F, PostDominatorTree &PDT,
    std::vector<BasicBlock *> &alreadyVisited) {
  // To avoid loops
  if (vectorContains(alreadyVisited, &BB)) {
    return;
  } else {
    alreadyVisited.push_back(&BB);
  }
  std::vector<BasicBlock *> controlBlocks;
  for (BasicBlock &B : F) {
    int total_successors = 0;
    int dominated_successors = 0;
    // errs() << "\nVisiting Block: " << B.getName() << "\n";
    for (auto succ : successors(&B)) {
      total_successors++;
      if (PDT.dominates(&BB, succ) || (&BB == succ)) {
        dominated_successors++;
      }
    }
    if ((dominated_successors > 0) &&
        (dominated_successors != total_successors)) {
      controlBlocks.push_back(&B);

      if (!(vectorContains(dominatingBlocks, &B))) {
        dominatingBlocks.push_back(&B);
      }

      // errs() << "\nBlock number is " << B.getName() << "\n";
    }
  }
  for (auto cb : controlBlocks) {
    if (cb->isEntryBlock()) {
      continue;
    }
    // errs() << "\n new recursion for " << cb->getName() << " \n";
    getDominatingConditions(*cb, F, PDT, alreadyVisited);
  }
}

std::vector<BasicBlock *>
ControlDependency::getPostDominanceFrontier(BasicBlock &BB, Function &F,
                                            PostDominatorTree &PDT) {
  std::vector<BasicBlock *> pdFrontier;
  for (auto IDom : PDT.getNode(&BB)->children()) {
    for (BasicBlock *pred : predecessors(IDom->getBlock())) {
      if (!PDT.dominates(&BB, pred)) {
        pdFrontier.push_back(pred);
      }
    }
  }
  return pdFrontier;
}

extern std::vector<Instruction *> conditionsIdentified;
extern unsigned instrumentationID;
extern std::vector<Value *> instrumentationValues;

ControlDependency::Result 
ControlDependency::run(Function &F, FunctionAnalysisManager &AM) {

  PostDominatorTree &PDT = AM.getResult<PostDominatorTreeAnalysis>(F);

  analysisInstr = cast<Instruction>(CLODSManager.getInstrToAnalyze());

  dbgs() << "Running control depenency pass on instr: " << *analysisInstr << "\n";

  std::vector<BasicBlock *> alreadyVisited;
  conditionsIdentified.clear();
  dominatingBlocks.clear();

  getDominatingConditions(*(analysisInstr->getParent()), F, PDT,
                          alreadyVisited);
  
  CLODSManager.clearInstrToAnalyzer();

  return dominatingBlocks;
}
