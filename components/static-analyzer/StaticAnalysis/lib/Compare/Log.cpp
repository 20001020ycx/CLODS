#include "Event.hpp"
#include "Log.hpp"

     // Copy constructor
Log::Log(const Log& other) {
    to_parse = other.to_parse;
    parsed = other.parsed;
    entry = other.entry;
    contexts[-1] = nullptr;
}

Log& Log::operator=(const Log& rhs) {
    if (this != &rhs) { // not same object
        to_parse = rhs.to_parse;
        parsed = rhs.parsed;
        entry = rhs.entry;
        loopStartIds = rhs.loopStartIds;
        parentLoop = rhs.parentLoop;
        ids_seen = rhs.ids_seen;
        contexts = rhs.contexts; contextMap = rhs.contextMap;
    }
    return *this;
}

Log::~Log(){
    for(int i=0; i<parsed.size(); i++){
        if(parsed[i] != nullptr){
            delete parsed[i];
        }
    }
    to_parse.clear();
    parsed.clear();
}
static const std::regex numRegex("^[-+]?[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?$");
bool is_number(std::string str){   
    return std::regex_match(str, numRegex);
}
Event* Log::parseNextLine() { // parse next line of log
    if(to_parse.empty()){
        return nullptr;
    }
    Event* e = nullptr;
    
    std::string::size_type temp_id;
    std::string line = to_parse.front();
    
    temp_id = line.find("Method Entry"); // assume method entry is in the form :
                                          //  // [Method Entry]class.method(file:line number)
    if(temp_id != std::string::npos){ 
        line = line.substr(temp_id+14);
        entry = line;
        temp_id = line.find("(");
        e = new Event();
        e->type = EventType::Invocation;
        if(temp_id != std::string::npos){
            e->value = line.substr(0, temp_id);
            line = line.substr(temp_id+1);
        }
        temp_id = line.find(":"); // the line number (or -1 if not found)
        if(temp_id != std::string::npos){
            std::stringstream ss(line.substr(temp_id+1));
            int id=-1; ss >> id;
            e->lineNum = id; 
        }
    }
    // if is not a method entry; if there is ID= after [Method Entry], rewrites its ID 
    temp_id = line.find("ID="); // std::cout << "ID! " << std::endl;
    if(temp_id != std::string::npos){
        line = line.substr(temp_id+3);
        temp_id = line.find(",");
        int id = std::stoi(line.substr(0, temp_id)); // between ID and ,
        if(e!=nullptr) {
            e->lineNum = id;
        }else{
            e = new Event(id);
        }
        
        if(temp_id != std::string::npos){ // the part after ,
            line = line.substr(temp_id+1);
            temp_id = line.find("loop="); // loop Id, if exist
            if(temp_id != std::string::npos){
                line = line.substr(temp_id+5); // after loop=
                
                temp_id = line.find(",");
                int loopId = std::stoi(line.substr(0, temp_id)); // between loop and ,
                e->loopId = loopId;
                line = line.substr(temp_id+1); // after ,
                
            }
            e->value = line;
            
            if(e->value=="true" || e->value=="false"){
            e->type = EventType::Condition;
            }else if(is_number(e->value)){
                e->type = EventType::Location;
            }else{
                e->type = EventType::Output;
            }
        }

    }
    
    to_parse.pop_front();
    if(e==nullptr){
        std::cout << "parse fail: " << line << std::endl;
        return nullptr; // failed to parse
    }
    // if(e!=nullptr && e->lineNum==6 && e->value=="true"){
    //     fail = true;
    // }
//    
      e->idx = parsed.size();
//    if(e->idx ==0){
//        contexts.insert({-1, e});
//    }
//    if(e->loopId > -1){ // is in a loop
//        if(contexts.find(e->loopId)!=contexts.end()){ 
//            e->context = contexts[e->loopId];
//        }
//    }
//    
    if(e->loopId>-1 && ids_seen.find(e->loopId)==ids_seen.end()){ // is a new loop
        loopStartIds.insert({e->lineNum, e->loopId});
        ids_seen.insert(e->loopId);
    }
    
    auto it = loopStartIds.find(e->lineNum);
    if(it!=loopStartIds.end()){ // is the condition of a known loop
        e->startLoopId = it->second;
//        if(contexts.find(e->loopId)!=contexts.end()){
//            e->context = contexts[e->loopId]; // context is last loop
//        }else{
//            if(parentLoop.find(e->loopId)!=parentLoop.end())
//                {e->context = contexts[parentLoop[e->loopId]];} // contexts of those in start of loops
//            else
//                {e->context = contexts[-1];}
//        }
//        contexts[e->startLoopId] = e; // update the context of a loopId
//        // TODO find parent loop
    }
//    
//    
//    
//    if(e->context != nullptr){
//        contextMap[e->context->idx].insert(e);
//    }
//    if(e->idx>0){
//        contextMap[e->idx-1].insert(e);
//    }
    parsed.push_back(e); // std::cout << "parsed " << e->lineNum << std::endl;
    return e;
}

