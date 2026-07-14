#ifndef TREE_HPP
#define TREE_HPP

#include <iostream>
#include <sstream> 
#include <string> 
#include <cstdio>

#include <vector>
#include <map>
#include <unordered_map>
#include <unordered_set>
#include <deque>
#include <regex>
#include <stack>
#include <queue>

#include "Event.hpp"
#include "Log.hpp"

class TrieNode {
public:
    std::unordered_map<int, TrieNode*> children; // lineNum (ID) to child
    bool isEndOfLog; int endLogIdx;
    int lineNum; int loopId;
    
    TrieNode() {
        isEndOfLog = false; endLogIdx=-1;
        lineNum = -1; loopId = -1;
        std::unordered_map<int, TrieNode*> temp; children = temp;
        
    }
    TrieNode(int ID) {
        isEndOfLog = false; endLogIdx=-1;
        lineNum = ID; loopId = -1;
        std::unordered_map<int, TrieNode*> temp; children = temp;
    }
    
    bool operator== (const TrieNode& rhs) const;
    bool operator!= (const TrieNode& rhs) const;
};
typedef struct triePair {
    TrieNode* eventA;
    TrieNode* eventB;
    int depth;
} TriePair;
struct TriePrefix {
    bool div;
    int length;
    std::vector<int> prefix;
    TriePrefix(){
        div = false;
        length = 0;
    }
};
class Trie {
public:
    std::string entry; // Method entry
    TrieNode* root; // which should be the entry
    std::unordered_map<int, int> loopStartIds; // loop Id to lineNum ID
    std::unordered_map <int, int> parentLoop; // loop Id to loop Id

    std::unordered_map<int, TrieNode*> loopStartNodes;
    // std::unordered_set<int> ids_seen;

    // Initialize 
    Trie();
    Trie(std::string name);
    ~Trie();

    bool insertLog(Log* log, int idx);
    void print_Trie();
    void print_subTrie(TrieNode* node);
    
    bool init_contexts(std::unordered_map<int, int>& start);
    bool init_contexts(std::unordered_map<int, int>& start, std::unordered_multimap<int, int> end);
};
TriePrefix compareTries(Trie* fail, Trie* succeed);



#endif // TREE_HPP
