#!/bin/bash

projectDirectory=''

while getopts 'd:' flag; do
  case "${flag}" in
    d) projectDirectory="${OPTARG}" ;;
    *) error "Unexpected option ${flag}" ;;
  esac
done

# 1st arg: Class name that implements the interface
# 2nd arg: Startup file path
# If incorrect args get provided, this means there's an issue with
# how the project is structured, so it's probably for the better to
# exit entirely rather than to give a false positive impression.
# This function should be used for more general cases, for MVP only
# we assume typical code practices
function find_class_interface {
    local className=$1
	local startupFilePath=$2

    [ -z "$className" ] && { echo "Class name is not provided!"; exit 1; }
    [ -z "$startupFilePath" ] && { echo "Startup file location is not provided!"; exit 1; }

	local interfaceName=$( grep -oP -e "services\.(?:AddScoped|AddTransient|AddSingleton)<\K\w+(?=, $className>\(\)\;)" $startupFilePath)

    if [ -z "$interfaceName" ]
    then
        echo "No interface was found!"
        exit 1
    else
        echo $interfaceName
    fi
}

# Gets the interface of the class within file
function get_file_interface {
    local filePath=$1

    [ -z "$filePath" ] && { echo "File path is empty!"; exit 1; }

    local interfaceName=$( grep -oP -e 'public class \w+ : \K\w+$' $filePath )

    if [ -z "$interfaceName" ]
    then
        echo "No interface was found!" && exit 1 # Exit code is used in a way, where if command succeeds finding GW, the proceeds UC
    else
        echo $interfaceName
    fi
}

function find_files_using_interface {
    local interface=$1

    [ -z "$interface" ] && { echo "Interface is empty!"; exit 1; }
    
    # Not sure if it's better to reprint it, or to return as is.
    #fileImplentingInterface=$( )
    grep -rlwE $apiProjectDirectory -e "public class \w+ : $interface"
}


# No need to search the project root or tests project
apiProjectDirectory=$( find $projectDirectory -mindepth 1 -type d -iname '*Api' )
startupFile=$( find $apiProjectDirectory -type f -name 'Startup.cs'  ) # Won't hurt to be safe


postgreContextsFiles=$( grep -rnwE $apiProjectDirectory -e 'public class \w+ : DbContext' )
postgreContexts=$( echo $postgreContextsFiles | grep -woP '(?<=public class )\w+(?= \: DbContext)' )
# PostgreSQL contexts are injected as instances, so they don't have an interface


mongoContextsFiles=$( grep -rlwE $apiProjectDirectory -e 'public IMongoCollection<BsonDocument> \w+ { get\; set\; }' )
# Could probably grab interface directly, but I have hopes of extracting the whole op into func

# Need to also search "IMongoDatabase", which is part of Mongo Driver I assume.
# Seems, there are a couple ways of implementing the MongoDB
for file in $mongoContextsFiles
do
    mongoDBClass=$( grep -oP -e '(?<=public class )\w+(?= \: \w+$)' $file ) # should call this get class within a file
    interface=$( find_class_interface $mongoDBClass $startupFile )

    # Need to be able to handle dead ends like with the RainContext & commented out code... so selectors should start with \s+?(?<!\/\/)s+?
    gateways=$( grep -rlwP $apiProjectDirectory -e "(?<=private readonly )$interface(?= \w+;)" )

    # should be another for each
    # Retrieving the interface of a gateway that uses db context. Getting the interface to trace down
    # the use cases that use this gateway as their dependency
    # TODO: Modify this to work with multiple inheritance (like : A, B)
    gatewayInterface=$( get_file_interface $gateways )
    #echo "GWI: $gatewayInterface"
    # Finds UC and another GW???
    usecases=$( grep -rlwP $apiProjectDirectory -e "(?<=private readonly )$gatewayInterface(?= \w+;)" | grep -P ".+?\/V\d\/UseCase\/.+" )
    for ucFile in $usecases
    do
        # TODO: extract this Interface extraction command into a function - it's going to get used many times
        ucInterface=$( get_file_interface $ucFile )
        #echo "uc: $ucInterface"
    done
done

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

echo "Start!"

#can't guarantee readonly because of shit code quality that devs produce
dependencyInterfacePattern='private(?: readonly)? \K\w+(?= \w+;)'
dependencyVariablePattern='private(?: readonly)? \K\w+ \K\w+(?=;)'

dependencyPattern='private(?: readonly)? \K\w+ \w+(?=;)'

endpointTypePattern='(?<=[Http)\w+'
endpointName='(IActionResult>? \K\w+)'


