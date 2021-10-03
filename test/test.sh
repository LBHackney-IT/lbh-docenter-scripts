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

function get_controller_route {
    local controllerFilePath=$1
    pcregrep -oM '\[Route\(\"[^"]+\"\)\][\S\s]+public class \w+ : Controller' $controllerFilePath |
    grep -oP '\[Route\(\"\K[^"]+(?=\"\)\])'
}


endpointMetadata='(?:\[[^\[\]]+\]\s+)+public \S+ \w+\b(?! : Controller\n)'
methodBlock='\([^\(\)]*\)(\s+)\{[\s\S]+?\1\}'
methodSig='\s+(?:(?:public|static|private) )+\S+\?? \w+'

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
        local controllerRoute=$(get_controller_route $scannedFile | sed -E 's/\//\\\//g')

        pcregrep -M "$endpointMetadata" $scannedFile | \
        perl -0777 -pe "s/(?:(?:\[Http(\w+)\]|\[Route\(\"([^\"]+)\"\)\]|(?:\[[^\[\]]+\]))\s+)+public \S+ (\w+)/<R: $controllerRoute\/\2\; T: \1\; N: \3\;>/gm; s/R: .+?\K\/\/(?=[^\;]+\;)/\//gm" | \
        grep -oP '<[^<>]+>' | \
        while read endpointInfo ; do {
            echo -e "\n$endpointInfo"
            endpointName=$( echo $endpointInfo | grep -oP '(?<=N: )\w+' )
            echo $endpointName

            pcregrep -M "(?:\[[^\[\]]+\]\s+)+public \S+ $endpointName\b(?! : Controller\n)$methodBlock" $scannedFile | \
            grep -oP "(?:$dependencyVariablesSearchPattern)\.\w+" | while read dependencyCall ; do {
                echo $dependencyCall
            } ; done
        } ; done
    else
        echo UC
    fi
}

scanAndFollowDependencies ./test/controller1.txt

scanAndFollowDependencies ./test/controller.txt

