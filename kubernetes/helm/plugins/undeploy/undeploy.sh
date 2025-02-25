#!/bin/bash

usage() {
cat << EOF
Delete an umbrella Helm Chart, and its subcharts, that was previously deployed using 'Helm deploy'.

Example of deleting all Releases that have the prefix 'demo'.
  $ helm undeploy demo

  $ helm undeploy demo --purge

Usage:
  helm undeploy [RELEASE] [flags]

Flags:
      --purge     remove the releases from the store and make its name free for later use
EOF
}

undeploy() {
  RELEASE=$1
  FLAGS=$2

  array=($(helm ls -q --all | grep $RELEASE))
  n=${#array[*]}
  for i in $(seq $(($n-1)) -1 0)
  do
    helm del "${array[i]}" $FLAGS
  done
}

if [ -z "$1" ]; then
  echo "Error: command 'undeploy' requires a release name"
  exit 1
fi

case "${1:-"help"}" in
  "help")
    usage
    ;;
  "--help")
    usage
    ;;
  "-h")
    usage
    ;;
  *)
    undeploy $1 $(echo ${@} | sed 's/^ *[^ ]* *//')
    ;;
esac

exit 0
