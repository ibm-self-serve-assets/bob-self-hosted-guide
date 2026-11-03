#!/usr/bin/env bash
# Print the mapping list files needed for the Bob features you will enable.
#
# usage: select-lists.sh <list-dir> [--rag] [--zproxy] [--understand]
#   <list-dir>     mappings/amd64 (single architecture) or mappings/full (all architectures)
#   --rag          bob.rag.enabled: true
#   --zproxy       bob.zProxy.enabled: true (implies --rag, as the chart does)
#   --understand   bob.understand.enabled: true (treated as implying --rag, see below)
#
# Prints one list file path per line. Use it as: LISTS=$(mappings/select-lists.sh mappings/amd64 --zproxy)

dir="${1:-}"
if [ -z "${dir}" ] || [ ! -d "${dir}" ]; then
  printf 'usage: %s <list-dir> [--rag] [--zproxy] [--understand]\n' "$0" >&2
  exit 1
fi
shift

rag=false
zproxy=false
understand=false
for arg in "$@"; do
  case "${arg}" in
    --rag) rag=true ;;
    --zproxy) zproxy=true ;;
    --understand) understand=true ;;
    *) printf 'unknown option: %s\n' "${arg}" >&2; exit 1 ;;
  esac
done

# zProxy implies RAG (the chart and bobctl both do this).
# Understand is treated the same way: docs/03-pre-install-config.md says OpenSearch is
# "required for Understand". Open question for the product team; extra images are harmless.
if [ "${zproxy}" = true ] || [ "${understand}" = true ]; then rag=true; fi

# Always needed
lists="ibm-bob.lst rhbk-operator.lst ibm-pg-operator.lst ibm-redis-cp.lst ibm-usage-metering.lst extra-ibm-licensing.lst"

# RAG: restore job and MCP server, plus OpenSearch
if [ "${rag}" = true ]; then
  lists="${lists} ibm-bob-rag.lst"
fi
if [ "${zproxy}" = true ]; then
  lists="${lists} ibm-bob-zproxy.lst"
fi
if [ "${understand}" = true ]; then
  lists="${lists} ibm-bob-understand.lst"
fi

# OpenSearch: needed by RAG (and therefore zProxy and Understand)
if [ "${rag}" = true ]; then
  lists="${lists} opencontent-opensearch.lst"
fi

# Shared helper images (busybox, ubi-minimal): the chart gives them to the operator but names no
# feature. Mirrored whenever any premium feature is on. Open question for the product team.
if [ "${rag}" = true ]; then
  lists="${lists} ibm-bob-z-common.lst"
fi

for f in ${lists}; do
  path="${dir%/}/${f}"
  if [ ! -f "${path}" ]; then
    printf 'error: list file not found: %s\n' "${path}" >&2
    exit 1
  fi
  printf '%s\n' "${path}"
done
