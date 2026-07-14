#include <iostream>
#include <sstream> 
#include <fstream>
#include <string> 
#include <cstdio>

#include <vector>
#include <map>
#include <unordered_map>
#include <regex>
#include <cassert>

#include "Compare.h"
#include "Event.hpp"
#include "Log.hpp"
#include "Globals.hpp"
#include "Trace.hpp"
#include "PrefixTree.hpp"

#define DIV 0
#define TRACE 1
#define ARG 2

int compare (int argc, char *argv[]){    ////////////////////////////////////////////////////////////////////
    std::cout << "argv: ";
    for(int i=0; i<argc; i++){
        std::cout << argv[i] << ", ";
    }std::cout << std::endl;
    int resultID = ENODIV;
    int what_to_do = DIV; 
    std::string file_path = "../logs/";
    std::string base_path = "/home/ubuntu/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/";
    if(argc>=2){         // ./compare {file name} {to do} {failureIndicator} {newLogIndicator}
        file_path += argv[1];    
    } //"";
    if(argc>=3){
        std::stringstream ss (argv[2]);         // 0: find divergence
        ss >> what_to_do;                   // 1: print stack trace
        std::cout << "to do: " << what_to_do << std::endl; // 2: find argument value
    }
    std::ifstream file1(file_path);
    std::cout << "file path: " << file_path << std::endl;
    if (!file1.is_open()) {
        return ENOOPEN;
    }

    int failure_id = 99;
    std::string failureIndicator = "ID=" + std::to_string(failure_id); 
    std::string newLogIndicator = "Method Entry";   // start new log
    std::string arg_value = "-1";
    std::string caller_for = "";
    std::string target_id; int target_line = -1;
    if(argc>=4){
        failureIndicator = argv[3];
        std::cout << "Indicator: " << failureIndicator << std::endl;
    } //"";
    if(argc>=5){
        if(what_to_do==ARG){
            target_id = argv[4];
        }else{
            newLogIndicator = argv[4];
            if(what_to_do==TRACE){
                caller_for = argv[4];
            }
        }
    }
    if(what_to_do == TRACE){    ////// TODO = 1 //// PRINT STACK TRACE ///////////////////////////
        std::vector<FuncCall> rules;
        return find_caller(file_path, failureIndicator, caller_for, rules, target_line);
        
    }else if(what_to_do == DIV){

        return find_divergence(file_path, failureIndicator, newLogIndicator);
    
    }
    else if(what_to_do == ARG){ ///// TODO = 2 /////////// VARIABLE //////////////////////////////////
        std::cout << "searching for argument value " << arg_value << std::endl;
        std::string target = "ID=" + target_id;

        bool found = false;
        std::string arg_value = ""; // value (DBL_MAX in this case)
        // std::string::size_type temp_id;
        Log* log = new Log(); int idx = 0;
        std::string line;
        while(std::getline(file1, line)){
            std::string::size_type temp_id = line.find("Stack Trace");
            if(temp_id != std::string::npos){ continue; } // is stack trace, ignore
            temp_id = line.find("BM");
            if(temp_id == std::string::npos){ continue; } // no BM, is stack trace, ignore
            log->to_parse.push_back(line);
            log->parseNextLine();

            temp_id = line.find(target); 
            if(temp_id != std::string::npos){ // is the target method
                temp_id = line.find(failureIndicator); 
                if(temp_id != std::string::npos){ // is target method in failed run
                    Event* e = log->getEvent(idx);
                    if(e != nullptr) {
                        arg_value = e->value; // found the target value (DBL_MAX)
                        e->loopId = 1;
                        found = true; 
                        break;
                    }
                }
                
            }
            idx++;
        }
        if(!found){
            std::cout << "______" << std::endl;
            std::cout << "did not find value as target" << std::endl;
            return ECOMPARE;
        }
        found = false;
        std::cout << "______" << std::endl;
        for(Event* e : log->parsed){
            if(e != nullptr && e->value==arg_value && e->loopId!=1){
                std::cout << "first log with value " << arg_value << ": " << std::endl;
                e->print(); 
                std::cout << std::endl;
                found = true;
                resultID = e->lineNum;
                return resultID;
            }
        }
        //if(!found){
            std::cout << "Did not find logs with argument value " << arg_value << std::endl;
        //}
        return ECOMPARE;
    }
    
    return ECOMPARE;
}

