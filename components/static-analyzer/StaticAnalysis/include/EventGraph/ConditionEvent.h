// #ifndef C01049E4_1131_415D_8AAB_4AB884F2D5A0
// #define C01049E4_1131_415D_8AAB_4AB884F2D5A0
// #include "Event.h"
// #include "llvm/IR/Instructions.h"
// #include <iostream>

// using namespace llvm;

// class ConditionEvent : public Event {
//   Instruction *condition;
//   BranchInst *branch;
//   ConditionEvent(BranchInst &branch) {
//     super(dyn_cast<Instruction>(branch));
//     this->branch = &branch;
//     if (branch->isConditional()) {
//       this->condition = dyn_cast<Instruction>(branch->getCondition());
//     } else {
//       this->condition = NULL;
//     }
//   }
// };

// #endif /* C01049E4_1131_415D_8AAB_4AB884F2D5A0 */
