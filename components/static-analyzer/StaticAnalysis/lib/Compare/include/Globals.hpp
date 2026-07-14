#ifndef GLOBALS
#define GLOBALS

#include <iostream>
#include <sstream> 
#include <string> 
#include <cstdio>

#include <vector>
#include <map>
#include <unordered_map>
#include <unordered_set>

#include "Event.hpp"
#include "Log.hpp"

std::unordered_set<std::string> java_var_types = {"int", "boolean", "String", "double", "char", "float", "long", "short", "byte"};
/*
protected DatanodeStorageInfo chooseRandom(numOfReplicas...) /////////00000000000000////////////////////////////
      
    int numOfAvailableNodes = clusterMap.countNumOfAvailableNodes(scope, excludedNodes);

    while(numOfReplicas > 0 && numOfAvailableNodes > 0) { //////////111111111111111111111111111////////////////
        DatanodeDescriptor chosenNode = clusterMap.chooseRandom(scope);
          
        if (excludedNodes.add(chosenNode)) { //was not in the excluded list //////////22222222222222222222//////////////////
            numOfAvailableNodes--;

            int i;
            for(i = 0; i < storages.length; i++) { ///////////////333333333333333333333333333////////////////

                final int newExcludedNodes = addIfIsGoodTarget(blkSize);
                if (newExcludedNodes >= 0) {  //////////////4444444444444444444444/////////////////

                    numOfReplicas--;   /////////////////////////////////555555555555555555555////////////////////////////////////

                    numOfAvailableNodes -= newExcludedNodes;
                    break; // break out of for (ID = 3)
                }
            }

        }
    }
      
    if (numOfReplicas>0) { //////////////////66666666666666//////////66666666666666666666666////////////////////////////////////////////

        throw new NotEnoughReplicasException(detail);
    }
    
    return firstChosen;

}

*/

int compare_log_context(Log* A, Log* B){ return compare_one_log(A, B);}
#endif // GLOBALS