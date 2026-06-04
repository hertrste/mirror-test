#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/cyberus-technology/libvirt.git}"
TARGET_REMOTE="${TARGET_REMOTE:-origin}"
BRANCH_PREFIX="${BRANCH_PREFIX:-libvirt/}"
TAG_PREFIX="${TAG_PREFIX:-libvirt/}"
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-main}"
MIRROR_ROOT="refs/mirror/libvirt"
BATCH_SIZE="${BATCH_SIZE:-100}"

die() {
  echo "error: $*" >&2
  exit 1
}

normalize_prefix() {
  local prefix="$1"

  [[ -n "${prefix}" ]] || die "ref prefix must not be empty"
  [[ "${prefix}" == */ ]] || prefix="${prefix}/"
  [[ "${prefix}" != "/" ]] || die "ref prefix must not be /"

  printf '%s' "${prefix}"
}

is_protected_branch() {
  local branch="$1"
  local protected

  for protected in ${PROTECTED_BRANCHES}; do
    if [[ "${branch}" == "${protected}" ]]; then
      return 0
    fi
  done

  return 1
}

push_batch() {
  local -n refspecs_ref="$1"

  if ((${#refspecs_ref[@]} == 0)); then
    return
  fi

  git push "${TARGET_REMOTE}" "${refspecs_ref[@]}"
  refspecs_ref=()
}

BRANCH_PREFIX="$(normalize_prefix "${BRANCH_PREFIX}")"
TAG_PREFIX="$(normalize_prefix "${TAG_PREFIX}")"

git check-ref-format "refs/heads/${BRANCH_PREFIX}probe" >/dev/null
git check-ref-format "refs/tags/${TAG_PREFIX}probe" >/dev/null

git fetch --prune --no-tags "${UPSTREAM_URL}" \
  "+refs/heads/*:${MIRROR_ROOT}/heads/*" \
  "+refs/tags/*:${MIRROR_ROOT}/tags/*"

declare -A upstream_branches=()
declare -A upstream_tags=()
declare -a branch_refspecs=()
declare -a tag_refspecs=()
declare -a delete_branch_refspecs=()
declare -a delete_tag_refspecs=()

while IFS= read -r source_ref; do
  branch="${source_ref#${MIRROR_ROOT}/heads/}"
  target_branch="${BRANCH_PREFIX}${branch}"
  target_ref="refs/heads/${target_branch}"

  is_protected_branch "${target_branch}" && die "refusing to update protected branch ${target_branch}"

  upstream_branches["${branch}"]=1
  branch_refspecs+=("+${source_ref}:${target_ref}")

  if ((${#branch_refspecs[@]} >= BATCH_SIZE)); then
    push_batch branch_refspecs
  fi
done < <(git for-each-ref --format='%(refname)' "${MIRROR_ROOT}/heads")

push_batch branch_refspecs

while IFS=$'\t' read -r _ remote_ref; do
  [[ "${remote_ref}" == refs/heads/"${BRANCH_PREFIX}"* ]] || continue

  branch="${remote_ref#refs/heads/${BRANCH_PREFIX}}"
  if [[ -z "${upstream_branches[${branch}]+present}" ]]; then
    delete_branch_refspecs+=(":${remote_ref}")
  fi

  if ((${#delete_branch_refspecs[@]} >= BATCH_SIZE)); then
    push_batch delete_branch_refspecs
  fi
done < <(git ls-remote --heads "${TARGET_REMOTE}")

push_batch delete_branch_refspecs

while IFS= read -r source_ref; do
  tag="${source_ref#${MIRROR_ROOT}/tags/}"
  target_ref="refs/tags/${TAG_PREFIX}${tag}"

  upstream_tags["${tag}"]=1
  tag_refspecs+=("+${source_ref}:${target_ref}")

  if ((${#tag_refspecs[@]} >= BATCH_SIZE)); then
    push_batch tag_refspecs
  fi
done < <(git for-each-ref --format='%(refname)' "${MIRROR_ROOT}/tags")

push_batch tag_refspecs

while IFS=$'\t' read -r _ remote_ref; do
  [[ "${remote_ref}" != *'^{}' ]] || continue
  [[ "${remote_ref}" == refs/tags/"${TAG_PREFIX}"* ]] || continue

  tag="${remote_ref#refs/tags/${TAG_PREFIX}}"
  if [[ -z "${upstream_tags[${tag}]+present}" ]]; then
    delete_tag_refspecs+=(":${remote_ref}")
  fi

  if ((${#delete_tag_refspecs[@]} >= BATCH_SIZE)); then
    push_batch delete_tag_refspecs
  fi
done < <(git ls-remote --tags "${TARGET_REMOTE}")

push_batch delete_tag_refspecs
