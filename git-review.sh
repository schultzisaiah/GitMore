#!/bin/zsh

# ---
# Git Long-Lived Review Script
# ---
#
# This script creates a "virtual" branch containing all commits for a specific
# ticket ID. It intelligently combines commits from main and the remote review
# branch, and then creates/updates a PR, auto-assigning commit authors.
#
# It also includes a self-updating mechanism and posts update comments to PRs.
#
# DEPENDENCIES:
# - git
# - GitHub CLI (gh). Install from: https://cli.github.com/
# - curl
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
# The URL to the raw script content for self-updating.
SCRIPT_URL="https://gist.githubusercontent.com/schultzisaiah/f25734903c466454c4f385032d3eba47/raw"

# --- Self-Update Function ---
checkForUpdates() {
    # Get the absolute path of the currently running script using a zsh-native method.
    local script_path="${(%):-%x}"
    # Create a temporary file to download the latest version.
    local temp_file=$(mktemp)

    # Download the latest version of the script with a 3-second timeout.
    if ! curl -sSL --max-time 3 "$SCRIPT_URL" -o "$temp_file"; then
        echo "⚠️  Warning: Could not check for script updates. Continuing..."
        rm "$temp_file"
        return
    fi

    # Check if there's a difference between the current script and the new one.
    if ! diff -q "$script_path" "$temp_file" >/dev/null; then
        echo "✨ A new version of this script is available."
        echo "   Updating now..."
        mv "$temp_file" "$script_path"
        chmod +x "$script_path"
        echo "✅ Script updated successfully. Please re-run your command."
        exit 0
    fi

    rm "$temp_file"
}

# --- Script Logic ---

# 1. Check for updates before doing anything else.
checkForUpdates

# 2. Input Validation
if [ -z "$1" ]; then
  echo "❌ Error: No Ticket ID provided."
  echo "Usage: $0 \"<TicketID>\" [MainBranch]"
  echo "Example: $0 \"AB#1234\""
  exit 1
fi

# 3. Input Processing and Normalization
echo "⚙️  Normalizing Ticket ID..."
TICKET_NUMBER=$(echo "$1" | tr -dc '0-9')
if [ -z "$TICKET_NUMBER" ]; then
    echo "❌ Error: Could not find any numbers in the provided Ticket ID '$1'."
    exit 1
fi
CANONICAL_TICKET_ID="${TICKET_PREFIX}${TICKET_NUMBER}"
SANITIZED_TICKET_ID=$(echo "$CANONICAL_TICKET_ID" | sed 's/[^a-zA-Z0-9]/-/g')
REVIEW_BRANCH_NAME="$REVIEW_BRANCH_PREFIX/$SANITIZED_TICKET_ID"

echo "🚀 Starting review preparation for Ticket ID: $CANONICAL_TICKET_ID"
echo "🌿 Review branch will be: $REVIEW_BRANCH_NAME"

# 4. Pre-flight Checks
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ Error: Your workspace has uncommitted changes."
  echo "Please commit, stash, or discard your changes before running this script."
  exit 1
fi
# Check for all required dependencies at once.
local missing_deps=()
if ! command -v git &> /dev/null; then missing_deps+=("git"); fi
if ! command -v curl &> /dev/null; then missing_deps+=("curl"); fi
if ! command -v gh &> /dev/null; then missing_deps+=("GitHub CLI ('gh')"); fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "❌ Error: The following required dependencies are not installed:"
    for dep in "${missing_deps[@]}"; do
        echo "  - $dep"
    done
    echo "Please install them to continue. The GitHub CLI can be found at https://cli.github.com/"
    exit 1
fi
echo "✅ Workspace is clean. Dependencies are met."

# 5. Determine Main Branch
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

# 6. Auto-detect GitHub Repo
echo "🔎 Auto-detecting GitHub repository..."
GIT_REMOTE_URL=$(git remote get-url origin 2>/dev/null)
if [ -z "$GIT_REMOTE_URL" ]; then echo "❌ Error: Could not determine the remote 'origin' URL."; exit 1; fi
GITHUB_REPO=$(echo "$GIT_REMOTE_URL" | sed -e 's/.*github.com[\/:]//' -e 's/\.git$//')
if [ -z "$GITHUB_REPO" ]; then echo "❌ Error: Could not parse GitHub repo from URL: $GIT_REMOTE_URL"; exit 1; fi
echo "✅ Detected repository: $GITHUB_REPO"

