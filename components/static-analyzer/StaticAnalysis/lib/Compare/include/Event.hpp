#ifndef EVENT_HPP
#define EVENT_HPP

#include <iostream>
#include <sstream> 
#include <string> 
#include <cstdio>

#include <vector>
#include <map>
#include <unordered_map>

/**
 * is a line of code
 */
enum class EventType { // type of event
    undefined = 0,
    Condition,
    Location,
    Output,
    Invocation
};
    
class Event{
public:

    int lineNum; // line number
    int idx; // idx in log
    EventType type;
    Event* context;   
    std::string value;
    int loopId; int startLoopId;

    // Constructors
    Event();
    Event(const int num);
    Event(const int num, const EventType t);
    // Event(const int num, EventType t);
    
    bool operator== (const Event& rhs) const;
    bool operator!= (const Event& rhs) const;
    void print();
};

#endif