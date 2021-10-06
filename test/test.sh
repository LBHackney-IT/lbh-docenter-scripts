#!/bin/bash

function methodBlock {
    local methodNamePattern=$1
    
    if [ -z "$methodNamePattern" ]
    then
        methodNamePattern='\w+'
    fi

    echo "\n\s+(?>(?:public|static|private) )+\S+\?? $methodNamePattern\([^\(\)]*\)(\s+)\{[\s\S]+?\1\}"
}


methodSignature='(?:(?:public|static|private) )+\S+\?? \w+\((?:[^\(\)]+)?\)'

function fileMethodNamesPattern {
    local fileName=$1
    pcregrep -M "$methodSignature" $fileName | \
    grep -oP '\w+(?=\s*\([^\(\)]*\))' | \
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
    pcregrep -M "$(methodBlock $methodName)" $filePath | \
    grep -oP "$(fileMethodCallsWithinMethodPattern $filePath)" 
}


echo "Start!"

dependencyVariablePattern='private(?: readonly)? \K\w+ \K\w+(?=;)'

function append_to_endpoint_info {
    local oldEndpointInfo=$1
    local methodName=$2
    echo $oldEndpointInfo | perl -pe "s/(?<=CallChain: )([\w ,]+)(?=!)/\1, $methodName/g"
}

function get_controller_route {
    local controllerFilePath=$1
    pcregrep -oM '\[Route\(\"[^"]+\"\)\][\S\s]+public class \w+ : Controller' $controllerFilePath |
    grep -oP '\[Route\(\"\K[^"]+(?=\"\)\])'
}

function find_files_using_interface {
    local interface=$1
    # apiProjectDirectory
    local startDirectory=$2

    [ -z "$interface" ] && { echo "Interface is empty!"; exit 1; }

    grep -rlwE $startDirectory -e "public class \w+ : $interface"
}

function find_files_using_class {
    local class=$1
    local startDirectory=$2
    # Not convinced on the value of exit codes yet
    grep -rlwE $startDirectory -e "public class $class : \w+"
}

# There should be only one file that contains the dependency method
# from the call
function find_files_by_dependency_type {
    local dataType=$1
    local startDirectory=$2
    local dependencyFile=$(find_files_using_interface $dataType $startDirectory)
    if [ -z "$dependencyFile" ]
    then
        dependencyFile=$(find_files_using_class $dataType $startDirectory)
    fi
    echo $dependencyFile
}

endpointMetadata='(?:\[[^\[\]]+\]\s+)+public \S+ \w+\b(?! : Controller\n)'
methodBlock='\([^\(\)]*\)(\s+)\{[\s\S]+?\1\}'
methodSig='\s+(?:(?:public|static|private) )+\S+\?? \w+'

function scanAndFollowDependencies {
    # If not controller, then use 2nd var 
    local scannedFile=$1
    # Only present when its not a root of the call chain
    local accumulator=$2
    # echo $scannedFile

    if [ -z "$scannedFile" ]
    then
        # temporary silly resolution for the base case
        # TODO: implement some accumulator? And then compact its data
        # could be  <R: /v1/*; T: Get; N: GetWorkerById; CallChain: UCMethod1, UCMethod2, GWMethod1, DBContext1; DBContext2>
        # Could maybe even include the DBContext collection name or smth.
        # Call chain could become useful later down the line
        echo "Base Case!"
        exit 0
    fi

    local dependencyVariablesSearchPattern=$(grep -oP -e "$dependencyVariablePattern" $scannedFile | \
        tr '\n' '|' | sed -E 's/\|$//g' )
    

    # local by default
    eval "declare -A dependencyTypeLookup=($(\
        grep -oP "private(?: readonly)? \K\w+ \w+(?=\;)" $scannedFile | \
        sed -E 's/(\w+)\s(\w+)/\[\2\]=\1/g' | \
        tr '\n' ' '))"
    
    
    # for x in "${!dependencyTypeLookup[@]}"; do printf "[%s]=%s\n" "$x" "${dependencyTypeLookup[$x]}" ; done


    (grep -wq ": Controller" $scannedFile)
    local isController=$?
    
    # You can instead just set variables for patterns within this block, rather than do all this heavy logic
    if [[ $isController -ne 1 ]]; then
        local controllerRoute=$(get_controller_route $scannedFile | sed -E 's/\//\\\//g')

        pcregrep -M "$endpointMetadata" $scannedFile | \
        perl -0777 -pe "s/(?:(?:\[Http(\w+)\]|\[Route\(\"([^\"]+)\"\)\]|(?:\[[^\[\]]+\]))\s+)+public \S+ (\w+)/<Route: $controllerRoute\/\2! Type: \1! Name: \3! CallChain: \3!>/gm; s/R: .+?\K\/\/(?=[^!]+!)/\//gm" | \
        grep -oP '<[^<>]+>' | \
        while read endpointInfo ; do {
            # echo -e "\n$endpointInfo"
            endpointName=$( echo $endpointInfo | grep -oP '(?<=Name: )\w+' )
            # echo $endpointName

            pcregrep -M "(?:\[[^\[\]]+\]\s+)+public \S+ $endpointName\b(?! : Controller\n)$methodBlock" $scannedFile | \
            grep -oP "(?>(?:$dependencyVariablesSearchPattern)\.\w+)(?!\.)" | while read dependencyCall ; do {
                # echo $dependencyCall
                dependencyMethod=$(echo "$dependencyCall" | grep -oP '\.\K\w+')
                
                #--------------------------Test--------------------
                if [[ $dependencyMethod == "ExecutePost" ]]
                then
                dependencyVarName=$(echo "$dependencyCall" | grep -oP '\w+(?=\.)')

                # uc implementing interface, HARDCODED start directory
                    dependencyFileName=$(find_files_by_dependency_type ${dependencyTypeLookup[$dependencyVarName]} ./test/)

                    local newAcc=$(append_to_endpoint_info "$endpointInfo" "$dependencyMethod")

                    scanAndFollowDependencies "$dependencyFileName" "$newAcc"
                else
                    echo "Skip"
                fi
                #------------------------End-Test--------------------

            } ; done
        } ; done
    else
        # apply inner file calls
        echo UC GW, etc.
        local calledMethod=$(echo $accumulator | grep -oP '(?<= )\w+(?=!\>)')

        # methodSignature --> problem I don't have $usecaseMethod in this context!!!!!!!! Need an extra var in the function
        # Make "methodSignature" into a functino that accepts a name
            grep -oP "(?>(?:$dependencyVariablesSearchPattern)\.\w+)(?!\.)" | while read dependencyCall ; do {
                # I don't think I'll use the method
                dependencyMethod=$(echo "$dependencyCall" | grep -oP '\.\K\w+')
                dependencyVarName=$(echo "$dependencyCall" | grep -oP '\w+(?=\.)')

                    dependencyFileName=$(find_files_by_dependency_type ${dependencyTypeLookup[$dependencyVarName]} ./test/)
                # TODO: add validation to check it not being empty
                scanAndFollowDependencies "$dependencyFileName" "$(append_to_endpoint_info "$accumulator" "$dependencyMethod")"
            } ; done

    fi
}
scanAndFollowDependencies ./test/controller.txt

scanAndFollowDependencies ./test/controller1.txt

scanAndFollowDependencies ./test/controller.txt

