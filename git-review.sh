#!/bin/zsh

# ---
# Git Long-Lived Review Script
# ---
#
# This script creates a "virtual" branch containing all commits for a specific
# ticket ID. It intelligently combines tagged commits from the main branch with
# any manually-added commits already on the remote review branch.
#
# DEPENDENCIES:
# - git
# - GitHub CLI (gh). Install from: https://cli.github.com/
#
# SETUP:
# 1. Save this script as 'git-review' (no file extension) in a directory on your PATH.
# 2. Make it executable: `chmod +x git-review`
# 3. Run `gh auth login` once to authenticate the GitHub CLI.
#
# USAGE:
# git-review <TicketID> [MainBranch]
#
# EXAMPLES:
# git-review "AB#1234"
# git-review "AB#5678" develop
#

# --- Configuration ---
# The prefix for the review branches.
REVIEW_BRANCH_PREFIX="CR"


# --- Script Logic ---

# 1. Input Validation
if [ -z "$1" ]; then
  echo "❌ Error: No Ticket ID provided."
  echo "Usage: $0 \"<TicketID>\" [MainBranch]"
  echo "Example: $0 \"AB#1234\""
  exit 1
fi

TICKET_ID="$1"
SANITIZED_TICKET_ID=$(echo "$TICKET_ID" | sed 's/[^a-zA-Z0-9]/-/g')
REVIEW_BRANCH_NAME="$REVIEW_BRANCH_PREFIX/$SANITIZED_TICKET_ID"

echo "🚀 Starting review preparation for Ticket ID: $TICKET_ID"
echo "🌿 Review branch will be: $REVIEW_BRANCH_NAME"

# 2. Determine Main Branch
MAIN_BRANCH=""
if [ -n "$2" ]; then
    MAIN_BRANCH="$2"
    echo "➡️ Using specified main branch: $MAIN_BRANCH"
else
    echo "🔎 Auto-detecting main branch (checking for 'main' or 'master')..."
    # Fetch first to ensure remote refs are up-to-date for detection
    git fetch origin
    if git show-ref --verify --quiet refs/remotes/origin/main; then
        MAIN_BRANCH="main"
        echo "✅ Detected 'main' as the primary branch."
    elif git show-ref --verify --quiet refs/remotes/origin/master; then
        MAIN_BRANCH="master"
        echo "✅ Detected 'master' as the primary branch."
    fi
fi

if [ -z "$MAIN_BRANCH" ]; then
    echo "❌ Error: Could not auto-detect 'main' or 'master' branch from remote 'origin'."
    echo "Please specify your main branch name as the second argument."
    echo "Usage: $0 \"<TicketID>\" <main-branch-name>"
    exit 1
fi

# 3. Auto-detect GitHub Repo
echo "🔎 Auto-detecting GitHub repository..."
GIT_REMOTE_URL=$(git remote get-url origin 2>/dev/null)
if [ -z "$GIT_REMOTE_URL" ]; then
    echo "❌ Error: Could not determine the remote 'origin' URL."
    exit 1
fi
GITHUB_REPO=$(echo "$GIT_REMOTE_URL" | sed -e 's/.*github.com[\/:]//' -e 's/\.git$//')
if [ -z "$GITHUB_REPO" ]; then
    echo "❌ Error: Could not parse the GitHub repository from the remote URL: $GIT_REMOTE_URL"
    exit 1
fi
echo "✅ Detected repository: $GITHUB_REPO"

# 4. Dependency Check
if ! command -v gh &> /dev/null; then
    echo "❌ Error: The GitHub CLI ('gh') is not installed. Please install from https://cli.github.com/"
    exit 1
fi

# 5. Ensure local main branch is up-to-date
echo "🔄 Pulling latest changes for '$MAIN_BRANCH'..."
if ! git checkout "$MAIN_BRANCH" > /dev/null 2>&1 || ! git pull origin "$MAIN_BRANCH" > /dev/null 2>&1; then
    echo "❌ Error: Could not check out or pull latest from '$MAIN_BRANCH'."
    exit 1
fi
echo "✅ '$MAIN_BRANCH' is up-to-date."

# 6. Find all commits related to the ticket from ALL sources
echo " gathering commits..."

# Get commits from main branch with the tag
MAIN_BRANCH_COMMITS=$(git log "$MAIN_BRANCH" --grep="$TICKET_ID" --pretty=format:"%H")

