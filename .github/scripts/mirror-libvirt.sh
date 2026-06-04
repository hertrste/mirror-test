#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/cyberus-technology/libvirt.git}"
TARGET_REMOTE="${TARGET_REMOTE:-origin}"
BRANCH_PREFIX="${BRANCH_PREFIX:-libvirt/}"
TAG_PREFIX="${TAG_PREFIX:-libvirt/}"
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-main}"
MIRROR_ROOT="refs/mirror/libvirt"
TARGET_ROOT="refs/mirror-target/libvirt"
BATCH_SIZE="${BATCH_SIZE:-100}"
SANITIZED_PATHS=(".github/workflows")
WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/mirror-libvirt.XXXXXX")"
SANITIZE_COUNTER=0

trap 'rm -rf "${WORK_DIR}"' EXIT

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

has_sanitized_marker() {
  local commit="$1"

  git log -1 --format=%B "${commit}" | grep -qx 'Mirror-Sanitized: true'
}

has_upstream_commit_marker() {
  local commit="$1"
  local upstream_commit="$2"

  git log -1 --format=%B "${commit}" | grep -qx "Upstream-Commit: ${upstream_commit}"
}

sanitized_tree() {
  local source_ref="$1"
  local index_file
  local tree
  local path
  local -a removed_paths=()

  SANITIZE_COUNTER=$((SANITIZE_COUNTER + 1))
  index_file="${WORK_DIR}/index.${SANITIZE_COUNTER}"

  GIT_INDEX_FILE="${index_file}" git read-tree "${source_ref}^{tree}"

  for path in "${SANITIZED_PATHS[@]}"; do
    while IFS= read -r -d '' removed_path; do
      removed_paths+=("${removed_path}")
    done < <(GIT_INDEX_FILE="${index_file}" git ls-files -z -- "${path}")
  done

  if ((${#removed_paths[@]} > 0)); then
    GIT_INDEX_FILE="${index_file}" git update-index --force-remove -- "${removed_paths[@]}"
  fi

  tree="$(GIT_INDEX_FILE="${index_file}" git write-tree)"
  rm -f "${index_file}"

  printf '%s' "${tree}"
}

sanitized_commit() {
  local source_ref="$1"
  local target_local_ref="$2"
  local source_kind="$3"
  local source_name="$4"
  local upstream_commit
  local tree
  local existing_commit=""
  local existing_tree=""
  local author_name
  local author_email
  local author_date
  local commit
  local -a parent_args=()

  upstream_commit="$(git rev-parse --verify "${source_ref}^{commit}")"
  tree="$(sanitized_tree "${source_ref}")"

  if existing_commit="$(git rev-parse --verify "${target_local_ref}^{commit}" 2>/dev/null)"; then
    existing_tree="$(git rev-parse "${existing_commit}^{tree}")"

    if [[ "${existing_tree}" == "${tree}" ]] &&
      has_sanitized_marker "${existing_commit}" &&
      has_upstream_commit_marker "${existing_commit}" "${upstream_commit}"; then
      printf '%s' "${existing_commit}"
      return
    fi

    if has_sanitized_marker "${existing_commit}"; then
      parent_args=(-p "${existing_commit}")
    fi
  fi

  author_name="$(git show -s --format=%an "${upstream_commit}")"
  author_email="$(git show -s --format=%ae "${upstream_commit}")"
  author_date="$(git show -s --format=%aI "${upstream_commit}")"

  commit="$(
    GIT_AUTHOR_NAME="${author_name}" \
      GIT_AUTHOR_EMAIL="${author_email}" \
      GIT_AUTHOR_DATE="${author_date}" \
      GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-github-actions[bot]}" \
      GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
      git commit-tree "${tree}" "${parent_args[@]}" <<EOF
Mirror libvirt ${source_kind} ${source_name}

Upstream-Commit: ${upstream_commit}
Upstream-Ref: ${source_ref}
Mirror-Sanitized: true
Sanitized-Paths: ${SANITIZED_PATHS[*]}
EOF
  )"

  git update-ref "${target_local_ref}" "${commit}"
  printf '%s' "${commit}"
}

BRANCH_PREFIX="$(normalize_prefix "${BRANCH_PREFIX}")"
TAG_PREFIX="$(normalize_prefix "${TAG_PREFIX}")"

git check-ref-format "refs/heads/${BRANCH_PREFIX}probe" >/dev/null
git check-ref-format "refs/tags/${TAG_PREFIX}probe" >/dev/null

git fetch --prune --no-tags "${UPSTREAM_URL}" \
  "+refs/heads/*:${MIRROR_ROOT}/heads/*" \
  "+refs/tags/*:${MIRROR_ROOT}/tags/*"

if git ls-remote --exit-code --heads "${TARGET_REMOTE}" "refs/heads/${BRANCH_PREFIX}*" >/dev/null 2>&1; then
  git fetch --prune --no-tags "${TARGET_REMOTE}" \
    "+refs/heads/${BRANCH_PREFIX}*:${TARGET_ROOT}/heads/*"
fi

if git ls-remote --exit-code --tags "${TARGET_REMOTE}" "refs/tags/${TAG_PREFIX}*" >/dev/null 2>&1; then
  git fetch --prune --no-tags "${TARGET_REMOTE}" \
    "+refs/tags/${TAG_PREFIX}*:${TARGET_ROOT}/tags/*"
fi

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
  target_local_ref="${TARGET_ROOT}/heads/${branch}"

  is_protected_branch "${target_branch}" && die "refusing to update protected branch ${target_branch}"

  upstream_branches["${branch}"]=1
  branch_refspecs+=("+$(sanitized_commit "${source_ref}" "${target_local_ref}" branch "${branch}"):${target_ref}")

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
  target_local_ref="${TARGET_ROOT}/tags/${tag}"

  upstream_tags["${tag}"]=1
  if git rev-parse --verify "${source_ref}^{commit}" >/dev/null 2>&1; then
    tag_refspecs+=("+$(sanitized_commit "${source_ref}" "${target_local_ref}" tag "${tag}"):${target_ref}")
  else
    echo "warning: skipping non-commit tag ${tag}" >&2
  fi

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
