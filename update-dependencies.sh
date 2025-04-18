#!/bin/bash

swift package update

if [[ `git status --porcelain` ]]; then
	git add Package.resolved
	git commit -m dependencies
 	git push
else
	echo "no updates"
fi

rm -rf .build