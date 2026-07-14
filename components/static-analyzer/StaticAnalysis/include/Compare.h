#ifndef COMPARE_H
#define COMPARE_H

#define ENODIV -1
#define ENOOPEN -2
#define ECOMPARE -3

class FuncCall{
    public:
    std::string name;
    int ID;
    int line_number;
    FuncCall(){
        ID = -1;
        line_number = -1;
    }
    void print();
};

int compare (int argc, char *argv[]);
int find_divergence(std::string file_path, std::string failureIndicator, std::string newLogIndicator);
int find_caller(std::string file_path, std::string failureIndicator, std::string caller_for, std::vector<FuncCall>& rules, int target_line);
int find_value(std::string file_path, std::string failureIndicator, int read_ID);

#endif /* COMPARE_H */
