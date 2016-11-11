#!/bin/bash

if [ "x$2" == "x" ]; then REF=""; else REF="?ref=$2"; fi
curl -s -H "Authorization: token $VERSION_GETTER_API_TOKEN" -H 'Accept: application/vnd.github.v3.raw' -L "https://api.github.com/repos/NBCUOTS/$1/contents/project/pom.xml$REF" | grep "<version>" | head -n 1 | sed -n 's#.*>\([0-9]*\.[0-9]*\).*#\1#p'
