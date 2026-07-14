#ifndef LOG_HPP
#define LOG_HPP

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

class Log {
public:
    std::deque<std::string> to_parse;
    std::vector<Event*> parsed;
    std::string entry; // Method entry
    // std::unordered_map<int, int> loopIds;
    std::unordered_map<int, int> loopStartIds;
    std::unordered_map <int, int> parentLoop;
    // std::unordered_map <int, int> loopEndIds;
    std::unordered_set<int> ids_seen;
    
    std::unordered_map<int, Event*> contexts;
    std::unordered_map<int, std::unordered_set<Event*>> contextMap; // idx in the Log, not lineNum

    bool fail;
    // Initialize log with a string stream
    Log() {fail = false;}
     // Copy constructor
    Log(const Log& other);

    Log& operator=(const Log& rhs);

    ~Log();

    // Parse the next event from the log
    Event* parseNextLine();

    Event* getEvent(int idx);
    bool parseAll();
    void printParsed();
    void printAll();
    void printContexts();
    void printContexMaps();
    void printLoops();
    void printLoopMaps();
    bool failed();
    bool init_contexts(std::unordered_map<int, int>& start);
    bool init_contexts(std::unordered_map<int, int>& start, std::unordered_multimap<int, int> end);
    bool set_contexts(std::vector<int>& contexts, int n);
};
int compare_one_log(Log* A, Log* B);
std::pair<int, std::vector<Event*>> bfs_start(Log* A, Log* B);
std::pair<int, std::vector<Event>> compare_log_contexts(Log* A, Log* B);
std::pair<int, std::vector<Event*>> loop_dfs(Log* A, Log* B);
std::pair<int, std::vector<Event>> compare_log_maploops(Log* A, Log* B);
typedef struct node {
    Event* eventA;
    Event* eventB;
    int depth;
} Node;
typedef struct return_prefix {
    Log* failed;
    bool div;
    int length;
    std::vector<Event> prefix;
} Prefix;
#endif // LOG_HPP
