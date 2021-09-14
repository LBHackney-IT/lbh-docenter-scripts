#!/bin/bash

projectDirectory=''

while getopts 'd:' flag; do
  case "${flag}" in
    d) projectDirectory="${OPTARG}" ;;
    *) error "Unexpected option ${flag}" ;;
  esac
done

# No need to search the project root or tests project
apiProjectDirectory=$( find $projectDirectory -mindepth 1 -type d -iname '*Api' )

# echo "something: ${apiProjectDirectory}"

postgreContextsFiles=$( grep -rnwE $apiProjectDirectory -e 'public class \w+ : DbContext' )
postgreContexts=$( echo $postgreContextsFiles | grep -woP '(?<=public class )\w+(?= \: DbContext)' )


# for i in $postgreContexts
# do
#     echo "output: $i"
# done


mongoContextsFiles=$( grep -rlwE $apiProjectDirectory -e 'public IMongoCollection<BsonDocument> \w+ { get\; set\; }' )
mongoContexts=$( grep -oP -e '(?<=public class )(\w+)(?= \: I\1)' $mongoContextsFiles )


echo $mongoContextsList




