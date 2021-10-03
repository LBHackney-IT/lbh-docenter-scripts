#!/bin/bash

function methodBlock {
    local methodNamePattern=$1
    
    if [ -z "$methodNamePattern" ]
    then
        methodNamePattern='\w+'
    fi

    echo "(?:(?:public|static|private) )+\S+\?? $methodNamePattern\((?:[^\(\)]+)?\)(\s+)\{[\s\S]+?\1\}"
}


methodSignature='(?:(?:public|static|private) )+\S+\?? \w+\((?:[^\(\)]+)?\)'

function fileMethodNamesPattern {
    local fileName=$1
    grep -oP "$methodSignature" $fileName | \
    grep -oP '\w+(?=\s*\((?:[^\(\)]+)?\))' | \
    tr '\n' '|' | \
    sed -E 's/\|$//g;s/(.+)/\(\?:\1\)/'
}

# Might be overkill, but it's best to make sure
# That the calls are to the local scope functions
function fileMethodCallsWithinMethodPattern {
    local fileName=$1
    echo "(?<!public)(?<!static)(?<!private) \S+\?? \K$(fileMethodNamesPattern $fileName)(?=\((?:[^\(\)]+)?\))"
}

function getFileScopeMethodCallsWithinMethod {
    local methodName=$1
    local filePath=$2
    pcregrep -oM "$(methodBlock $methodName)" $filePath | \
    grep -oP "$(fileMethodCallsWithinMethodPattern $filePath)" 
}


echo "Start!"

dependencyVariablePattern='private(?: readonly)? \K\w+ \K\w+(?=;)'

function scanAndFollowDependencies {
    # If not controller, then use 2nd var 
    local scannedFile=$1
    echo $scannedFile
    local dependencyVariablesSearchPattern=$(grep -oP -e "$dependencyVariablePattern" $scannedFile | \
        tr '\n' '|' | sed -E 's/\|$//g' )
    

    # local by default
    eval "declare -A dependencyTypeLookup=($(\
        grep -oP "private(?: readonly)? \K\w+ \w+" $scannedFile | \
        sed -E 's/(\w+)\s(\w+)/\[\2\]=\1/g' | \
        tr '\n' ' '))"
    
    
    for x in "${!dependencyTypeLookup[@]}"; do printf "[%s]=%s\n" "$x" "${dependencyTypeLookup[$x]}" ; done


    (grep -wq ": Controller" $scannedFile)
    local isController=$?
    
    if [[ $isController -ne 1 ]]; then
        pcregrep -oM '(?:\[[^\[\]]+\]\s+)+public \S+ \w+\b(?! : Controller\n)' $scannedFile | \
        perl -0777 -pe 's/(?:(?:\[Http(\w+)\]|\[Route\(\"([^\"]+)\"\)\]|(?:\[[^\[\]]+\]))\s+)+public \S+ (\w+)/<R: \2\; T: \1\; N: \3\;>/gm' | \
        grep -oP '<[^<>]+>' | while read endpointInfo ; do {
            echo $endpointInfo
        } ; done
    else
        echo UC
    fi
}

scanAndFollowDependencies ./test/controller.txt

