//===- DDG.cpp - Data Dependence Graph -------------------------------------==//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// The implementation for the data dependence graph.
//===----------------------------------------------------------------------===//
#include "EventGraph/EventGraph.h"
#include "llvm/ADT/SCCIterator.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/LoopIterator.h"
#include "llvm/Support/CommandLine.h"

#define DEBUG_TYPE "EventGraph"

using namespace llvm;

// bootstrap the event graph with hard coded starting node
// TODO: this should be handled more elegantly in the future
void EventGraph::eventGraphBootstrap(Value *startingInstruction) {
  EventNode *root = new EventNode(nullptr, EventNode::EventKind::RootEvent);
  EventNode *start =
      new EventNode(startingInstruction, EventNode::EventKind::LocationEvent);
  graph.addNode(*root);
  graph.addNode(*start);
  EventEdge *edge = new EventEdge(*start, EventEdge::EdgeKind::Rooted);
  graph.connect(*root, *start, *edge);
  this->setCurrEvent(start);
  this->printEventGraphFineGrain();
}

void EventGraph::printEventGraphHelperBFS(EventNode *node, bool fineGrain) {
  std::queue<EventNode *> q;
  std::unordered_set<EventNode *> visited;

  q.push(node);
  visited.insert(node);
  while (!q.empty()) {
    int levelSize = q.size();
    for (int i = 0; i < levelSize; i++) {
      EventNode *top = q.front();
      q.pop();
      
      // skip all nodes with empty edge as they already appeared (Note that at least we have one
      // edge for back tracing, except root)
      if (top != *graph.begin() && top->getEdges().size() == 1) continue;
      LLVM_DEBUG(debug(1) << *top << "\n");

      for (auto edge : top->getEdges()) {

        // we are doing forward trace
        if (edge->getTargetNode().depth < top->depth) {continue;}

        // Only printing edges in the granularity we cares
        if (!fineGrain && edge->getKind() == EventEdge::EdgeKind::FineGrain) {
          continue;
        }        
        
        if (fineGrain && edge->getKind() == EventEdge::EdgeKind::CoarseGrain) {
          continue;
        }

        LLVM_DEBUG(debug(1) << "edge is: " << *edge << "and its target is: \n");
        LLVM_DEBUG(debug(1) << edge->getTargetNode() << "\n");

        if (visited.find(&edge->getTargetNode()) == visited.end()) {
          q.push(&edge->getTargetNode());
          visited.insert(&edge->getTargetNode());
        }
      }
    }
    LLVM_DEBUG(debug(1) << "\n\n");
  }
}

// print event graph in the event granularity (coarse-grain)
void EventGraph::printEventGraphCoraseGrain() {
  LLVM_DEBUG(debug(1) << "Printing Event Graph in Corase Grain Manner: \n");
  LLVM_DEBUG(debug(1) << "Current event ptr is: " << *currEvent << "\n");
  auto node = *graph.begin();
  printEventGraphHelperBFS(node, false);
  LLVM_DEBUG(debug(1) << "\n");
}

// print event graph in the LLVM instruction granularity (coarse-grain)
void EventGraph::printEventGraphFineGrain() {
  LLVM_DEBUG(debug(1) << "Printing Event Graph in Fine Grain Manner: \n");
  LLVM_DEBUG(debug(1) << "Current event ptr is: " << *currEvent << "\n");
  auto node = *graph.begin();
  printEventGraphHelperBFS(node, true);
  LLVM_DEBUG(debug(1) << "\n");
}

// this function aims to look up leaf nodes that located at the deepest level 
// of the graph. We are NOT interested in the leaf node for which our instrumentation
// tool did not pick as we can conclude that they are not executed in the 
// control flow
std::vector<EventNode*> EventGraph::findLeafNodes() {
  std::vector<EventNode*> result;
  auto node = *graph.begin();

  std::queue<EventNode *> q;
  std::unordered_set<EventNode *> visited;

  q.push(node);
  //visited.insert(node);
  while (!q.empty()) {
    int levelSize = q.size();
    for (int i = 0; i < levelSize; i++) {
      EventNode *top = q.front();
      q.pop();

      for (auto edge : top->getEdges()) {
        if (edge->getKind() == EventEdge::EdgeKind::FineGrain) {
          continue;
        }

        q.push(&edge->getTargetNode());
      }
      
      if (top->getEdges().empty()) {
        result.push_back(top);
      }
    }
    // if there's any node in the queue, that means we have not reached the 
    // deepest level, clear the result
    if (!q.empty()) result.clear();
  }
  return result;
}

EventNode *EventGraph::findNode(Value *targetValue) {
  for (auto *node : graph) {
    if (node->getValue() == targetValue)
      return node;
  }

  return nullptr;
}

EventNode* EventGraph::deleteNode(Value* val) {
  auto delNode = findNode(val);
  EventNode* delNodeParent = nullptr;

  for (auto edge : delNode->getEdges()) {
    // skip all children connecting to delNode
    if (edge->getTargetNode().depth > delNode->depth) {continue;}

    if (edge->getKind() == EventEdge::EdgeKind::FineGrain)
      delNodeParent = &edge->getTargetNode();
  }

  graph.removeNode(*delNode);

  return delNodeParent;
}

