#!/usr/bin/env bash

set -Eeuo pipefail

separator() {
  echo "--------------------"
}

prepare_mirror() {
  git remote remove origin

  if git remote get-url origin >/dev/null 2>&1; then
    echo "Origin still exists after removal; refusing to continue." >&2
    exit 1
  fi

  echo "::group::Filtering Platform files"
  git filter-repo --force \
    --path .dockerignore \
    --path .github/workflows/ \
    --path Makefile \
    --path docker/ \
    --path ops/ \
    --path-rename ops/README.md:README.md
  separator
  git ls-files | sort
  echo "::endgroup::"

  echo "::group::Gitleaks: Git history"
  gitleaks git --log-opts="--all" .
  echo "::endgroup::"

  echo "::group::Gitleaks: Git messages"
  git log --all --format='%an <%ae>%n%B' | gitleaks stdin
  separator
  git log --all --date=short --format='%h | %ad | %an <%ae> | %s'
  echo "::endgroup::"
}

publish_mirror() {
  : "${PLATFORM_TOKEN:?PLATFORM_TOKEN is required}"

  git remote add platform "https://x-access-token:${PLATFORM_TOKEN}@github.com/hokopiHQ/hokopi-platform.git"
  git push --force platform HEAD:main
}

case "${1:-}" in
  prepare)
    prepare_mirror
    ;;
  publish)
    publish_mirror
    ;;
  *)
    echo "Usage: $0 {prepare|publish}" >&2
    exit 1
    ;;
esac
