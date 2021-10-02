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