void EventGraph::addNodeWithEdge(EventNode *source, Value *dest,
                                 EventNode::EventKind nodeType,
                                 EventEdge::EdgeKind edgeType
                                  ) {
  assert(source && "Source of the adding node is null");
  assert(dest && "Destination of the adding node is null");

  EventNode *newNode;
  // if already existed, connect to the existing one rather than building new
  // node
  if (auto *destNode = findNode(dest)) {
    newNode = destNode;
  } else {
    newNode = new EventNode(dest, nodeType);
    graph.addNode(*newNode);
  }

  newNode->depth = source->depth + 1;

  EventEdge *edge = new EventEdge(*newNode, edgeType);
  graph.connect(*source, *newNode, *edge);

  // create back edge for backtrace
  EventEdge *backEdge = new EventEdge(*source, edgeType);
  graph.connect(*newNode, *source, *backEdge);
}

// As we collect LLVM instruction traversed in data flow analysis, we have
// already inserted location event as fine-grain node into the graph.
// Now, We need to promote them into the real location event node which is
// coarse grain
void EventGraph::promoteFineGrainNode(Value *val, EventNode *conditionEvent) {
  auto *destNode = findNode(val);

  SmallVector<EventEdge *, 10> edgeList;
  graph.findIncomingEdgesToNode(*destNode, edgeList);
  for (auto* edge : edgeList) {
    EventNode *eventNode = &edge->getTargetNode();
    eventNode->setKind(EventNode::EventKind::LocationEvent);
  }

  EventEdge *edge = new EventEdge(*destNode, EventEdge::EdgeKind::CoarseGrain);
  graph.connect(*conditionEvent, *destNode, *edge);
}


std::vector<Value *> EventGraph::getGepInOrdersFineGrain() {
  std::vector<Value *> result;
  std::stack<EventNode *> q; // we respect the order in the data flow analysis
  std::unordered_set<EventNode *> visited;

  // we only search within two coarse-grain events inclusively
  LLVM_DEBUG(debug(3) << "[getGepInOrdersFineGrain]:starting coarse grain node: " << *currEvent << "\n");
  q.push(currEvent);

  while (!q.empty()) {
    EventNode *top = q.top();
    q.pop();

    Value *valueInGenericEvent = top->getValue();
    if (isa<GetElementPtrInst>(valueInGenericEvent)) {
      result.push_back(valueInGenericEvent);
    }

    for (auto edge : top->getEdges()) {
      if (visited.find(&edge->getTargetNode()) == visited.end()) {
        // we are doing forward trace
        if (edge->getTargetNode().depth < top->depth) {continue;}
        q.push(&edge->getTargetNode());
        visited.insert(&edge->getTargetNode());
      }
    }
  }

  return result;
}

std::vector<Function* > EventGraph::getStackTrace(Value* val) {
  std::unordered_set<EventEdge *> visited;
  std::stack<EventNode *> q;
  std::vector<Function* > result;
  std::unordered_set<Function *> rewoundStacks;
  q.push(findNode(val));


  // dfs backtrace
  while (!q.empty()) {
    EventNode *top = q.top();
    LLVM_DEBUG(debug(1) << "[getStackTrace]:Current top: " << *top << "\n");
    q.pop();

    // analyzed argument means we rewind a stack
    if (auto topArg = dyn_cast<Argument>(top->getValue())) {
      if (topArg->getParent()->hasName()) {
        LLVM_DEBUG(debug(1) << "[getStackTrace]:Arg parent name: " << topArg->getParent()->getName().str() << "\n");
      }
      rewoundStacks.insert(topArg->getParent());
    }

    // analyzed callBase means we create a stack:
    // This include both callInst and invokeInst
    if (auto callInstTop = dyn_cast<CallBase>(top->getValue())) {
      auto topFunc = callInstTop->getCalledFunction();
      if (topFunc) {
        if (topFunc->hasName()) {
          LLVM_DEBUG(debug(1) << "[getStackTrace]:Func name: " << topFunc->getName().str() << "\n");
        }
        if (rewoundStacks.find(topFunc) == rewoundStacks.end()){
          result.push_back(topFunc);
        }
      } else {
        // This is referring to function like call %133
        // This should be handled by checking its metadata of its frame point
        assert(false && "Calling function pointer in a register, please implement metadata lookup of frame point");
      }
    }

    for (auto edge : top->getEdges()) {
      if (visited.find(edge) == visited.end()) {
        auto targetNode = edge->getTargetNode();
        // we only back trace, going shallow in the event graph
        if (targetNode.depth < top->depth) {
          q.push(&edge->getTargetNode());
          visited.insert(edge);
        }
        
        // This is the very first instruction, we should add its function call 
        // into the stack
        if (top->depth == 0) {
          if (auto topInst = dyn_cast<Instruction>(top->getValue())) {
            auto topFunc = topInst->getParent()->getParent();
            if (rewoundStacks.find(topFunc) == rewoundStacks.end()){
              result.push_back(topFunc);
            }
          }
        }
      }
    }
  }

  return result;
}


Function* EventGraph::getLastCaller(Value* val) {
  printEventGraphFineGrain();
  std::vector<Function*> stackTraces = getStackTrace(val);
  if (stackTraces.empty()) return nullptr;

  LLVM_DEBUG(debug(1) << "Current function in the stack trace: ");
  for (auto stackTrace : stackTraces) {
    LLVM_DEBUG(debug(1) << stackTrace->getName() << "\n");
  }

  return *stackTraces.begin();
}


