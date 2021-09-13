#!/bin/bash

projectDirectory=''

while getopts 'd:' flag; do
  case "${flag}" in
    d) projectDirectory="${OPTARG}" ;;
    *) error "Unexpected option ${flag}" ;;
  esac
done

echo "hello! dirpath: ${projectDirectory}"

# No need to search the project root or tests project
apiProjectDirectory=$( find $projectDirectory -mindepth 1 -type d -iname '*Api' )

# echo "something: ${apiProjectDirectory}"

postgreContextsList=$( grep -rnwE $apiProjectDirectory -e 'public class \w+ : DbContext' ) #'public\sclass\s\w+\s:\sDbContext'

echo -e "Result: ${postgreContextsList}"

mongoContextsList=$( grep -rlwE $apiProjectDirectory -e 'public IMongoCollection<BsonDocument> \w+ { get; set; }' )

echo -e "Mongo: ${mongoContextsList}"

#'public class DatabaseContext : DbContext'
