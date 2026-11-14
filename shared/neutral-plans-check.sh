#!/bin/bash
# shared/neutral-plans-check.sh
# A shared repo (this hook kit, a manifest) may keep plans, but a plan there must stay
# neutral: it describes the change to the shared repo, never the app, product, client
# or workspace it came from. Refused in such a plan:
#   - a forbidden name (from local git config, so the names never enter the repo)
#   - a local path that reveals a machine or workspace (/Users/x/, /home/x/, C:\Users\)
#   - a link to another repository (github.com/<owner>/<repo> other than this one)
#
# Opt-in per repo, local config only (never committed):
#   git config hooks.neutralPlans true
#   git config hooks.forbiddenNames "name1,name2"   # whole words, case-insensitive
#   git config hooks.neutralPaths ".cursor/plans/"   # optional; comma list of path prefixes
#   git config hooks.ownRepos "owner/repo"           # optional; extra allowed repo links
# The repo's own origin is always an allowed link.

np_enabled() { [ "$(git config --bool hooks.neutralPlans 2>/dev/null)" = "true" ]; }

np_in_scope() {
    local file="$1" prefixes p
    prefixes=$(git config hooks.neutralPaths 2>/dev/null || echo ".cursor/plans/")
    IFS=',' read -ra list <<<"$prefixes"
    for p in "${list[@]}"; do
        p="${p//[[:space:]]/}"
        [ -n "$p" ] && [[ "$file" == "$p"* ]] && return 0
    done
    return 1
}

# owner/repo of origin plus hooks.ownRepos, lower-case, one per line
np_own_repos() {
    local url slug extra r
    url=$(git remote get-url origin 2>/dev/null || true)
    slug=$(printf '%s' "$url" | sed -nE 's#.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed -E 's/\.git$//')
    [ -n "$slug" ] && printf '%s\n' "$slug" | tr '[:upper:]' '[:lower:]'
    extra=$(git config hooks.ownRepos 2>/dev/null || true)
    IFS=',' read -ra list <<<"$extra"
    for r in "${list[@]}"; do
        r="${r//[[:space:]]/}"
        [ -n "$r" ] && printf '%s\n' "$r" | tr '[:upper:]' '[:lower:]'
    done
}

# Prints one line per problem in the given content.
np_problems() {
    local content="$1" names n link own
    names=$(git config hooks.forbiddenNames 2>/dev/null || true)
    IFS=',' read -ra list <<<"$names"
    for n in "${list[@]}"; do
        n="$(printf '%s' "$n" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [ -z "$n" ] && continue
        if grep -qiwF -- "$n" <<<"$content"; then
            echo "names \"$n\" (a forbidden name)"
        fi
    done
    if grep -qE '(/Users/[^/[:space:]]+/|/home/[^/[:space:]]+/|[A-Za-z]:\\Users\\)' <<<"$content"; then
        echo "contains a local path (/Users/…, /home/…, C:\\Users\\…)"
    fi
    own=$(np_own_repos)
    while IFS= read -r link; do
        [ -z "$link" ] && continue
        link=$(printf '%s' "$link" | sed -E 's/\.+$//; s/\.git$//')
        if ! grep -qxF -- "$link" <<<"$own"; then
            echo "links another repository (github.com/$link)"
        fi
    done < <(grep -oiE 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' <<<"$content" | tr '[:upper:]' '[:lower:]' | sed -E 's#^github\.com[:/]##' | sort -u)
}

# $1 files (one per line), $2 revision to read from ("" = the index)
np_check_files() {
    local files="$1" rev="$2" file content problems failed=0
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        np_in_scope "$file" || continue
        content=$(git show "${rev}:$file" 2>/dev/null) || continue
        problems=$(np_problems "$content")
        if [ -n "$problems" ]; then
            echo "${RED}❌ NOT A NEUTRAL PLAN: $file${NC}"
            while IFS= read -r p; do echo "${RED}   - $p${NC}"; done <<<"$problems"
            failed=1
        fi
    done <<<"$files"
    if [ "$failed" = 1 ]; then
        echo ""
        echo "${YELLOW}Plans in this shared repo must stay neutral: describe the change to this repo,${NC}"
        echo "${YELLOW}not the app, product, client or workspace it came from. Remove the names, local${NC}"
        echo "${YELLOW}paths and links to other repos, or keep the plan in the project's own workspace.${NC}"
        return 1
    fi
    return 0
}

check_neutral_plans_staged() {
    np_enabled || return 0
    echo "${YELLOW}🧭 Checking that plans stay neutral...${NC}"
    np_check_files "$(git diff --cached --name-only --diff-filter=ACMR)" "" || return 1
    echo "${GREEN}✅ Plans are neutral${NC}"
}

# $1 the pushed tips. Every commit behind them that no remote has yet is checked,
# so a bad plan removed again in a later commit still cannot reach the remote history.
check_neutral_plans_commits() {
    local tips="$1" tip commit failed=0
    np_enabled || return 0
    echo "${YELLOW}🧭 Checking that plans in the pushed commits stay neutral...${NC}"
    for commit in $(for tip in $tips; do
                        [ "$tip" = "0000000000000000000000000000000000000000" ] && continue
                        git rev-list "$tip" --not --remotes 2>/dev/null
                    done | sort -u); do
        np_check_files "$(git diff-tree --root --no-commit-id --name-only --diff-filter=ACMR -r "$commit")" "$commit" || failed=1
    done
    [ "$failed" = 1 ] && return 1
    echo "${GREEN}✅ Plans are neutral${NC}"
}