int find_divergence(std::string file_path, std::string failureIndicator, std::string newLogIndicator){
    std::vector<Log*> succeeds; 
    std::vector<Log*> fails;
    std::unordered_map<std::string, Log*> threads; // newest log from that thread
    Log* log = nullptr;
    std::ifstream file1(file_path);
    std::cout << "file path: " << file_path << std::endl;
    if (!file1.is_open()) {
        std::cout << "Failed to open logs." << std::endl;
        return ENOOPEN;
    }
    std::string line;
    while(std::getline(file1, line)){
        bool newLog = false; std::string thread = ""; 
        // std::cout << line << std::endl; 
        std::string::size_type temp_id = line.find("Stack Trace");
        if(temp_id != std::string::npos){ continue; } // stack trace, ignore
        temp_id = line.find("BM");
        if(temp_id == std::string::npos){ continue; } // no BM, is stack trace, ignore
        
        line = line.substr(5); // get rid of [BM][
        
        temp_id = line.find("]");
        if(temp_id != std::string::npos){ 
            thread = line.substr(0, temp_id); // thread name
        }
        
        if(threads.find(thread) == threads.end()){ // new thread
            // threads[thread] = num_threads; num_threads++;
            newLog = true;
        }
        
        temp_id = line.find(newLogIndicator);
        if(temp_id != std::string::npos){ // new Log
            newLog = true;
            // if(fail) {num_fails++;}
        }
        
        if(newLog){
            if(log != nullptr){ // push back the previous log
                if(log->fail){
                    fails.push_back(log);
                }else{
                    succeeds.push_back(log);
                }
            }
            
            // std::cout << "new log! " << "fail: " << fail << std::endl;
            log = new Log();
            // log->loopIds = loopIds; 
            // log->loopStartIds = loopStartIds; log->loopIds_count = loopStartIds.size() + 1; log->parentLoop = parentLoop;
            // log->init_contexts(loopStarts);
            threads[thread] = log; // update current log for that thread
        }else{
            // log = threads[thread]; // current log of that thread
        }
        
        if(log==nullptr){
            std::cout << "null" << std::endl;
            continue;
        }
        
        if(line.find(failureIndicator) != std::string::npos){ // failed run
            log->fail = true;
        }

        log->to_parse.push_back(line);
        // std::cout << line << ": thread # " << thread << " fail: " << fail << std::endl;
    }
    if(log != nullptr){ // push back the previous log
        if(log->fail){
            fails.push_back(log);
        }else{
            succeeds.push_back(log);
        }
    }
    // std::cout << "# logs " << logs.size() << std::endl;
    
    if(fails.size()==0){
        std::cout << "did not find log for failure runs" << std::endl;
        return ECOMPARE;
    }
    
    
    std::cout << "# of fails: " << fails.size() << std::endl;
    std::cout << "# of succs: " << succeeds.size() << std::endl;
    file1.close(); 
    
    std::cout << "/////////////////////////" << std::endl;
    
    Trie* fail = new Trie();
    Trie* succeed = new Trie();
    int i = 0;
    for(auto& log : fails){
        log->parseAll();
        fail->insertLog(log, i); i++;
    }
    i = 0;
    for(auto& log : succeeds){
        log->parseAll();
        succeed->insertLog(log, i); i++;
    }
    std::cout << "inserted " << std::endl;
    std::cout << "fail: " << std::endl;
    fail->print_Trie(); std::cout << "/////" << std::endl;
    std::cout << "succeed: " << std::endl;
    succeed->print_Trie(); std::cout << "/////" << std::endl;
    

    TriePrefix result = compareTries(fail, succeed);
    std::cout << "prefix length: " << result.length << std::endl;
    std::cout << "vec (size= " << result.prefix.size() << "): " << std::endl;
    for(int id : result.prefix){
        std::cout << "ID=" << id << " ";
    }
    std::cout << std::endl;
    if(result.div){
        std::cout << "div at " << result.prefix.back() << std::endl;
        return result.prefix.back();
    }
    else{
        std::cout << "no divergence" << std::endl;
        for (auto& child : fail->root->children) {
            std::cout << "continue at " << child.first << std::endl;
            return child.first;
        }
    }
    std::cout << std::endl;
    return ECOMPARE;
}

