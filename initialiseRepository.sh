#!/bin/bash

git --version && git clone https://github.com/LBHackney-IT/social-care-case-viewer-api.git || (echo "Git is not installed!" && exit 1)
