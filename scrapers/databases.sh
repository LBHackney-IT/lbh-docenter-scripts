#!/bin/bash

projectDirectory=''

while getopts 'd:' flag; do
  case "${flag}" in
    d) projectDirectory="${OPTARG}" ;;
    *) error "Unexpected option ${flag}" ;;
  esac
done

echo "hello! dirpath: ${projectDirectory}"
