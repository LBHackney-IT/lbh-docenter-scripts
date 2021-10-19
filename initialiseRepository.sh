#!/bin/bash

(git --version || (echo "Git is not installed!" && exit 1)) && git clone https://github.com/LBHackney-IT/social-care-case-viewer-api.git 