int find_caller(std::string file_path, std::string failureIndicator, std::string caller_for, std::vector<FuncCall>& rules, int target_line){

    std::cout << "use stack trace" << std::endl;
    std::cout << "failureIndicator " << failureIndicator << std::endl;
    std::string traceStartIndicator = "Start Stack Trace";   // start new log
    std::string traceEndIndicator = "End Stack Trace"; 

    std::ifstream file1(file_path);
    std::cout << "file path: " << file_path << std::endl;
    if (!file1.is_open()) {
        std::cout << "Failed to open logs." << std::endl;
        return ENOOPEN;
    }

    std::string::size_type temp_id;
    
    std::vector<Trace*> failed_traces;
    std::unordered_map<std::string, Trace*> thread_traces;
    Trace* current_trace;
    bool tracing = false;

    std::string line;
    while(std::getline(file1, line)){
        temp_id = line.find(traceStartIndicator);
        if(temp_id != std::string::npos){
            std::string thread = line.substr(temp_id+traceStartIndicator.length()+2);
            temp_id = thread.find("]");
            if(temp_id != std::string::npos){
                thread = thread.substr(0, temp_id);
            }
            current_trace = new Trace(thread); current_trace->fail = false;
            thread_traces[thread] = current_trace;
            tracing = true;
            continue;
        }

        temp_id = line.find(traceEndIndicator);
        if(temp_id != std::string::npos){
            std::string thread = line.substr(temp_id+traceEndIndicator.length()+2);
            temp_id = thread.find("]");
            if(temp_id != std::string::npos){
                thread = thread.substr(0, temp_id);
            }
            tracing = false;
        }

        temp_id = line.find(failureIndicator); // "ID=99"
        if(temp_id != std::string::npos){
            std::string thread = line.substr(5);
            temp_id = thread.find("]");
            if(temp_id != std::string::npos){
                thread = thread.substr(0, temp_id);
            }
            if(thread_traces.find(thread)!=thread_traces.end()){
                if(thread_traces[thread]->fail==false){
                    thread_traces[thread]->fail = true;
                    failed_traces.push_back(thread_traces[thread]);
                }
            }
        }

        if(tracing){
            current_trace->lines.push_back(line);
        }
    }
    std::cout << "# failed: " << failed_traces.size() << std::endl;
    if(failed_traces.size()==0){
        std::cout << "Did not find stack trace of " << failureIndicator << std::endl;
        return ECOMPARE;
    }
    
    // for(int i=0; i<failed_traces.size(); i++){
    //     std::cout << "trace " << i << std::endl ;
    //     failed_traces[i]->print();
    //     std::cout << std::endl;
    // }
    
    // std::vector<FuncCall> matches; std::vector<FuncCall> name_matches;
    std::unordered_set<int> IDs; std::unordered_set<int> name_IDs; int i = 0;
    for(auto& trace : failed_traces){
        std::cout << "trace " << i << std::endl ; i++;
        Caller caller =trace->find_caller(caller_for, target_line);
        if(caller.valid){
            std::cout << "caller of " << caller_for << ": " << std::endl;
            std::cout << caller.function_name << ", line: " << caller.line_number << std::endl;
            for(FuncCall rule : rules){
                if(rule.name == caller.function_name){

		    std::cout << "/// rule: " << rule.name << "; ";
                    std::cout << "rule line: " << rule.line_number << ", caller line: " << caller.line_number << std::endl;


		    if(rule.line_number == caller.line_number){
                        // matches.push_back(rule);
                        IDs.insert(rule.ID);
                    }else{
                        // name_matches.push_back(rule);
                        name_IDs.insert(rule.ID);
                    }
                }
            }
        }else{
            std::cout << "did not find caller of " << caller_for << std::endl;
        }
    }

    std::cout << "IDs: " << std::endl;
    for (auto itr=IDs.begin(); itr != IDs.end(); itr++){
        std::cout << "ID " << *itr << std::endl;
    }
    std::cout << "name_IDs: " << std::endl;
    for (auto itr=name_IDs.begin(); itr != name_IDs.end(); itr++){
        std::cout << "name_ID " << *itr << std::endl;
    }
    std::cout << std::endl;

    // std::cout << "# matches: " << matches.size() << std::endl;
    if (IDs.size()==1){
        return *(IDs.begin());
    }
    else if (IDs.size()>1){
        std::cout << "multilple matches found: " << std::endl;
        for (auto itr=IDs.begin(); itr != IDs.end(); itr++)
        {   
            std::cout << "ID " << *itr << ": " << std::endl;
            for(FuncCall rule : rules){
                if(rule.ID == *itr){
                    std::cout << rule.name << std::endl;
                }
            }
            // std::cout << *itr << std::endl;
        }
        std::cout << "what is the ID to continue? " << std::endl;
        int sel = -1;
        std::cin >> sel;
        return sel;
    }else if (name_IDs.size()==1){
        return  *(name_IDs.begin());
    }else if(name_IDs.size()>1){
        std::cout << "multilple callers found: " << std::endl;
        for (auto itr=name_IDs.begin(); itr != name_IDs.end(); itr++){
            std::cout << *itr <<  std::endl;
        }
        for (auto itr=name_IDs.begin(); itr != name_IDs.end(); itr++){   
            std::cout << "ID " << *itr << ": " << std::endl;
            for(FuncCall rule : rules){
                if(rule.ID == *itr){
                    std::cout << rule.name << std::endl;
                }
            }
            // std::cout << *itr << std::endl;
        }
        std::cout << "what is the ID to continue? " << std::endl;
        int sel = -1;
        std::cin >> sel;
        return sel;
    }
    return ECOMPARE;
}

