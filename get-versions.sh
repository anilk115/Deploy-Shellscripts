#!/bin/bash

eval git ls-remote -t $1 | grep $2 | awk '{print $2}' | sed -n "s#^refs/tags/$2-\([0-9.]*\).*#\1#p" | uniq | sort -r -V
