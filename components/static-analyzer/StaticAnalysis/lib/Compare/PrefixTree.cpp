#include "PrefixTree.hpp"

bool TrieNode::operator== (const TrieNode& rhs) const{
    return (lineNum == rhs.lineNum);
}
bool TrieNode::operator!= (const TrieNode& rhs) const{
    return !(this->operator==(rhs));
}
    
Trie::Trie(){
    root = nullptr;
    // std::unordered_map<int, TrieNode*> temp; loopStartNodes  = temp;
}
Trie::Trie(std::string name) : entry(name){
    root = nullptr;
    // std::unordered_map<int, TrieNode*> temp; loopStartNodes  = temp;
}
Trie::~Trie(){
}
void Trie::print_Trie(){
    if(root==nullptr){
        std::cout << "root is null" << std::endl;
        return;
    }
    print_subTrie(root);
}
void Trie::print_subTrie(TrieNode* node){
    if(node==nullptr){
        return;
    }
    std::cout << node->lineNum << "; children: ";
    for (auto& child : node->children) {
        std::cout << child.first << " ";
    }
    std::cout << std::endl;
    for (auto& child : node->children) {
        print_subTrie(child.second);
    }
}
bool Trie::insertLog(Log* log, int idx) {
    // std::cout << "HERE" << std::endl;
    if(log==nullptr || log->parsed.size()==0 || log->parsed[0]==nullptr){
        return false;
    }
    if(root==nullptr){
        root = new TrieNode(log->parsed[0]->lineNum);
        entry = log->entry;
        // std::cout << "entry: " << entry << std::endl;
    }
    
    loopStartIds.insert(log->loopStartIds.begin(), log->loopStartIds.end());
    parentLoop.insert(log->parentLoop.begin(), log->parentLoop.end());
    std::multimap<int, TrieNode*> loopTails;

    TrieNode *current = root; // parent of the node being added
    if(current==nullptr){
        std::cout << "null root" << std::endl;
    }
    
    int looping = -1;

    //std::cout << "THERE" << std::endl;
    for (int i = 1; i < log->parsed.size(); i++) {
        // std::cout << std::endl << "start " << i << std::endl;
        int lineNum = -1; int loopId = -1;
        Event* e = log->getEvent(i);
        if(e==nullptr){
            std::cout << "null Event in log, idx: " << i << std::endl;
            current->isEndOfLog = true;
            return false;
        }else{
            lineNum = e->lineNum; loopId = e->loopId;
        }
        
        if(current==nullptr){
            std::cout << "current is null" << std::endl;
        }
        // std::cout << std::endl << i << " current: " << current->lineNum << " \"lineNum\": " << lineNum << std::endl;
        // print_Trie();

        bool start_loop = (loopId>-1 && loopStartIds.find(lineNum)!=loopStartIds.end()); // node being added is start of loop
        bool new_node = (current->children.find(lineNum) == current->children.end());
        
        TrieNode* next = nullptr;

        if(start_loop){
            // std::cout << "start_loop: " << loopId << std::endl;
            looping = loopId;
            if(new_node){
                if(loopStartNodes.find(loopId)==loopStartNodes.end()){ // first loop start added to Trie
                    // std::cout << "loop start added: " << lineNum << " loopId: " << loopId << std::endl;
                    next = new TrieNode(lineNum); next->loopId = loopId;
                    current->children[lineNum] = next; // current is node before the Trie
                    loopStartNodes[loopId] = next; 

                }else{ // start node already added to Trie
                    if(current->loopId == loopId){ // this should be true
                        loopTails.insert({loopId, current});
                        // std::cout << "Tail added: " << current->lineNum << " loopId: " << loopId << std::endl;
                    }else{
                        std::cout << "start added but not same loop " << lineNum << " loopId: " << loopId << std::endl;
                    }
                    next = loopStartNodes[loopId];
                }
            }
            else{ // not new Node
                // std::cout << "start & not new; " << lineNum << " loopId: " << loopId << std::endl;
                
                next = loopStartNodes[loopId];
            }
        }
        else{ // not start of index
            if(new_node){
                next = new TrieNode(lineNum); next->loopId = loopId;
                current->children[lineNum] = next;
            }else{
                next = current->children[lineNum];
            }
            
            if(loopId!=looping){ // loop Id of next != current but is not start of loop
                auto bound = loopTails.upper_bound(looping);
                for(auto it=loopTails.lower_bound(looping); it!=bound; it++){
                    it->second->children[lineNum] = next;
                }
                looping = loopId;
            }
        }
        
        current = next;
    }

    if(current->children.size()==0){
        current->isEndOfLog = true;
    }
    current->endLogIdx = idx;
    return true;
}
//typedef struct return_prefix {
//    Log* failed;
//    bool div;
//    int length;
//    std::vector<Event> prefix;
//} Prefix;

TriePrefix compareTries(Trie* fail, Trie* succeed){
    TriePrefix current = TriePrefix(); 
    if(fail==nullptr || succeed==nullptr || fail->entry!=succeed->entry){
        return current; 
    }
    std::queue<TriePair> q;
    q.push({fail->root, succeed->root, 1});
    // int length = 0; // current longest 
    // // std::vector<int> current; // lineNums
    while(!q.empty()){
        TriePair node = q.front();
        q.pop();
        if(node.eventA==nullptr || node.eventB==nullptr){
            continue;
        }
        if (*(node.eventA) == *(node.eventB)) {
            if (node.depth > current.length) {
                current.length = node.depth;
                current.prefix.push_back(node.eventA->lineNum);
                if(node.eventA->isEndOfLog && node.eventB->isEndOfLog){
                    current.div = false;     
                }else{
                    current.div = true;
                }
            }

            for (auto& childA : node.eventA->children) {
                for (auto& childB : node.eventB->children) {
                    if (childA.first == childB.first) {
                        q.push({childA.second, childB.second, node.depth+1});
                    }
                }
            } // enque
        }
    }
    return current;
}