void FuncCall::print(){
    std::cout << "ID " << ID << ": " << name << ", line " << line_number << std::endl;
}

int find_value(std::string file_path, std::string failureIndicator, int read_ID){
    std::string read_method = "ID=" + std::to_string(read_ID);
    std::cout << "searching for argument value of ID : " << read_method << std::endl;

    std::ifstream file1(file_path);
    std::cout << "file path: " << file_path << std::endl;
    if (!file1.is_open()) {
        std::cout << "Failed to open logs." << std::endl;
        return ENOOPEN;
    }

    bool found = false;
    std::string arg_value = ""; 
    std::string::size_type temp_id;
    // Log* log = new Log(); 
    std::string line; std::vector<std::string> lines;

    while(std::getline(file1, line)){
        std::string::size_type temp_id = line.find("Stack Trace");
        if(temp_id != std::string::npos){ continue; } // stack trace, ignore
        temp_id = line.find("BM");
        if(temp_id == std::string::npos){ continue; } // no BM, is stack trace
        lines.push_back(line);
    }
    file1.close();

    std::cout << "#lines: " << lines.size() << std::endl;
    if(lines.size()==0){
        std::cout << "no log" << std::endl;
        return ECOMPARE;
    }
    int ID=ECOMPARE; std::vector<int> IDs;
    std::unordered_set<std::string> threads_fails;
    std::unordered_map<std::string, int> value_lines; // value to line number

    
    for(int i=lines.size()-1; i>=0; i-=1){
        line = lines[i];
        // std::cout << i << ": " << line << std::endl;

        temp_id = line.find(failureIndicator);
        if(temp_id != std::string::npos){
            line = line.substr(5); // get rid of [BM][
            temp_id = line.find("]");
            if(temp_id != std::string::npos){ 
                std::string thread = line.substr(0, temp_id); // thread name
                threads_fails.insert(thread);
            }
        }

        temp_id = line.find(read_method);
        if(temp_id != std::string::npos){
            line = line.substr(5); // get rid of [BM][
            temp_id = line.find("]");
            if(temp_id != std::string::npos){ 
                std::string thread = line.substr(0, temp_id); // thread name
                if (threads_fails.find(thread) != threads_fails.end()){
                    found = true;
                    temp_id = line.find(","); 
                    if(temp_id != std::string::npos){ 
                        std::string value = line.substr(temp_id+1);
                        threads_fails.erase(thread);
                        value_lines.insert({value, i});
                        std::cout << "add target value " << value << std::endl;
                    }
                }
            }
            continue;
        }

        temp_id = line.find(","); 
        if(temp_id != std::string::npos){ 
            std::string value = line.substr(temp_id+1);
            if(value_lines.find(value)!=value_lines.end()){
                std::cout << "target value found: " << value << std::endl;
                line = line.substr(0, temp_id);
                temp_id = line.find("ID="); 
                if(temp_id != std::string::npos){ 
                    std::string id_str = line.substr(temp_id+3);
                    ID = std::stoi(id_str); IDs.push_back(ID);
                    std::cout << "ID=" << ID << ", " << value << std::endl;
                }
            }
        }
    }

    if(!found){
        std::cout << "______" << std::endl;
        std::cout << "did not find value as target" << std::endl;
        return ECOMPARE;
    }

    if(ID==ECOMPARE){
        std::cout << "did not find target value" << std::endl;
    }
    std::cout << "ID selected: " << ID << std::endl;
    return ID;
}
