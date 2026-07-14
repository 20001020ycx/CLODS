#include "Event.hpp"

Event::Event() {
    lineNum = -1; idx = -1;
    type = EventType::undefined; 
    context = nullptr; 
    loopId = -1; startLoopId = -2;
}
Event::Event(const int num) : lineNum(num) {
    type = EventType::undefined; idx = -1;
    context = nullptr; 
    loopId = -1; startLoopId = -2;
}
Event::Event(const int num, const EventType t) : lineNum(num), type(t) {
    context = nullptr; idx = -1;
    loopId = -1; startLoopId = -2;
}
bool Event::operator== (const Event& rhs) const{ // compare events across logs
    if(lineNum != rhs.lineNum || type != rhs.type ){ // not same line number
        return false;
    }
    // if(type == EventType::Condition){
    //     // if conditional, value should be same
    //     if(value != rhs.value){
    //         // return false;
    //     }
    // }
    // should also compare context here
    return true;
}

bool Event::operator!= (const Event& rhs) const{
    return !(this->operator==(rhs));
}
void Event::print(){
    std::cout << "idx " << idx << ":ID=" << lineNum << "," << value ;
}
