#!/bin/bash

echo "Start!"

projectDirectory='./social-care-case-viewer-api/'
# No need to search the project root or tests project
apiProjectDirectory=$( find $projectDirectory -mindepth 1 -type d -iname '*Api' )

function find_files_using_interface {
    local interface=$1
    local startDirectory=$2
    # [ -z "$interface" ] && { echo "Interface is empty!"; return 1; }
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

# Creating a partially applied function (like in Haskell)
function find_dependency_file_name_in_api_directory {
    local dataType=$1
    find_files_by_dependency_type "$dataType" "$apiProjectDirectory"
}

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

    echo "\n\s+(?>(?:public|static|private) )+(?:async )?\S+\?? $methodNamePattern\([^\(\)]*\)(\s+)\{[\s\S]+?\1\}"
}

methodSignature='\n\s+(?>(?:public|static|private) )+(?:async )?\S+\?? \w+\([^\(\)]*\)'

function fileMethodNamesPattern {
    local fileName=$1
    pcregrep -M "$methodSignature" $fileName | \
    grep -oP '\b\w+(?=\s*\([^\(\)]*\))(?![^[]+\])' | \
    tr '\n' '|' | \
    sed -E 's/\|$//g;s/(.+)/\(\?:\1\)/'
}

# Might be overkill, but it's best to make sure
# That the calls are to the local scope functions
# This has a weakness of that the following pattern won't match:
# LegitMethodNameThatWontMatch(StaticClass.AnyMethod())
# It won't match, because we have braces within braces. The "AnyMethod" will
# match instead of the desired one... need some OR magic to resolve this.
# It's low priority right now bcz it's a super rare case.
function fileMethodCallsWithinMethodPattern {
    local fileName=$1
    echo "(?<![\w>?] )\b$(fileMethodNamesPattern $fileName)(?=\((?:[^\(\)]+)?\))"
}

function getFileScopeMethodCallsWithinMethod {
    local methodName=$1
    local filePath=$2
    pcregrep -M "$(methodBlock $methodName)" $filePath | \
    grep -oP "$(fileMethodCallsWithinMethodPattern $filePath)" 
}

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

endpointMetadata='(?:\[[^\[\]]+\]\s+)+public (?:async )?\S+ \w+\b(?! : Controller\n)'
# block='(\s+)\{[\s\S]+?\1\}'
methodBlock='\([^\(\)]*\)(\s+)\{[\s\S]+?\1\}'
# methodSig='\n\s+(?>(?:public|static|private) )+\S+\?? \w+'