# 7. Ensure local main branch is up-to-date
echo "🔄 Pulling latest changes for '$MAIN_BRANCH'..."
if ! git checkout "$MAIN_BRANCH" > /dev/null 2>&1 || ! git pull origin "$MAIN_BRANCH" > /dev/null 2>&1; then
    echo "❌ Error: Could not check out or pull latest from '$MAIN_BRANCH'."; exit 1
fi
echo "✅ '$MAIN_BRANCH' is up-to-date."

# 8. Find all commits related to the ticket from ALL sources
echo " gathering commits..."
# Source 1: Tagged commits from the main branch
MAIN_BRANCH_COMMITS=(${(f)"$(git log "$MAIN_BRANCH" --grep="$CANONICAL_TICKET_ID" -i --pretty=format:"%H")"})

# Source 2: All commits from an existing review branch (if it exists)
REMOTE_REVIEW_BRANCH="origin/$REVIEW_BRANCH_NAME"
REMOTE_BRANCH_COMMITS=()
OLD_HEAD=$(git rev-parse "$REMOTE_REVIEW_BRANCH" 2>/dev/null)
if [ -n "$OLD_HEAD" ]; then
    echo "  - Found existing remote review branch. Preserving its commits."
    MERGE_BASE=$(git merge-base "$MAIN_BRANCH" "$REMOTE_REVIEW_BRANCH")
    if [ -n "$MERGE_BASE" ]; then
        REMOTE_BRANCH_COMMITS=(${(f)"$(git log "$MERGE_BASE..$REMOTE_REVIEW_BRANCH" --pretty=format:"%H")"})
    fi
else
    echo "  - No existing remote review branch found."
fi

# Combine all potential commit hashes
ALL_CANDIDATE_HASHES=("${MAIN_BRANCH_COMMITS[@]}" "${REMOTE_BRANCH_COMMITS[@]}")

# De-duplicate commits based on their content (patch-id) to prevent re-picking the same change.
typeset -A patch_ids_to_hashes
for hash in "${ALL_CANDIDATE_HASHES[@]}"; do
    if [ -z "$hash" ]; then continue; fi
    patch_id=$(git show "$hash" | git patch-id | cut -d' ' -f1)
    if [[ ! -v patch_ids_to_hashes[$patch_id] ]] || [[ " ${MAIN_BRANCH_COMMITS[@]} " =~ " ${hash} " ]]; then
        patch_ids_to_hashes[$patch_id]=$hash
    fi
done

