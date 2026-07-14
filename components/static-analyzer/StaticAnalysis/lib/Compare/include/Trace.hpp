#ifndef TRACE_HPP
#define TRACE_HPP

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

class Caller{
    public:
    std::string function_name;
    int line_number;
    bool valid;
    Caller(){
        line_number = -1;
        valid = false;
    }
};
class Trace {
public:
    std::vector<std::string> lines;
    std::string thread;

    bool fail;
    
    Trace() {}
    Trace(std::string name);
    ~Trace();

    void print();
    Caller find_caller(std::string function_name, int target_line);
};

std::string compare_trace(Trace* t1, Trace* t2);
#endif // TRACE_HPP