# Get commits from the remote review branch, if it exists
REMOTE_REVIEW_BRANCH="origin/$REVIEW_BRANCH_NAME"
REMOTE_BRANCH_COMMITS=""
if git show-ref --verify --quiet "refs/remotes/$REMOTE_REVIEW_BRANCH"; then
    echo "  - Found existing remote review branch. Preserving its commits."
    REMOTE_BRANCH_COMMITS=$(git log "$REMOTE_REVIEW_BRANCH" --pretty=format:"%H")
else
    echo "  - No existing remote review branch found."
fi

# Combine, de-duplicate, and chronologically sort all discovered commits
# `git rev-list --stdin --reverse` is the key to sorting the combined list correctly.
COMMIT_HASHES=$( (echo "$MAIN_BRANCH_COMMITS"; echo "$REMOTE_BRANCH_COMMITS") | \
                 grep . | \
                 git rev-list --stdin --reverse --no-walk )


if [ -z "$COMMIT_HASHES" ]; then
  echo "⚠️ No commits found for Ticket ID '$TICKET_ID' on '$MAIN_BRANCH' or in a remote review branch."
  exit 0
fi

echo "🔍 Found the following unique commits to be cherry-picked:"
readarray -t COMMIT_ARRAY <<< "$COMMIT_HASHES"
for hash in "${COMMIT_ARRAY[@]}"; do
  echo "  - $(git show -s --format='%h %s' "$hash")"
done

# 7. Determine the starting point for the new branch
FIRST_COMMIT_HASH="${COMMIT_ARRAY[0]}"
STARTING_POINT_HASH=$(git rev-parse "$FIRST_COMMIT_HASH^")

if [ -z "$STARTING_POINT_HASH" ]; then
    echo "❌ Error: Could not determine the parent of the first commit ($FIRST_COMMIT_HASH)."
    exit 1
fi

echo "🌱 Creating review branch from starting point: $(git show -s --format='%h %s' "$STARTING_POINT_HASH")"

# 8. Create or reset the review branch
if git show-ref --verify --quiet "refs/heads/$REVIEW_BRANCH_NAME"; then
  echo "♻️ Deleting existing local branch '$REVIEW_BRANCH_NAME' to rebuild it."
  git branch -D "$REVIEW_BRANCH_NAME"
fi
git checkout -b "$REVIEW_BRANCH_NAME" "$STARTING_POINT_HASH"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to create new branch '$REVIEW_BRANCH_NAME' from '$STARTING_POINT_HASH'."
    exit 1
fi

# 9. Cherry-pick the commits
echo "🍒 Cherry-picking commits onto '$REVIEW_BRANCH_NAME'..."
for hash in "${COMMIT_ARRAY[@]}"; do
  echo "  -> Picking $(git show -s --format='%h' "$hash")"
  if ! git cherry-pick -x "$hash"; then
    echo "❌ ERROR: Cherry-pick of $hash failed."
    echo "A merge conflict likely occurred. Please resolve it manually and re-run the script."
    echo "To abort: 'git cherry-pick --abort' then 'git checkout $MAIN_BRANCH'."
    exit 1
  fi
done
echo "✅ All commits successfully cherry-picked."

# 10. Push the branch to the remote
echo "📤 Force-pushing '$REVIEW_BRANCH_NAME' to origin..."
git push -f origin "$REVIEW_BRANCH_NAME"
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to push to origin."
    exit 1
fi
echo "✅ Branch pushed successfully."

# 11. Create or update the Pull Request
echo "🔎 Checking for an existing Pull Request..."
EXISTING_PR_URL=$(gh pr list --repo "$GITHUB_REPO" --head "$REVIEW_BRANCH_NAME" --json url --jq '.[0].url' 2>/dev/null)

if [ -z "$EXISTING_PR_URL" ]; then
    echo "🤝 No existing PR found. Creating a new draft PR..."
    PR_TITLE="[REVIEW-ONLY] Feature: $TICKET_ID"
    PR_BODY="This is an automatically generated, long-lived PR for reviewing all commits related to **$TICKET_ID**. This PR should **NEVER** be merged."
    
    NEW_PR_URL=$(gh pr create \
        --repo "$GITHUB_REPO" --draft --title "$PR_TITLE" --body "$PR_BODY" \
        --head "$REVIEW_BRANCH_NAME" --base "$MAIN_BRANCH")
    
    if [ $? -eq 0 ]; then
        echo "🎉 Success! New draft PR created at: $NEW_PR_URL"
    else
        echo "❌ Error: Failed to create Pull Request."
    fi
else
    echo "✅ Existing PR has been updated with the latest changes."
    echo "➡️  Review it here: $EXISTING_PR_URL"
fi

# Go back to the main branch for safety.
echo "↩️ Returning to '$MAIN_BRANCH' branch."
git checkout "$MAIN_BRANCH" > /dev/null 2>&1

