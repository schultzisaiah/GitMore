#!/bin/zsh

# ---
# Git Long-Lived Review Script
# ---
#
# This script creates a "virtual" branch containing all commits for a specific
# ticket ID. It intelligently combines commits from main and the remote review
# branch, and then creates/updates a PR, auto-assigning commit authors.
#
# DEPENDENCIES:
# - git
# - GitHub CLI (gh). Install from: https://cli.github.com/
#
# SETUP:
# 1. Save this script as 'git-review' in a directory on your PATH.
# 2. Make it executable: `chmod +x git-review`
# 3. Run `gh auth login` once to authenticate the GitHub CLI.
#
# USAGE:
# git-review <TicketID> [MainBranch]
#
# EXAMPLES:
# git-review "AB#1234"
# git-review "#5678"
# git-review "ab5678" develop
#

# --- Configuration ---
# The prefix for the review branches.
REVIEW_BRANCH_PREFIX="CR"
# The standard prefix for your tickets, including any separator.
# Example: "AB#", "JIRA-", "TICKET-"
TICKET_PREFIX="AB#"


# --- Script Logic ---

# 1. Input Validation
if [ -z "$1" ]; then
  echo "❌ Error: No Ticket ID provided."
  echo "Usage: $0 \"<TicketID>\" [MainBranch]"
  echo "Example: $0 \"AB#1234\""
  exit 1
fi

# 2. Input Processing and Normalization
echo "⚙️  Normalizing Ticket ID..."
# Extract just the numbers from the input string.
TICKET_NUMBER=$(echo "$1" | tr -dc '0-9')
if [ -z "$TICKET_NUMBER" ]; then
    echo "❌ Error: Could not find any numbers in the provided Ticket ID '$1'."
    exit 1
fi
# Reconstruct the ticket ID into a canonical format.
CANONICAL_TICKET_ID="${TICKET_PREFIX}${TICKET_NUMBER}"
# Create a sanitized version for the branch name.
SANITIZED_TICKET_ID=$(echo "$CANONICAL_TICKET_ID" | sed 's/[^a-zA-Z0-9]/-/g')
REVIEW_BRANCH_NAME="$REVIEW_BRANCH_PREFIX/$SANITIZED_TICKET_ID"

echo "🚀 Starting review preparation for Ticket ID: $CANONICAL_TICKET_ID"
echo "🌿 Review branch will be: $REVIEW_BRANCH_NAME"

# 3. Pre-flight Checks
# Check for uncommitted changes in the workspace.
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ Error: Your workspace has uncommitted changes."
  echo "Please commit, stash, or discard your changes before running this script."
  exit 1
fi
# Check for gh dependency.
if ! command -v gh &> /dev/null; then echo "❌ Error: GitHub CLI ('gh') is not installed."; exit 1; fi
echo "✅ Workspace is clean. Dependencies are met."

# 4. Determine Main Branch
MAIN_BRANCH=""
if [ -n "$2" ]; then
    MAIN_BRANCH="$2"
    echo "➡️ Using specified main branch: $MAIN_BRANCH"
else
    echo "🔎 Auto-detecting default branch from remote 'origin'..."
    git fetch origin
    DETECTED_BRANCH=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
    if [ -n "$DETECTED_BRANCH" ] && [ "$DETECTED_BRANCH" != "(unknown)" ]; then
        MAIN_BRANCH="$DETECTED_BRANCH"
        echo "✅ Detected '$MAIN_BRANCH' as the default remote branch."
    else
        echo "⚠️ Could not detect default branch from remote HEAD. Falling back to 'main' or 'master'."
        if git show-ref --verify --quiet refs/remotes/origin/main; then
            MAIN_BRANCH="main"
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
            MAIN_BRANCH="master"
        fi
        echo "✅ Detected '$MAIN_BRANCH' as the primary branch."
    fi
fi

if [ -z "$MAIN_BRANCH" ]; then
    echo "❌ Error: Could not auto-detect the default branch."
    echo "Please specify your main branch name as the second argument."
    echo "Usage: $0 \"<TicketID>\" <main-branch-name>"
    exit 1
fi

