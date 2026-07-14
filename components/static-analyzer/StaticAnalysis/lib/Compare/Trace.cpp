#include "Trace.hpp"
     // Copy constructor
Trace::Trace(std::string name) : thread(name) {
    fail = false;
}
Trace::~Trace() {
    lines.clear(); lines.resize(0);
}
void Trace::print(){
    std::cout << "thread " << thread << "stack trace: " << std::endl;
    for(std::string l : lines){
        std::cout << l << std::endl;
    }
}

Caller Trace::find_caller(std::string function_name, int target_line){
    std::string::size_type temp_id;
    Caller result;
    int i = 0; int index = 0; bool found = false;
    for(i=0; i<lines.size(); i++){
        temp_id = lines[i].find(function_name);
        if(temp_id != std::string::npos){
            // std::cout << "i: " << i << std::endl;
            if(!found){
                index = i; found = true;
            }else{
                std::string line = lines[i]; temp_id = line.find(":"); 
                std::cout << "line: " << line << std::endl;
                if (temp_id != std::string::npos) {
                    line = line.substr(temp_id+1);
                }
                temp_id = line.find(")");
                if (temp_id != std::string::npos) {
                    line = line.substr(0,temp_id);
                }
                std::stringstream ss(line);
                int lineNum = -1; ss >> lineNum;

                std::cout << "lineNum " << lineNum << std::endl;
                if(lineNum == target_line){
                    index = i;
                }
            }
        }
    }
    for(i=index+1; i<lines.size(); i++){
        std::string line = lines[i];
        temp_id = line.find("(");
        if(temp_id == std::string::npos){
            continue;
        }else{
	    // std::cout << "HERE: " << line << std::endl;
            std::string name = line.substr(0, temp_id);
            std::string call = line.substr(temp_id+1);
            temp_id = name.rfind(".");
            if (temp_id != std::string::npos && temp_id != name.length()-1) {
                name = name.substr(temp_id + 1);
            }
            result.function_name = name;

            temp_id = call.find(":");
            if (temp_id != std::string::npos) {
                call = call.substr(temp_id+1);
            }
            temp_id = call.find(")");
            if (temp_id != std::string::npos) {
                call = call.substr(0,temp_id);
            }
            std::stringstream ss(call);
            int lineNum = -1; ss >> lineNum;
            result.line_number = lineNum;
            result.valid = true;
	    std::cout << "name: " << name << ", line: " << lineNum << std::endl;
            return result;
        }
    }
    return result;
}

std::string compare_trace(Trace* t1, Trace* t2){
    int size1 = t1->lines.size();
    int size2 = t2->lines.size();
    int i=0;
    if(size1==0 || size2==0){
        return "";
    }
    for(; i<size1&&i<size2; i++){
        if(t1->lines[i] != t2->lines[i]){
            break;
        }
    }
    if(i>0){
        return t1->lines[i-1];
    }
    else{
        return t1->lines[0];
    }
}

