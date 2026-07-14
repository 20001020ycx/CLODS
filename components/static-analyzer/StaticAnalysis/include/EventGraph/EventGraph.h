#ifndef DB0316CE_677F_451A_BC26_31CA3C227808
#define DB0316CE_677F_451A_BC26_31CA3C227808
#include "Utility.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DirectedGraph.h"
#include "llvm/Analysis/DependenceAnalysis.h"
#include "llvm/Analysis/DependenceGraphBuilder.h"
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/IR/Instructions.h"

#include <map>
#include <vector>
#include <queue>

namespace llvm {
class DDGNode;
class EventNode;
class DDGEdge;
class EventEdge;
using DDGNodeBase = DGNode<DDGNode, DDGEdge>;
using EventNodeBase = DGNode<EventNode, EventEdge>;
using DDGEdgeBase = DGEdge<DDGNode, DDGEdge>;
using EventEdgeBase = DGEdge<EventNode, EventEdge>;
using DDGBase = DirectedGraph<DDGNode, DDGEdge>;
class LPMUpdater;

class EventNode : public EventNodeBase {
public:
  // a utility data structure where our data flow analysis can throw information
  // for the later look up
  struct EventUtil {
    // all call insts line number
    std::queue<std::string> callLineNumbers;
  };

  // eventInfoQuery contains information collected in the static code analysis for
  // which we wish to pass down to the event graph and store in the node or
  // edge
  std::map<Value*, EventUtil> eventInfoQuery;

  unsigned depth = 0;

  enum class EventKind {
    ConditionEvent,
    LocationEvent,
    InvocationEvent,
    OutputEvent,
    RootEvent,
    GenericEvent
  };
  EventNode() = delete;
  EventNode(Value *val, const EventKind K) : LLVMValue(val), Kind(K) {}
  EventNode(const EventNode &N) = default;
  EventNode(EventNode &&N) : EventNodeBase(std::move(N)), Kind(N.Kind) {}
  // virtual ~EventNode() = 0;

  EventNode &operator=(const EventNode &N) {
    DGNode::operator=(N);
    Kind = N.Kind;
    return *this;
  }

  EventNode &operator=(EventNode &&N) {
    DGNode::operator=(std::move(N));
    Kind = N.Kind;
    return *this;
  }

  /// Getter for the kind of this node.
  EventKind getKind() const { return Kind; }

  /// Setter for the kind of this node.
  void setKind(EventKind K) { Kind = K; }

  Value *getValue() const { return LLVMValue; }

  bool getIsHappend() const {return isHappend; }

  friend llvm::raw_ostream &operator<<(llvm::raw_ostream &out,
                                       const EventNode &obj) {
    if (obj.getKind() == EventNode::EventKind::LocationEvent) {
      out << "Location event node: " << *(obj.getValue()) << "\n";
    } else if (obj.getKind() == EventNode::EventKind::ConditionEvent) {
      out << "Condition event node: " << *(obj.getValue()) << "\n";
    } else if (obj.getKind() == EventNode::EventKind::GenericEvent) {
      out << "Generic event node: " << *(obj.getValue()) << "\n";
    } else if (obj.getKind() == EventNode::EventKind::RootEvent) {
      out << "Root event node\n";
    } else {
      out << "Invalid node!\n";
    }
    return out;
  }

private:
  EventKind Kind;
  Value *LLVMValue;

  // TODO: need interface, now we just hard code in here
  bool isHappend = false;
};

class EventEdge : public EventEdgeBase {
public:
  /// The kind of edge in the DDG
  enum class EdgeKind {
    ControlDep,
    DataDep,
    Rooted,
    Last = Rooted, // Must be equal to the largest enum value.
    FineGrain,
    CoarseGrain
  };

  explicit EventEdge(EventNode &N) = delete;
  EventEdge(EventNode &N, EdgeKind K) : EventEdgeBase(N), Kind(K) {}
  EventEdge(const EventEdge &E) : EventEdgeBase(E), Kind(E.getKind()) {}
  EventEdge(EventEdge &&E) : EventEdgeBase(std::move(E)), Kind(E.Kind) {}
  EventEdge &operator=(const EventEdge &E) = default;

  EventEdge &operator=(EventEdge &&E) {
    EventEdgeBase::operator=(std::move(E));
    Kind = E.Kind;
    return *this;
  }

  /// Get the edge kind
  EdgeKind getKind() const { return Kind; };
  void setKind(EdgeKind kind) { this->Kind = kind; }

  /// Return true if this is a def-use edge, and false otherwise.
  bool isDataDep() const { return Kind == EdgeKind::DataDep; }

  /// Return true if this is a memory dependence edge, and false otherwise.
  bool isControlDep() const { return Kind == EdgeKind::ControlDep; }

  /// Return true if this is an edge stemming from the root node, and false
  /// otherwise.
  bool isRooted() const { return Kind == EdgeKind::Rooted; }

  friend llvm::raw_ostream &operator<<(llvm::raw_ostream &out,
                                       const EventEdge &obj) {
    if (obj.getKind() == EdgeKind::Rooted) {
      dbgs() << "This is a root edge\n";
    } else if (obj.getKind() == EdgeKind::CoarseGrain) {
      dbgs() << "This is a coarse grain edge\n";
    } else if (obj.getKind() == EdgeKind::FineGrain) {
      dbgs() << "This is a fine grain edge\n";
    }
    return out;
  }

private:
  EdgeKind Kind;
};

} // namespace llvm

using namespace llvm;
class EventGraph {
private:
  // currEvent not only serves as a coarse-grain look-up entry point, but also 
  // stores all information collected during the static code analysis. We 
  // maintain a map in each coarse grain node to store all information required
  // for instrumentation.
  EventNode *currEvent;

public:
  DirectedGraph<EventNode, EventEdge> graph;

  void eventGraphBootstrap(Value *startingInstruction);

  void printEventGraphHelperBFS(EventNode *node, bool fineGrain);

  void printEventGraphCoraseGrain();
  void printEventGraphFineGrain();

  inline void setCurrEvent(EventNode *event) { currEvent = event; }
  inline EventNode *getCurrEvent() { return currEvent; }

  EventNode *findNode(Value *targetValue);
  EventNode* deleteNode(Value* val);

  void addNodeWithEdge(EventNode *source, Value *dest,
                       EventNode::EventKind nodeType,
                       EventEdge::EdgeKind edgeType);
  void promoteFineGrainNode(Value *val, EventNode *conditionEvent);
  std::vector<Value *> getGepInOrdersFineGrain();
  std::vector<EventNode*> findLeafNodes();
  std::vector<Function* > getStackTrace(Value* val);
  Function* getLastCaller(Value* val);
};

#endif /* DB0316CE_677F_451A_BC26_31CA3C227808 */

