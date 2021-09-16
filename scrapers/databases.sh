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
    echo "Debug!"
    echo $interface
    # Need to be able to handle dead ends like with the RainContext & commented out code... so selectors should start with \s+?(?<!\/\/)s+?
    gateways=$( grep -rlwP $apiProjectDirectory -e "(?<=private readonly )$interface(?= \w+;)" )
    echo $gateways
    echo "Debug!"
    # should be another for each
    # Retrieving the interface of a gateway that uses db context. Getting the interface to trace down
    # the use cases that use this gateway as their dependency
    gatewayInterface=$( grep -oP -e 'public class \w+ : \K\w+$)' $gateways )
    echo $gatewayUsingDBContext
done


echo "Done!"