# 5. Auto-detect GitHub Repo
echo "🔎 Auto-detecting GitHub repository..."
GIT_REMOTE_URL=$(git remote get-url origin 2>/dev/null)
if [ -z "$GIT_REMOTE_URL" ]; then echo "❌ Error: Could not determine the remote 'origin' URL."; exit 1; fi
GITHUB_REPO=$(echo "$GIT_REMOTE_URL" | sed -e 's/.*github.com[\/:]//' -e 's/\.git$//')
if [ -z "$GITHUB_REPO" ]; then echo "❌ Error: Could not parse GitHub repo from URL: $GIT_REMOTE_URL"; exit 1; fi
echo "✅ Detected repository: $GITHUB_REPO"

# 6. Ensure local main branch is up-to-date
echo "🔄 Pulling latest changes for '$MAIN_BRANCH'..."
if ! git checkout "$MAIN_BRANCH" > /dev/null 2>&1 || ! git pull origin "$MAIN_BRANCH" > /dev/null 2>&1; then
    echo "❌ Error: Could not check out or pull latest from '$MAIN_BRANCH'."; exit 1
fi
echo "✅ '$MAIN_BRANCH' is up-to-date."

# 7. Find all commits related to the ticket from ALL sources
echo " gathering commits..."
# Use the canonical ticket ID for the search, and the -i flag for case-insensitivity.
MAIN_BRANCH_COMMITS=$(git log "$MAIN_BRANCH" --grep="$CANONICAL_TICKET_ID" -i --pretty=format:"%H")
REMOTE_REVIEW_BRANCH="origin/$REVIEW_BRANCH_NAME"
REMOTE_BRANCH_COMMITS=""
if git show-ref --verify --quiet "refs/remotes/$REMOTE_REVIEW_BRANCH"; then
    echo "  - Found existing remote review branch. Preserving its commits."
    REMOTE_BRANCH_COMMITS=$(git log "$REMOTE_REVIEW_BRANCH" --pretty=format:"%H")
else
    echo "  - No existing remote review branch found."
fi
COMMIT_HASHES=$( (echo "$MAIN_BRANCH_COMMITS"; echo "$REMOTE_BRANCH_COMMITS") | grep . | git rev-list --stdin --reverse --no-walk )
if [ -z "$COMMIT_HASHES" ]; then
  echo "⚠️ No commits found for Ticket ID '$CANONICAL_TICKET_ID'."
  exit 0
fi
echo "🔍 Found the following unique commits to be cherry-picked:"
COMMIT_ARRAY=("${(@f)COMMIT_HASHES}")
for hash in "${COMMIT_ARRAY[@]}"; do echo "  - $(git show -s --format='%h %s' "$hash")"; done

# 8. Determine the starting point for the new branch
FIRST_COMMIT_HASH="${COMMIT_ARRAY[1]}"
STARTING_POINT_HASH=$(git rev-parse "$FIRST_COMMIT_HASH^")
if [ -z "$STARTING_POINT_HASH" ]; then echo "❌ Error: Could not determine parent of first commit."; exit 1; fi
echo "🌱 Creating review branch from starting point: $(git show -s --format='%h %s' "$STARTING_POINT_HASH")"

# 9. Create or reset the review branch
if git show-ref --verify --quiet "refs/heads/$REVIEW_BRANCH_NAME"; then
  echo "♻️ Deleting existing local branch '$REVIEW_BRANCH_NAME' to rebuild it."
  git branch -D "$REVIEW_BRANCH_NAME"
fi
git checkout -b "$REVIEW_BRANCH_NAME" "$STARTING_POINT_HASH"
if [ $? -ne 0 ]; then echo "❌ Error: Failed to create new branch '$REVIEW_BRANCH_NAME'."; exit 1; fi

# 10. Cherry-pick the commits
echo "🍒 Cherry-picking commits onto '$REVIEW_BRANCH_NAME'..."
for hash in "${COMMIT_ARRAY[@]}"; do
  echo "  -> Picking $(git show -s --format='%h' "$hash")"
  if ! git cherry-pick -x "$hash"; then
    echo "❌ ERROR: Cherry-pick of $hash failed. Please resolve conflicts and re-run."
    echo "To abort: 'git cherry-pick --abort' then 'git checkout $MAIN_BRANCH'."
    exit 1
  fi