function scanAndFollowDependencies {
    local scannedFile=$1
    local accumulator=$2

    if [ -z "$scannedFile" ]
    then
        # temporary silly resolution for the base problem case like validator, etc.
        echo "Dead End Case!"
        return 1
    fi

    local dependencyVariablesSearchPattern=$(grep -oP -e "$dependencyVariablePattern" $scannedFile | \
        tr '\n' '|' | sed -E 's/\|$//g' )
    
    eval "declare -A dependencyTypeLookup=($(\
        grep -oP "private(?: readonly)? \K\w+ \w+(?=\;)" $scannedFile | \
        sed -E 's/(\w+)\s(\w+)/\[\2\]=\1/g' | \
        tr '\n' ' '))"


    local dependencyCount=${#dependencyTypeLookup[@]}

    (grep -wq ": Controller" $scannedFile)
    local isController=$?
    
    if [[ $isController -ne 1 ]]; then
        local targetMethod=$( echo $accumulator | grep -oP '(?<=Name: )\w+' )
        local targetMethodBlock=$(pcregrep -M "$(methodBlock $targetMethod)" $scannedFile)
    else
        local targetMethod=$(echo $accumulator | grep -oP '(?<= )\w+(?=!\>)')
        local targetMethodBlock=$(pcregrep -M "$(methodBlock $targetMethod)" $scannedFile)
    fi

    if [[ -z "$targetMethodBlock" || $dependencyCount -eq 0 ]]
    then
        local dbType=$(determineDBContextType $scannedFile)
        local dbName=$(determineDBContextName $scannedFile)

        [[ -z "$dbType" && -z "$dbName" ]] && return 1

        # TODO: Extract this into a function
        local eName=$(echo "$accumulator" | grep -oP '(?<=Name: )\w+(?=\!)')
        local eRoute=$(echo "$accumulator" | grep -oP '(?<=Route: ).+?(?=\!)')
        local eType=$(echo "$accumulator" | grep -oP '(?<=Type: )\w+(?=\!)')
        echo "<DbName: $dbName! DbType: $dbType! Name: $eName! Type: $eType! Route: $eRoute!>"
    else
        getFileScopeMethodCallsWithinMethod $targetMethod $scannedFile | while read localCall ; do {
            scanAndFollowDependencies "$scannedFile" "$(append_to_endpoint_info "$accumulator" "$localCall")"
        } ; done

        echo "$targetMethodBlock" | \
        grep -oP "(?>(?:$dependencyVariablesSearchPattern)\.\w+)" | while read dependencyCall ; do {                
            # There should also be a part that determines the type of the input & output objects, but that skyrockets the complexity of
            # the script & hence should be done as separate PR. Luckily this is only important for dis-ambiguing the C# method overloads,
            # which tend to get used quite rarely, so it doesn't affect the accuracy of the output too much.
            dependencyMethod=$(echo "$dependencyCall" | grep -oP '\.\K\w+')    
            dependencyVarName=$(echo "$dependencyCall" | grep -oP '\w+(?=\.)')
            dependencyFileName=$(find_dependency_file_name_in_api_directory "${dependencyTypeLookup[$dependencyVarName]}")
            scanAndFollowDependencies "$dependencyFileName" "$(append_to_endpoint_info "$accumulator" "$dependencyMethod")"
        } ; done
    fi
}

controllersList=$(find "$apiProjectDirectory/V1/Controllers" -mindepth 1)

# Need to also search "IMongoDatabase", which is part of Mongo Driver I assume.
# Seems, there are a couple ways of implementing the MongoDB
for controllerFile in $controllersList
do
    controllerRoute=$(get_controller_route "$controllerFile" | sed -E 's/\//\\\//g')
    pcregrep -M "$endpointMetadata" $controllerFile | \
    perl -0777 -pe "s/(?:(?:\[Http(\w+)\]|\[Route\(\"([^\"]+)\"\)\]|(?:\[[^\[\]]+\]))\s+)+public (?:async )?\S+ (\w+)/<Route: $controllerRoute\/\2! Type: \1! Name: \3! CallChain: \3!>/gm; s/R: .+?\K\/\/(?=[^!]+!)/\//gm" | \
    grep -oP '<[^<>]+>' | while read endpointInfo ; do {
        scanAndFollowDependencies "$controllerFile" "$endpointInfo"
    } ; done
done | sort -u | {
    IFS=''; read -r -d '' executionTreeOutput; IFS='\n';
    databases=$(echo -e "$executionTreeOutput" | grep -oP '<DbName: \w+! DbType: \w+!' | sort -u)
    jsonDbDepObj=$(echo -e "$databases" | while read database ; do {
        dbTechName=$(echo "$database" | grep -oP '(?<=DbName: )\w+(?=!)')
        dbType=$(echo "$database" | grep -oP '(?<=DbType: )\w+(?=!)')
        jsonEndpointsList=$(echo -e "$executionTreeOutput" | grep -P "^$database" | perl -pe 's/<.+?! Name: (\w+)! Type: (\w+)! Route: ([^!]+)!>/\{"name":"\1"\,"httpMethod":"\2","path":"\3"}/gm' | tr '\n' ',' | sed -E 's/,$//')
        echo -e "{\"technicalName\":\"$dbTechName\",\"type\":\"$dbType\",\"endpointsUsingIt\":[$jsonEndpointsList]}"
    } ; done | tr '\n' ',' | sed -E 's/,$//')
    
    dependenciesObject="{\"databases\":[$jsonDbDepObj]}"
}

# You can do the grouping by making a db combination a capture group & the find all the results with that capture group




#---------------------------------------------------TEST----------------------------------------------------------------------------

# file="./social-care-case-viewer-api/SocialCareCaseViewerApi/V1/Controllers/CaseController.cs"
# controllerRoute=$(get_controller_route "$file" | sed -E 's/\//\\\//g')

# # echo "R: $controllerRoute"
# pcregrep -M "$endpointMetadata" $file | \
# perl -0777 -pe "s/(?:(?:\[Http(\w+)\]|\[Route\(\"([^\"]+)\"\)\]|(?:\[[^\[\]]+\]))\s+)+public (?:async )?\S+ (\w+)/<Route: $controllerRoute\/\2! Type: \1! Name: \3! CallChain: \3!>/gm; s/R: .+?\K\/\/(?=[^!]+!)/\//gm" | \
# grep -oP '<[^<>]+>' | while read endpointInfo ; do {
#     echo "S----------------------------------------------"
#     # echo "$endpointInfo"
#     scanAndFollowDependencies "$file" "$endpointInfo" | sort -u
#     echo "E----------------------------------------------"
#     # | sort -u
# } ; done