bool Log::set_contexts(std::vector<int>& contexts, int n){ 
    parseAll(); // manually set the contexts for testing, shouldn't use this 
    int size = parsed.size();
    for(int i=0; i<n&&i<size; i++){
        parsed[i]->context = parsed[contexts[i]];
    }
    return true;
}

Event* Log::getEvent(int idx){
    if(idx < 0 || idx >= (parsed.size()+to_parse.size())) {return nullptr;}
    int n = parsed.size();
    if(idx < n){ // which should equal current
        return parsed[idx];
    }
    Event* e = nullptr;
    for(int i=n; i<=idx; i++){
       e = parseNextLine();
    }
    return e;
}

bool Log::parseAll(){
    while(!to_parse.empty()){
        parseNextLine();
    }
    return (to_parse.size()==0);
}



int compare_one_log(Log* A, Log* B){ // this is dead lock compare, not considering loops
    int idx = 0;                     // only need to return length since the prefix must be continuous
    int nA = A->parsed.size() + A->to_parse.size();
    int nB = B->parsed.size() + B->to_parse.size();
    while((idx < nA) && (idx < nB)){
        Event* ef = A->getEvent(idx); 
        Event* es = B->getEvent(idx); 
        if(*es != *ef){ // compare lineNum
            break; // diverge
        }
        idx++;
    }
    return idx; // length of common prefix
}


bool Log::failed(){
    parseAll();
    return fail;
}

// assume logs have loop Ids, and all loops are map loops
std::pair<int, std::vector<Event>> compare_log_maploops(Log* A, Log* B){
    std::vector<Event> prefix; 
   
    auto result = loop_dfs(A, B);
    int length = result.first;
    
    for(Event* e : result.second){
        prefix.push_back(*e);
    }
    return std::make_pair(length, prefix);
}

std::pair<int, std::vector<Event*>> loop_dfs(Log* A, Log* B){ // actually bfs
    // std::vector<Event> prefix;
    A->parseAll(); B->parseAll();
    int sizeA = A->parsed.size(); int sizeB = B->parsed.size();
    std::vector<Event*> current;
    if(sizeA==0 || sizeB==0) {return std::make_pair(0, current);}

    std::queue<Node> q; // Node: Event in A and B, and depth
    q.push({A->getEvent(0), B->getEvent(0), 1});
    
    int length = 0;

    while (!q.empty()) {
        Node node = q.front(); 
        q.pop();
        if(node.eventA==nullptr || node.eventB==nullptr){
            continue;
        }
        if (*(node.eventA) == *(node.eventB)) {
            if (node.depth > length) {
                length = node.depth;
                current.push_back(node.eventA);
            }
            // Enqueue 
            int idxA = node.eventA->idx; int idxB = node.eventB->idx; 
            std::vector<Event*> childrenA; // add possible next nodes to the queue
            Event* nextA = A->getEvent(idxA+1);
            if(nextA!=nullptr){
                childrenA.push_back(nextA); // next event
                if(nextA->startLoopId != -2){ // starting or immediately after ending a loop
                    for(int i=idxA+2; i<A->parsed.size(); i++){
                        if(A->parsed[i]->startLoopId == nextA->startLoopId){
                            childrenA.push_back(A->parsed[i]); 
                        }
                    }
                }
            }
                    
            std::vector<Event*> childrenB; Event* nextB = B->getEvent(idxB+1);
            if(nextB!=nullptr){
                childrenB.push_back(nextB); // next event
                if(nextB->startLoopId != -2){ // starting or immediately after ending a loop
                    for(int i=idxB+2; i<B->parsed.size(); i++){
                        if(B->parsed[i]->startLoopId == nextB->startLoopId){
                            childrenB.push_back(B->parsed[i]); 
                        }
                    }
                }
            }
            
            for (auto& childA : childrenA) {
                // For each child in A, if it also exists in B, enqueue them
                for (auto& childB : childrenB) {
                    if (*childA == *childB) {
                        q.push({childA, childB, node.depth+1});
                    }
                }
            }
        }
    }
    return std::make_pair(length, current);
}


////////////// PRINTS //////////////////////////////////////////////

void Log::printParsed(){
    for(int i=0; i<parsed.size(); i++){
       parsed[i]->print(); 
       std::cout << ", " ;
    }
    std::cout << std::endl;
}

