#!/bin/bash


# Should also probs look for Npgsql import - it might be smth else like MySQL
function isPostgreContextFile {
    local filePath=$1
    grep -woPq '(?<=public class )\w+(?= \: DbContext)' "$filePath"

    [[ $? -eq 0 ]] && echo 0 || echo 1
}

function getPostgreContextName {
    local filePath=$1
    grep -woP '(?<=public class )\w+(?= \: DbContext)' "$filePath"
}

# Could also search "IMongoDatabase", which is part of Mongo Driver I assume.
function isMongoContextFile {
    local filePath=$1

    grep -woPq 'public class [^I\s]\w+(?= : \w+)' "$filePath"
    local isNotInterface=$?
    
    grep -woPq 'public IMongoCollection<BsonDocument> \w+ { get\; set\; }' "$filePath"
    local containsMongoCollection=$?

    [[ $isNotInterface -eq 0 && $containsMongoCollection -eq 0 ]] && echo 0 || echo 1
}

function getMongoContextName {
    local filePath=$1
    grep -woP '(?<=public class )\w+(?= : \w+)' "$filePath"
}

# If the name is empty, consider error?
# It shouldn't be possible.
function determineDBContextName {
    local filePath=$1

    [[ $(isPostgreContextFile $filePath) -eq 0 ]] && getPostgreContextName $filePath && return 0
    [[ $(isMongoContextFile $filePath) -eq 0 ]] && getMongoContextName $filePath && return 0
    # TODO: Add DynamoDB indentifier (if possible)
}

function determineDBContextType {
    local filePath=$1

    [[ $(isPostgreContextFile $filePath) -eq 0 ]] && echo 'PostgreSQL' && return 0
    [[ $(isMongoContextFile $filePath) -eq 0 ]] && echo 'MongoDB' && return 0
    # TODO: Add DynamoDB indentifier (if possible)
}

function methodBlock {
    local methodNamePattern=$1
    
    if [ -z "$methodNamePattern" ]
    then
        methodNamePattern='\w+'
    fi

    echo "\n\s+(?>(?:public|static|private) )+\S+\?? $methodNamePattern\([^\(\)]*\)(\s+)\{[\s\S]+?\1\}"
}

methodSignature='\n\s+(?>(?:public|static|private) )+\S+\?? \w+\([^\(\)]*\)'

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
    echo "(?<![\w>] )$(fileMethodNamesPattern $fileName)(?=\((?:[^\(\)]+)?\))"
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
    local scannedFile=$1
    local accumulator=$2
    echo -e "\nAcc: $accumulator"

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
            endpointName=$( echo $endpointInfo | grep -oP '(?<=Name: )\w+' )
            pcregrep -M "(?:\[[^\[\]]+\]\s+)+public \S+ $endpointName\b(?! : Controller\n)$methodBlock" $scannedFile | \
            grep -oP "(?>(?:$dependencyVariablesSearchPattern)\.\w+)(?!\.)" | while read dependencyCall ; do {
                dependencyMethod=$(echo "$dependencyCall" | grep -oP '\.\K\w+')
                
                #--------------------------Test--------------------
                if [[ $dependencyMethod == "ExecutePost" ]]
                then
                    local newAcc=$(append_to_endpoint_info "$endpointInfo" "$dependencyMethod")
                    
                dependencyVarName=$(echo "$dependencyCall" | grep -oP '\w+(?=\.)')
                    dependencyFileName=$(find_files_by_dependency_type ${dependencyTypeLookup[$dependencyVarName]} ./test/)
                    scanAndFollowDependencies "$dependencyFileName" "$newAcc"
                else
                    echo "Skip"
                fi
                #------------------------End-Test--------------------

            } ; done
        } ; done
    else
        local calledMethod=$(echo $accumulator | grep -oP '(?<= )\w+(?=!\>)')

        # methodSignature --> problem I don't have $usecaseMethod in this context!!!!!!!! Need an extra var in the function
        # Make "methodSignature" into a functino that accepts a name

        local calledMethodBlock=$(pcregrep -M "$(methodBlock $calledMethod)" $scannedFile)

        if [ -z "$calledMethodBlock" ]
        then
            determineDBContextType $scannedFile
            determineDBContextName $scannedFile
            # If the values are non-empty, the send them, else return 1 & end execution branch
        else
            echo "$calledMethodBlock" | \
            grep -oP "(?>(?:$dependencyVariablesSearchPattern)\.\w+)(?!\.)" | while read dependencyCall ; do {
                dependencyMethod=$(echo "$dependencyCall" | grep -oP '\.\K\w+')
                dependencyVarName=$(echo "$dependencyCall" | grep -oP '\w+(?=\.)')

                    dependencyFileName=$(find_files_by_dependency_type ${dependencyTypeLookup[$dependencyVarName]} ./test/)
                # TODO: add validation to check it not being empty
                scanAndFollowDependencies "$dependencyFileName" "$(append_to_endpoint_info "$accumulator" "$dependencyMethod")"
            } ; done
        fi        
    fi
}

scanAndFollowDependencies ./test/controller.txt

# isPostgreContextFile ./test/databaseContextPostgre.txt

#mongoContext

