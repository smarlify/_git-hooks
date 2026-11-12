#!/bin/bash
# shared/security-check.sh
# Reusable security check functions for git hooks

# Colors for output (only if outputting to a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# List of sensitive patterns to block
SENSITIVE_PATTERNS=(
    "AIza[0-9A-Za-z_-]{35}"  # Google API keys
    "sk-[0-9A-Za-z]{48}"     # OpenAI API keys
    "xoxb-[0-9]{11}-[0-9]{11}-[0-9A-Za-z]{24}"  # Slack bot tokens
    "xoxp-[0-9]{11}-[0-9]{11}-[0-9A-Za-z]{24}"  # Slack user tokens
    "https://hooks\.slack\.com/services/[A-Z0-9]+/[A-Z0-9]+/[A-Za-z0-9]+"  # Slack webhooks
    "-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----"  # Private keys
    "AKIA[0-9A-Z]{16}"       # AWS access keys
    "ya29\.[0-9A-Za-z_-]+"   # Google OAuth tokens
    "(^|[^0-9A-Za-z_/-])1/[0-9A-Za-z_-]{43}"  # Google refresh tokens (not inside a URL path like /2024/11/...)
    "AIzaSy[0-9A-Za-z_-]{33}" # Firebase API keys
    "firebase.*api.*key"      # Firebase config
    "mongodb://.*:.*@"        # MongoDB connection strings
    "postgres://.*:.*@"       # PostgreSQL connection strings
    "mysql://.*:.*@"          # MySQL connection strings
    "redis://.*:.*@"          # Redis connection strings
    "(^|[^A-Za-z0-9_])NEXT_PUBLIC_.*=\s*['\"][^'\"]*['\"]"  # Next.js public env vars with actual values
    "(^|[^A-Za-z0-9_])REACT_APP_.*=\s*['\"][^'\"]*['\"]"    # React app env vars with actual values
    "(^|[^A-Za-z0-9_])VITE_.*=\s*['\"][^'\"]*['\"]"         # Vite env vars with actual values (not "invite_...")
    "password\s*=\s*['\"][^'\"]*['\"]"     # Password fields with actual values
    "secret\s*=\s*['\"][^'\"]*['\"]"       # Secret fields with actual values
    "(^|[^?&])token\s*=\s*['\"][^'\"]*['\"]"  # Token fields with actual values (not a ?token= / &token= URL query)
    "api.*key\s*=\s*['\"][^'\"]*['\"]"     # API key fields with actual values
)

# This file lists the patterns as text, so it matches itself. It is skipped
# only when the file being scanned is this very script (the kit's own repo).
SECURITY_CHECK_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Function to check files for sensitive data
# $3 (optional): the commit to read the files from. Without it, the staged
# (index) version is read. A pushed commit must be scanned at its own content,
# not at whatever the current checkout has staged.
check_files_for_sensitive_data() {
    local files="$1"
    local context="$2"  # "staged files" or "commits"
    local rev="${3:-}"

    echo "${YELLOW}🔒 Checking for sensitive data in $context...${NC}"

    local sensitive_found=false
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P)

    # One path per line, so names with spaces are scanned too.
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        if [ -n "$top" ] && [ "$top/$file" = "$SECURITY_CHECK_SELF" ]; then
            continue
        fi
        # Skip binary files
        if [ -n "$rev" ]; then
            if git diff-tree --no-commit-id --numstat -r "$rev" -- "$file" 2>/dev/null | grep -q "^-"; then
                continue
            fi
        elif git diff --cached --numstat "$file" 2>/dev/null | grep -q "^-"; then
            continue
        fi
        
        # Skip package-lock.json and similar lock files from Google refresh token check
        # (they contain legitimate hash values that can match the pattern)
        local skip_google_token_check=false
        if [[ "$file" == *"package-lock.json"* ]] || [[ "$file" == *"yarn.lock"* ]] || [[ "$file" == *"pnpm-lock.yaml"* ]]; then
            skip_google_token_check=true
        fi
        
        # Check file content for sensitive patterns
        for pattern in "${SENSITIVE_PATTERNS[@]}"; do
            # Skip Google refresh token pattern for lock files
            if [ "$skip_google_token_check" = true ] && [[ "$pattern" == *"1/[0-9A-Za-z_-]{43}" ]]; then
                continue
            fi
            
            if git show "${rev}:$file" 2>/dev/null | grep -iE "$pattern" >/dev/null 2>&1; then
                echo "${RED}❌ SECURITY VIOLATION DETECTED!${NC}"
                echo "${RED}File: $file${NC}"
                echo "${RED}Pattern: $pattern${NC}"
                echo "${RED}This file contains sensitive data and cannot be committed!${NC}"
                echo ""
                echo "${YELLOW}Common sensitive data types:${NC}"
                echo "  • API keys (Google, OpenAI, AWS, etc.)"
                echo "  • Database connection strings"
                echo "  • Slack webhooks and tokens"
                echo "  • Private keys and certificates"
                echo "  • Environment variables with secrets"
                echo "  • Passwords and authentication tokens"
                echo ""
                echo "${YELLOW}To fix this:${NC}"
                echo "  1. Remove the sensitive data from the file"
                echo "  2. Add the file to .gitignore if it contains secrets"
                echo "  3. Use environment variables instead"
                echo "  4. Consider using a secrets management service"
                echo ""
                sensitive_found=true
            fi
        done
    done <<< "$files"

    if [ "$sensitive_found" = true ]; then
        echo "${RED}🚨 COMMIT BLOCKED: Sensitive data detected!${NC}"
        echo "${RED}Please remove all sensitive information before committing.${NC}"
        return 1
    fi
    
    echo "${GREEN}✅ No sensitive data detected${NC}"
    return 0
}

# Function to check staged files
check_staged_files() {
    local staged_files=$(git diff --cached --name-only)
    check_files_for_sensitive_data "$staged_files" "staged files"
}

# Function to check commits being pushed
check_commits() {
    local commits="$1"
    local sensitive_found=false
    
    echo "${YELLOW}🔒 Checking for sensitive data in commits...${NC}"
    
    for commit in $commits; do
        if [ "$commit" != "0000000000000000000000000000000000000000" ]; then
            local changed_files=$(git diff-tree --no-commit-id --name-only -r "$commit")
            if ! check_files_for_sensitive_data "$changed_files" "commit $commit" "$commit"; then
                sensitive_found=true
            fi
        fi
    done
    
    if [ "$sensitive_found" = true ]; then
        echo "${RED}🚨 PUSH BLOCKED: Sensitive data detected!${NC}"
        echo "${RED}Please remove all sensitive information before pushing.${NC}"
        return 1
    fi
    
    echo "${GREEN}✅ No sensitive data detected in commits${NC}"
    return 0
}
