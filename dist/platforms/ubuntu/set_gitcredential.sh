#!/usr/bin/env bash

if [ -z "${GIT_PRIVATE_TOKEN}" ]
then
  echo "GIT_PRIVATE_TOKEN unset skipping"
else
  echo "GIT_PRIVATE_TOKEN is set configuring git credentials"

	git config --global credential.helper store
	git config --global --replace-all url."https://x-access-token:$GIT_PRIVATE_TOKEN@github.com/".insteadOf ssh://git@github.com/
	git config --global --add url."https://x-access-token:$GIT_PRIVATE_TOKEN@github.com/".insteadOf git@github.com
  git config --global --add url."https://x-access-token:$GIT_PRIVATE_TOKEN@github.com/".insteadOf "https://github.com/"

  git config --global url."https://x-access-token:$GIT_PRIVATE_TOKEN@github.com/".insteadOf "ssh://git@github.com/"
  git config --global url."https://x-access-token:$GIT_PRIVATE_TOKEN@github.com/".insteadOf "git@github.com:"

fi

echo "---------- git config --list -------------"
git config --list

echo "---------- git config --list --show-origin -------------"
git config --list --show-origin