UNIQUE_HASHES=("${(@v)patch_ids_to_hashes}")
if [ ${#UNIQUE_HASHES[@]} -eq 0 ]; then
  echo "⚠️ No commits found for Ticket ID '$CANONICAL_TICKET_ID'."
  exit 0
fi

# Sort the unique commits chronologically.
COMMIT_HASHES=$(echo "${UNIQUE_HASHES[@]}" | tr ' ' '\n' | git rev-list --stdin --reverse --no-walk)
COMMIT_ARRAY=("${(@f)COMMIT_HASHES}")

# --- "No Changes" Check ---
# If an old branch existed, compare its content to what we've just calculated.
if [ -n "$OLD_HEAD" ]; then
    typeset -A old_patch_ids
    for hash in "${REMOTE_BRANCH_COMMITS[@]}"; do
        if [ -z "$hash" ]; then continue; fi
        old_patch_ids[$(git show "$hash" | git patch-id | cut -d' ' -f1)]=1
    done

    # If the number of unique patches is the same, and all old patches are present in the new set,
    # then no content has changed.
    all_found=true
    if [ ${#UNIQUE_HASHES[@]} -eq ${#old_patch_ids[@]} ]; then
        for patch_id in ${(k)old_patch_ids}; do
            if [[ ! -v patch_ids_to_hashes[$patch_id] ]]; then
                all_found=false
                break
            fi
        done
    else
        all_found=false
    fi

    if $all_found; then
        echo "✅ No content changes detected in the review branch. Nothing to do."
        git checkout "$MAIN_BRANCH" > /dev/null 2>&1
        exit 0
    fi
fi

echo "🔍 Found ${#COMMIT_ARRAY[@]} unique commits to be included in the review:"
for hash in "${COMMIT_ARRAY[@]}"; do echo "  - $(git show -s --format='%h %s' "$hash")"; done

# 9. Determine the starting point for the new branch
FIRST_COMMIT_HASH="${COMMIT_ARRAY[1]}"
STARTING_POINT_HASH=$(git rev-parse "$FIRST_COMMIT_HASH^")
if [ -z "$STARTING_POINT_HASH" ]; then echo "❌ Error: Could not determine parent of first commit."; exit 1; fi
echo "🌱 Creating review branch from starting point: $(git show -s --format='%h %s' "$STARTING_POINT_HASH")"

# 10. Create or reset the review branch
if git show-ref --verify --quiet "refs/heads/$REVIEW_BRANCH_NAME"; then
  echo "♻️ Deleting existing local branch '$REVIEW_BRANCH_NAME' to rebuild it."
  git branch -D "$REVIEW_BRANCH_NAME"
fi
git checkout -b "$REVIEW_BRANCH_NAME" "$STARTING_POINT_HASH"
if [ $? -ne 0 ]; then echo "❌ Error: Failed to create new branch '$REVIEW_BRANCH_NAME'."; exit 1; fi

# 11. Cherry-pick the commits
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

# 12. Push the branch to the remote
echo "📤 Force-pushing '$REVIEW_BRANCH_NAME' to origin..."
git push -f origin "$REVIEW_BRANCH_NAME"
if [ $? -ne 0 ]; then echo "❌ Error: Failed to push to origin."; exit 1; fi
echo "✅ Branch pushed successfully."
NEW_HEAD=$(git rev-parse "$REVIEW_BRANCH_NAME")

# 13. Find commit authors and map to GitHub users
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

# 14. Create or update the Pull Request
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
    
    # Post an update comment to the PR
    if [ -n "$OLD_HEAD" ]; then
        echo "📝 Posting an update comment to the PR..."
        
        # Find newly added commits by comparing content (patch-id)
        typeset -A old_patch_ids_comment
        for hash in "${REMOTE_BRANCH_COMMITS[@]}"; do
            if [ -z "$hash" ]; then continue; fi
            old_patch_ids_comment[$(git show "$hash" | git patch-id | cut -d' ' -f1)]=1
        done

        NEWLY_ADDED_COMMITS=()
        for hash in "${COMMIT_ARRAY[@]}"; do
            patch_id=$(git show "$hash" | git patch-id | cut -d' ' -f1)
            if [[ ! -v old_patch_ids_comment[$patch_id] ]]; then
                NEWLY_ADDED_COMMITS+=("$hash")
            fi
        done

        # Construct the comment body with real newlines
        COMMENT_BODY="**🤖 Review Update**

This review branch has been updated. The link below provides a visual diff of all file changes in this update.

* [**View file changes**](https://github.com/$GITHUB_REPO/compare/$OLD_HEAD...$NEW_HEAD)
  *Note: The commit list in the comparison view may be noisy due to the branch being rebuilt. The list of new commits below is the most accurate summary of what was added.*"

        if [ ${#NEWLY_ADDED_COMMITS[@]} -gt 0 ]; then
            COMMENT_BODY+="

**New commits added in this update:**
"
            for hash in "${NEWLY_ADDED_COMMITS[@]}"; do
                commit_line=$(git show -s --format='* `%h` %s' "$hash")
                COMMENT_BODY+="${commit_line}
"
            done
        else
            COMMENT_BODY+="

No new commits were added, but the branch was rebuilt (e.g., to resolve conflicts or reorder commits)."
        fi
        
        gh pr comment "$EXISTING_PR_URL" --body "$COMMENT_BODY"
    fi
    
    # Update assignees
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