void Log::printAll(){
    parseAll();
    printParsed();
}
void Log::printContexts(){
    for(int i=1; i<parsed.size(); i++){
       parsed[i]->print(); 
       if(parsed[i]->context == nullptr){
            std::cout << " ctx: -1";
        }else{
            std::cout << " ctx: ";
            parsed[i]->context->print();
        }
       std::cout << std::endl ;
    }
    std::cout << std::endl;
}
void Log::printContexMaps(){
    for(auto it : contextMap){
        if(it.first>=0){
            getEvent(it.first)->print();
        }else{
            std::cout << it.first;
        }
        std::cout << ": " << std::endl << "-> ";
        for(Event* e : it.second){
            e->print(); std::cout << " ";
        }
        std::cout << std::endl;
    }
}
void Log::printLoops(){
    for(int i=0; i<parsed.size(); i++){
       parsed[i]->print(); 
       std::cout << " loop id: " << parsed[i]->loopId;
       std::cout << ", " ;
    }
    std::cout << std::endl;   
}
void Log::printLoopMaps(){
    std::cout << "loopStartIds:" << std::endl;
    for(auto it : loopStartIds){
        std::cout << "ID " << it.first << ": loop Id " << it.second << std::endl;
    }
}

std::pair<int, std::vector<Event*>> bfs_start(Log* A, Log* B){ 
    // std::vector<Event> prefix;
    A->parseAll(); B->parseAll();
    int sizeA = A->parsed.size(); int sizeB = B->parsed.size();
    std::vector<Event*> current;
    if(sizeA==0 || sizeB==0) {return std::make_pair(0, current);}

    std::queue<Node> q;
    q.push({A->getEvent(0), B->getEvent(0), 1});
    
    int length = 0;

    while (!q.empty()) {
        Node node = q.front(); 
        q.pop();
        if(node.eventA==nullptr || node.eventB==nullptr){
            continue;
        }
        if (*(node.eventA) == *(node.eventB)) {
            if (node.depth > length) {
                length = node.depth;
                current.push_back(node.eventA);
            }
                // Enqueue children
            auto childrenA = A->contextMap[node.eventA->idx];
            auto childrenB = B->contextMap[node.eventB->idx];
            
            for (auto& childA : childrenA) {
                // For each child in A, if it also exists in B, enqueue them
                for (auto& childB : childrenB) {
                    if (*childA == *childB) {
                        q.push({childA, childB, node.depth+1});
                    }
                }
            }
        }
    }
    return std::make_pair(length, current);
}
std::pair<int, std::vector<Event>> compare_log_contexts(Log* A, Log* B){
    int length = compare_one_log(A, B);
    std::vector<Event> prefix;

    auto result = bfs_start(A, B);
    // std::cout << "bfs " << result.first << std::endl;
    // for(Event* e : result.second){
    //     std::cout << e->idx << ":L" << e->lineNum << " ";
    // }std::cout << std::endl;

    // if(result.first > length){
        for(Event* e : result.second){
            prefix.push_back(*e);
        }
        return std::make_pair(length, prefix);
    // }
        
//    for(int i=0; i<length; i++){ 
//        prefix.push_back(*A->getEvent(i));
//    }
//    return std::make_pair(length, prefix);

}

std::pair<int, std::vector<Event*>> context_bfs(Log* A, Log* B){
    // std::vector<Event> prefix;
    A->parseAll(); B->parseAll();
    int sizeA = A->parsed.size(); int sizeB = B->parsed.size();
    std::vector<Event*> current;
    if(sizeA==0 || sizeB==0) {return std::make_pair(0, current);}

    std::queue<Node> q;
    q.push({A->getEvent(0), B->getEvent(0), 1});
    
    int length = 0;

    while (!q.empty()) {
        Node node = q.front(); 
        q.pop();
        if(node.eventA==nullptr || node.eventB==nullptr){
            continue;
        }
        if (*(node.eventA) == *(node.eventB)) {
            if (node.depth > length) {
                length = node.depth;
                current.push_back(node.eventA);
            }
            // Enqueue 
            int idxA = node.eventA->idx; int idxB = node.eventB->idx; 
            std::vector<Event*> childrenA; 
            Event* nextA = A->getEvent(idxA+1);
            if(nextA!=nullptr){
                childrenA.push_back(nextA); // next event
                if(nextA->startLoopId != -2){ // starting or immediately after ending a loop
                    for(int i=idxA+2; i<A->parsed.size(); i++){
                        if(A->parsed[i]->startLoopId == nextA->startLoopId){
                            childrenA.push_back(A->parsed[i]); 
                        }
                    }
                }
            }
                    
            std::vector<Event*> childrenB; Event* nextB = B->getEvent(idxB+1);
            if(nextB!=nullptr){
                childrenB.push_back(nextB); // next event
                if(nextB->startLoopId != -2){ // starting or immediately after ending a loop
                    for(int i=idxB+2; i<B->parsed.size(); i++){
                        if(B->parsed[i]->startLoopId == nextB->startLoopId){
                            childrenB.push_back(B->parsed[i]); 
                        }
                    }
                }
            }
            
            for (auto& childA : childrenA) {
                // For each child in A, if it also exists in B, enqueue them
                for (auto& childB : childrenB) {
                    if (*childA == *childB) {
                        q.push({childA, childB, node.depth+1});
                    }
                }
            }
        }
    }
    return std::make_pair(length, current);
}