# Let's try going from the other side instead:
# For MVP version is hard coded to V1, TODO: make script search versions first
# Get the list of Controllers:
controllersList=$( find "$apiProjectDirectory/V1/Controllers" -mindepth 1 )

for controller in $controllersList
do
    echo -e "\n$controller"
    
    usecasesVarsPattern=$( grep -oP -e "$dependencyVariablePattern" $controller | \
        tr '\n' '|' | sed -E 's/\|$//g' )

    # declare use case var to interface lookup
    eval "declare -A ucInterfaceLookup=($(\
        grep -oP "private(?: readonly)? \K\w+ \w+" $controller | \
        sed -E 's/(\w+)\s(\w+)/\[\2\]=\1/g' | \
        tr '\n' ' '))"
    # for endpoint in $endpointsList
    # do
    #     echo -e '\n'
    #     echo -e $endpoint
    # done

    pcregrep -oM '\[Http\w+\]\s+(?:\[[^\[\]]+\]\s+)*public (?:async Task<)?IActionResult>? \w+' $controller | \
    perl -0777 -pe 's/(?:(?:\[Http(\w+)\]|\[Route\(\"([^\[\(\)\]]+)\"\)\])\s+)+(?:\[[^\[\]]+\]\s+)*public (?:async Task<)?'\
'IActionResult>? (\w+)/<R: \2\; T: \1\; N: \3\;>/gm' | \
    grep -oP '<[^<>]+>' | while read endpointInfo
    do
        endpointName=$( echo $endpointInfo | grep -oP '(?<=N: )\w+' )
        pcregrep -oM "public (?:async Task<)?IActionResult>? $endpointName\([^\(\)]+\)(\s+)\{[\s\S]+?\1\}" $controller | \
        grep -oP "(?:$usecasesVarsPattern)\.\w+" | while read usecaseCall ; do {
            usecaseMethod=$(echo "$usecaseCall" | grep -oP '\.\K\w+')
            usecaseVarName=$(echo "$usecaseCall" | grep -oP '\w+(?=\.)')
            echo $usecaseMethod
            echo $usecaseVarName
            echo ${ucInterfaceLookup[$usecaseVarName]}
            # UC File
            ucFileName=$(find_files_using_interface ${ucInterfaceLookup[$usecaseVarName]})
            gatewayVarsPattern=$( grep -oP -e "$dependencyVariablePattern" $ucFileName | \
                tr '\n' '|' | sed -E 's/\|$//g' )

            eval "declare -A gwInterfaceLookup=($(\
                grep -oP "private(?: readonly)? \K\w+ \w+" $ucFileName | \
                sed -E 's/(\w+)\s(\w+)/\[\2\]=\1/g' | \
                tr '\n' ' '))"

            pcregrep -oM "(?:(?:public|static) )+\S+\?? $usecaseMethod\([^\(\)]+\)(\s+)\{[\s\S]+?(?=\1\})" $ucFileName | \
            grep -oP "(?:$gatewayVarsPattern)\.\w+" | while read gatewayCall ; do {
                gatewayMethod=$(echo "$gatewayCall" | grep -oP '\.\K\w+')
                gatewayVarName=$(echo "$gatewayCall" | grep -oP '\w+(?=\.)')

                gwFileName=$(find_files_using_interface ${gwInterfaceLookup[$gatewayVarName]})
                echo "$gatewayCall: $gwFileName"

                if [ -n "$(echo $gwFileName | tr -d ' ')" ]
                then
                    databaseVarsPattern=$( grep -oP -e "$dependencyVariablePattern" $gwFileName | \
                        tr '\n' '|' | sed -E 's/\|$//g' )
                    
                    eval "declare -A dbInterfaceLookup=($(\
                        grep -oP "private(?: readonly)? \K\w+ \w+" $gwFileName | \
                        sed -E 's/(\w+)\s(\w+)/\[\2\]=\1/g' | \
                        tr '\n' ' '))"
                    
                    pcregrep -oM "(?:(?:public|static) )+\S+\?? $gatewayMethod\([^\(\)]+\)(\s+)\{[\s\S]+?(?=\1\})" $gwFileName | \
                    grep -oP "(?:$databaseVarsPattern)\.\w+"
                fi
            } ; done
        } ; done
        echo "E--------------------------------"
    done
done


# All methods:
# public (?:async Task<)?IActionResult>? \w+\([^\(\)]+\)(\s+)\{[\s\S]+?\1\}

#Will need to ignore empty ones like Healthcheck

echo "Done!"

# DB Context --> Find Interface if any
# DB Context -->                       --> Find 