done
echo "✅ All commits successfully cherry-picked."

# 11. Push the branch to the remote
echo "📤 Force-pushing '$REVIEW_BRANCH_NAME' to origin..."
git push -f origin "$REVIEW_BRANCH_NAME"
if [ $? -ne 0 ]; then echo "❌ Error: Failed to push to origin."; exit 1; fi
echo "✅ Branch pushed successfully."

# 12. Find commit authors and map to GitHub users
echo "👥 Finding commit authors to assign to the PR..."
ASSIGNEES=()
for hash in "${COMMIT_ARRAY[@]}"; do
    login=$(gh api "repos/$GITHUB_REPO/commits/$hash" --jq '.author.login // empty')
    if [ -n "$login" ]; then
        ASSIGNEES+=("$login")
    else
        echo "  - Could not find a linked GitHub user for commit $hash"
    fi
done
UNIQUE_ASSIGNEES=("${(@u)ASSIGNEES}")
ASSIGNEE_STRING=$(echo ${(j:,:)UNIQUE_ASSIGNEES})

# 13. Create or update the Pull Request
echo "🔎 Checking for an existing Pull Request..."
EXISTING_PR_URL=$(gh pr list --repo "$GITHUB_REPO" --head "$REVIEW_BRANCH_NAME" --json url --jq '.[0].url' 2>/dev/null)

if [ -z "$EXISTING_PR_URL" ]; then
    echo "🤝 No existing PR found. Creating a new draft PR..."
    PR_TITLE="[REVIEW-ONLY] Feature: $CANONICAL_TICKET_ID"
    PR_BODY=$(cat <<EOF
This is an automatically generated, long-lived PR for reviewing all commits related to **$CANONICAL_TICKET_ID**. This PR should **NEVER** be merged.

---
*Want to use this script for your own reviews? [Install \`git-review\` from this gist](https://gist.github.com/schultzisaiah/f25734903c466454c4f385032d3eba47).*
EOF
)
    
    CREATE_ARGS=("--repo" "$GITHUB_REPO" "--draft" "--title" "$PR_TITLE" "--body" "$PR_BODY" "--head" "$REVIEW_BRANCH_NAME" "--base" "$MAIN_BRANCH")
    if [ -n "$ASSIGNEE_STRING" ]; then
        echo "  - Assigning users: $ASSIGNEE_STRING"
        CREATE_ARGS+=("--assignee" "$ASSIGNEE_STRING")
    fi
    
    NEW_PR_URL=$(gh pr create "${CREATE_ARGS[@]}")
    if [ $? -eq 0 ]; then echo "🎉 Success! New draft PR created at: $NEW_PR_URL"; else echo "❌ Error: Failed to create Pull Request."; fi
else
    echo "✅ Existing PR has been updated with the latest changes."
    if [ -n "$ASSIGNEE_STRING" ]; then
        CURRENT_ASSIGNEES=($(gh pr view "$EXISTING_PR_URL" --json assignees --jq '.assignees.[].login'))
        ASSIGNEES_TO_ADD=()
        for user in "${UNIQUE_ASSIGNEES[@]}"; do
            if ! printf '%s\n' "${CURRENT_ASSIGNEES[@]}" | grep -q -w "$user"; then
                ASSIGNEES_TO_ADD+=("$user")
            fi
        done
        
        if [ ${#ASSIGNEES_TO_ADD[@]} -gt 0 ]; then
            ADD_ASSIGNEE_STRING=$(echo ${(j:,:)ASSIGNEES_TO_ADD})
            echo "  - Adding new contributors as assignees: $ADD_ASSIGNEE_STRING"
            gh pr edit "$EXISTING_PR_URL" --add-assignee "$ADD_ASSIGNEE_STRING"
        else
            echo "  - All contributors are already assigned."
        fi
    fi
    echo "➡️  Review it here: $EXISTING_PR_URL"
fi

# Go back to the main branch for safety.
echo "↩️ Returning to '$MAIN_BRANCH' branch."
git checkout "$MAIN_BRANCH" > /dev/null 2>&1

