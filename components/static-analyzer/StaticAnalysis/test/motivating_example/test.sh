# This is an ad-hoc testing script for testing motivating example only
# Please refine the infrastructure if more test case are involved

#!/bin/bash

show_spinner() {
    local pid=$1 # Process ID of the command we are waiting for
    local spin='|/-\' # Characters for the spinner animation
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\rRunning CLODS Static Analyzer ${spin:$i:1} "
        sleep 0.1
    done
    printf "\rDone         \n"
}


# ANSI color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Welcome to CLODS's testing infrastructure${NC}"

script_dir="$(cd "$(dirname "$0")" && pwd)"

cd $script_dir

echo "The current directory is: $(pwd)"

cp ../../CLODS.conf CLODS.conf.old
cp ../../jumpTable.conf jumpTable.conf.old

cp CLODS.conf ../../
cp jumpTable.conf ../../

cd ../../build

echo -e "${GREEN}Building CLODS${NC}"
make -j
./static-analysis < $script_dir/input.txt &> $script_dir/output.txt &
show_spinner $!

echo ""

if diff "$script_dir/output.txt" "$script_dir/output_ref.txt" > /dev/null; then
    echo -e "${GREEN}Test passed: The files match.${NC}"
else
   echo -e "${RED}Test failed: The files do not match.${NC}"
fi

cd "$script_dir" || exit 1

cp CLODS.conf.old ../../CLODS.conf 
cp jumpTable.conf.old ../../jumpTable.conf 

rm CLODS.conf.old
rm jumpTable.conf.old


