#!/bin/zsh

# ---
# Git Long-Lived Review Script
# ---
#
# This script creates a "virtual" branch containing all commits for a specific
# ticket ID. It intelligently combines commits from main and the remote review
# branch, and then creates/updates a PR, auto-assigning commit authors and
# linking to related PRs in other repositories.
#
# It also includes a self-updating mechanism and updates the PR body on changes.
#
# DEPENDENCIES:
# - git
# - GitHub CLI (gh). Install from: https://cli.github.com/
# - curl
#
# SETUP:
# 1. Save this script as 'git-review' (no file extension) in a directory on your PATH.
# 2. Make it executable: `chmod +x git-review`
# 3. Run `gh auth login` once to authenticate the GitHub CLI.
#
# USAGE:
# git-review <TicketID> [MainBranch]
# git-review --update
#
# EXAMPLES:
# git-review "AB#1234"
# git-review "#5678"
# git-review "ab5678" develop
# git-review --update
#

# --- Configuration ---
# The prefix for the review branches.
REVIEW_BRANCH_PREFIX="CR"
# The standard prefix for your tickets, including any separator.
# Example: "AB#", "JIRA-", "TICKET-"
TICKET_PREFIX="AB#"
# The URL to the raw script content for self-updating.
SCRIPT_URL="https://raw.githubusercontent.com/schultzisaiah/GitMore/refs/heads/main/scripts/git-review.sh"
# Set to 'true' to allow git hooks (e.g., pre-commit, pre-push) to run.
# Set to 'false' to bypass hooks for script operations using '--no-verify'.
GIT_HOOKS_ENABLED=false


# --- Self-Update Function ---
checkForUpdates() {
    local force_check=$1
    local update_url="$SCRIPT_URL"

    if [ "$force_check" = "true" ]; then
        local check_message="🚀 Force-checking for script updates..."
        # Append a cache-busting query parameter using the current Unix timestamp.
        update_url="${SCRIPT_URL}?cb=$(date +%s)"
    fi

    # Only print the "checking" message on a forced run.
    if [ "$force_check" = "true" ]; then
        echo "$check_message"
    fi

    # Get the absolute path of the currently running script using a zsh-native method.
    local script_path="${(%):-%x}"
    # Create a temporary file to download the latest version.
    local temp_file=$(mktemp)

    # Download the latest version of the script with a 3-second timeout.
    if ! curl -sSL --max-time 3 "$update_url" -o "$temp_file"; then
        # Only show a warning on a normal run. On a forced run, it's an error.
        if [ "$force_check" = "true" ]; then
            echo "❌ Error: Could not download script from $update_url"
            rm "$temp_file"
            exit 1
        else
            echo "⚠️  Warning: Could not check for script updates. Continuing..."
            rm "$temp_file"
            return
        fi
    fi

    # Check if there's a difference between the current script and the new one.
    if ! diff -q "$script_path" "$temp_file" >/dev/null; then
        echo "✨ A new version of this script is available."
        echo "   Updating now..."
        mv "$temp_file" "$script_path"
        chmod +x "$script_path"
        echo "✅ Script updated successfully. Please re-run your command."
        exit 0
    else
        # If this was a forced check, notify the user they're up-to-date.
        if [ "$force_check" = "true" ]; then
            echo "✅ You are already running the latest version."
        fi
    fi

    rm "$temp_file"
}

# --- Script Logic ---

# 1. Handle flags like --update or perform a standard update check.
if [ "$1" = "--update" ]; then
  checkForUpdates true
  exit 0
fi
# On normal runs, quietly check for updates.
checkForUpdates

# 2. Input Validation
if [ -z "$1" ]; then
  echo "❌ Error: No Ticket ID provided."
  echo "Usage: $0 \"<TicketID>\" [MainBranch]"
  echo "   or: $0 --update"
  echo "Example: $0 \"AB#1234\""
  exit 1
fi

# 3. Setup Git Hook Flag
GIT_NO_VERIFY_FLAG=""
if ! $GIT_HOOKS_ENABLED; then
  GIT_NO_VERIFY_FLAG="--no-verify"
fi

# 4. Input Processing and Normalization
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

# 5. Pre-flight Checks
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

# 6. Determine Main Branch
MAIN_BRANCH=""
if [ -n "$2" ]; then
    MAIN_BRANCH="$2"
    echo "➡️ Using specified main branch: $MAIN_BRANCH"
else
    echo "🔎 Auto-detecting default branch from remote 'origin'..."
    # Fetch with --prune to remove stale remote-tracking branches.
    git fetch origin --prune
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

# 7. Auto-detect GitHub Repo
echo "🔎 Auto-detecting GitHub repository..."
GIT_REMOTE_URL=$(git remote get-url origin 2>/dev/null)
if [ -z "$GIT_REMOTE_URL" ]; then echo "❌ Error: Could not determine the remote 'origin' URL."; exit 1; fi
GITHUB_REPO=$(echo "$GIT_REMOTE_URL" | sed -e 's/.*github.com[\/:]//' -e 's/\.git$//')
if [ -z "$GITHUB_REPO" ]; then echo "❌ Error: Could not parse GitHub repo from URL: $GIT_REMOTE_URL"; exit 1; fi
GITHUB_ORG=$(echo $GITHUB_REPO | cut -d'/' -f1)
echo "✅ Detected repository: $GITHUB_REPO"

# 8. Ensure local main branch is up-to-date
echo "🔄 Pulling latest changes for '$MAIN_BRANCH'..."
if ! git checkout "$MAIN_BRANCH" > /dev/null 2>&1 || ! git pull origin "$MAIN_BRANCH" > /dev/null 2>&1; then
    echo "❌ Error: Could not check out or pull latest from '$MAIN_BRANCH'."; exit 1
fi
echo "✅ '$MAIN_BRANCH' is up-to-date."

# 9. Find all commits related to the ticket from ALL sources
echo " gathering commits..."
# Source 1: Tagged commits from the main branch
MAIN_BRANCH_COMMITS=(${(f)"$(git log "$MAIN_BRANCH" --grep="$CANONICAL_TICKET_ID" -i --pretty=format:"%H")"})

# Source 2: All commits from an existing review branch (if it exists)
REMOTE_REVIEW_BRANCH="origin/$REVIEW_BRANCH_NAME"
REMOTE_BRANCH_COMMITS_RAW=()
OLD_HEAD=$(git rev-parse "$REMOTE_REVIEW_BRANCH" 2>/dev/null)
if [ -n "$OLD_HEAD" ]; then
    echo "  - Found existing remote review branch. Preserving its commits."
    MERGE_BASE=$(git merge-base "$MAIN_BRANCH" "$REMOTE_REVIEW_BRANCH")
    if [ -n "$MERGE_BASE" ]; then
        REMOTE_BRANCH_COMMITS_RAW=(${(f)"$(git log "$MERGE_BASE..$REMOTE_REVIEW_BRANCH" --pretty=format:"%H")"})
    fi
else
    echo "  - No existing remote review branch found."
fi

# Combine all potential commit hashes into a single pool
ALL_CANDIDATE_HASHES=("${MAIN_BRANCH_COMMITS[@]}" "${REMOTE_BRANCH_COMMITS_RAW[@]}")

# De-duplicate commits based on their content (patch-id) to prevent re-picking the same change.
typeset -A patch_ids_to_hashes
for hash in "${ALL_CANDIDATE_HASHES[@]}"; do
    if [ -z "$hash" ]; then continue; fi
    patch_id=$(git show "$hash" | git patch-id | cut -d' ' -f1)
    # Prefer the original commit from the main branch if a content collision occurs.
    is_from_main=false
    for main_hash in "${MAIN_BRANCH_COMMITS[@]}"; do
        if [[ "$main_hash" == "$hash" ]]; then
            is_from_main=true
            break
        fi
    done

    if [[ ! -v patch_ids_to_hashes[$patch_id] ]] || $is_from_main; then
        patch_ids_to_hashes[$patch_id]=$hash
    fi
done

UNIQUE_HASHES=("${(@v)patch_ids_to_hashes}")
if [ ${#UNIQUE_HASHES[@]} -eq 0 ]; then
  echo "⚠️ No commits found for Ticket ID '$CANONICAL_TICKET_ID' after filtering."
  # If an old branch existed, we need to update it to be empty.
  if [ -n "$OLD_HEAD" ]; then
    echo "  - The feature appears to have been fully reverted. Updating review branch..."
  else
    exit 0
  fi
fi

# Sort the unique commits chronologically.
COMMIT_HASHES=$(echo "${UNIQUE_HASHES[@]}" | tr ' ' '\n' | git rev-list --stdin --reverse --no-walk)
COMMIT_ARRAY=("${(@f)COMMIT_HASHES}")

# --- "No Changes" Check ---
# If an old branch existed, compare its content to what we've just calculated.
if [ -n "$OLD_HEAD" ]; then
    typeset -A old_patch_ids
    for hash in "${REMOTE_BRANCH_COMMITS_RAW[@]}"; do
        if [ -z "$hash" ]; then continue; fi
        old_patch_ids[$(git show "$hash" | git patch-id | cut -d' ' -f1)]=1
    done

    typeset -A new_patch_ids
    for hash in "${COMMIT_ARRAY[@]}"; do
        if [ -z "$hash" ]; then continue; fi
        new_patch_ids[$(git show "$hash" | git patch-id | cut -d' ' -f1)]=1
    done

    all_found=true
    if [ ${#new_patch_ids[@]} -eq ${#old_patch_ids[@]} ]; then
        for patch_id in ${(k)old_patch_ids}; do
            if [[ ! -v new_patch_ids[$patch_id] ]]; then
                all_found=false
                break
            fi
        done
    else
        all_found=false
    fi

    if $all_found; then
        echo "✅ No content changes detected in the review branch. Nothing to do."
        # Even if no code changes, we'll still run the cross-linking logic to ensure all PRs are in sync.
    fi
fi

echo "🔍 Found ${#COMMIT_ARRAY[@]} unique commits to be included in the review:"
for hash in "${COMMIT_ARRAY[@]}"; do echo "  - $(git show -s --format='%h %s' "$hash")"; done

# 10. Determine the starting point for the new branch
# Handle case where all commits were reverted
if [ ${#COMMIT_ARRAY[@]} -eq 0 ]; then
    # If no commits are left, we can't create a branch. We'll push an empty one later.
    STARTING_POINT_HASH=$MAIN_BRANCH
else
    FIRST_COMMIT_HASH="${COMMIT_ARRAY[1]}"
    STARTING_POINT_HASH=$(git rev-parse "$FIRST_COMMIT_HASH^")
fi

if [ -z "$STARTING_POINT_HASH" ]; then echo "❌ Error: Could not determine a starting point for the branch."; exit 1; fi
echo "🌱 Creating review branch from starting point: $(git show -s --format='%h %s' "$STARTING_POINT_HASH")"

# 11. Create or reset the review branch
if git show-ref --verify --quiet "refs/heads/$REVIEW_BRANCH_NAME"; then
  echo "♻️ Deleting existing local branch '$REVIEW_BRANCH_NAME' to rebuild it."
  git branch -D "$REVIEW_BRANCH_NAME"
fi
git checkout -b "$REVIEW_BRANCH_NAME" "$STARTING_POINT_HASH"
if [ $? -ne 0 ]; then echo "❌ Error: Failed to create new branch '$REVIEW_BRANCH_NAME'."; exit 1; fi

# 12. Cherry-pick the commits
if [ ${#COMMIT_ARRAY[@]} -gt 0 ]; then
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
else
    echo "✅ No commits to cherry-pick. The branch will be empty of this feature's changes."
fi

# 13. Map original commit hashes to their new cherry-picked hashes
typeset -A original_to_new_hash_map
if [ ${#COMMIT_ARRAY[@]} -gt 0 ]; then
    echo "🗺️  Mapping new commit hashes to original hashes..."
    # Get the list of newly created hashes on this branch, in chronological order.
    NEW_HASHES_ON_BRANCH=(${(f)"$(git log "$STARTING_POINT_HASH..HEAD" --reverse --pretty=format:"%H")"})
    # Create a map from original hash to the new cherry-picked hash.
    for i in {1..${#COMMIT_ARRAY[@]}}; do
        original_to_new_hash_map[${COMMIT_ARRAY[i]}]=${NEW_HASHES_ON_BRANCH[i]}
    done
fi

# 14. Push the branch to the remote
echo "📤 Force-pushing '$REVIEW_BRANCH_NAME' to origin..."
if ! $GIT_HOOKS_ENABLED; then
  echo "🤫 Git hooks are disabled for this script's operations (using --no-verify)."
fi
git push -f $GIT_NO_VERIFY_FLAG origin "$REVIEW_BRANCH_NAME"
if [ $? -ne 0 ]; then echo "❌ Error: Failed to push to origin."; exit 1; fi
echo "✅ Branch pushed successfully."
NEW_HEAD=$(git rev-parse "$REVIEW_BRANCH_NAME")

# 15. Find commit authors and map to GitHub users
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

# 16. Create or update the Pull Request
echo "🔎 Checking for an existing Pull Request..."
EXISTING_PR_URL=$(gh pr list --repo "$GITHUB_REPO" --head "$REVIEW_BRANCH_NAME" --json url --jq '.[0].url' 2>/dev/null)

PR_BODY_HEADER=$(cat <<EOF
This is an automatically generated, long-lived PR for reviewing all commits related to **$CANONICAL_TICKET_ID**. This PR should **NEVER** be merged.

---
*Want to use this script for your own reviews? [Install \`git-review\` from this repo](https://github.com/schultzisaiah/GitMore/blob/main/scripts/git-review.sh).*
EOF
)

if [ -z "$EXISTING_PR_URL" ]; then
    echo "🤝 No existing PR found. Creating a new draft PR..."
    PR_TITLE="[REVIEW-ONLY] Feature: $CANONICAL_TICKET_ID"

    # --- Construct PR Body for NEW PR ---
    COMMIT_LIST_BODY=""
    if [ ${#COMMIT_ARRAY[@]} -gt 0 ]; then
        COMMIT_LIST_BODY+="

---

### Commits Included in this Review

| Date & Time (UTC) | Commit | Description |
|---|---|---|
"
        for hash in "${COMMIT_ARRAY[@]}"; do
            commit_info=$(git show -s --format='%ci|%h|%s' "$hash")
            commit_date_full=$(echo "$commit_info" | cut -d'|' -f1)
            commit_datetime_utc=$(echo "$commit_date_full" | cut -d' ' -f1,2)
            commit_hash_short=$(echo "$commit_info" | cut -d'|' -f2)
            commit_subject=$(echo "$commit_info" | cut -d'|' -f3)
            new_hash_for_link=${original_to_new_hash_map[$hash]}
            # Use the canonical commit link since the PR doesn't exist yet, but with the NEW hash.
            commit_link="[\`${commit_hash_short}\`](https://github.com/$GITHUB_REPO/commit/${new_hash_for_link})"
            COMMIT_LIST_BODY+="${commit_datetime_utc}|${commit_link}|${commit_subject}
"
        done
    fi
    FINAL_PR_BODY="${PR_BODY_HEADER}${COMMIT_LIST_BODY}"

    CREATE_ARGS=("--repo" "$GITHUB_REPO" "--draft" "--title" "$PR_TITLE" "--body" "$FINAL_PR_BODY" "--head" "$REVIEW_BRANCH_NAME" "--base" "$MAIN_BRANCH")
    if [ -n "$ASSIGNEE_STRING" ]; then
        echo "  - Assigning users: $ASSIGNEE_STRING"
        CREATE_ARGS+=("--assignee" "$ASSIGNEE_STRING")
    fi

    NEW_PR_URL=$(gh pr create "${CREATE_ARGS[@]}")
    if [ $? -eq 0 ]; then
        echo "🎉 Success! New draft PR created at: $NEW_PR_URL"
        EXISTING_PR_URL=$NEW_PR_URL # Set this so the cross-linking step runs
    else
        echo "❌ Error: Failed to create Pull Request."
    fi
else
    echo "✅ Existing PR has been updated with the latest changes."

    # --- Construct PR Body for EXISTING PR ---
    PR_NUMBER=$(gh pr view "$EXISTING_PR_URL" --json number --jq '.number')
    COMMIT_LIST_BODY=""
    if [ ${#COMMIT_ARRAY[@]} -gt 0 ]; then
        COMMIT_LIST_BODY+="

---

### Commits Included in this Review

| Date & Time (UTC) | Commit | Description |
|---|---|---|
"
        for hash in "${COMMIT_ARRAY[@]}"; do
            commit_info=$(git show -s --format='%ci|%H|%h|%s' "$hash")
            commit_date_full=$(echo "$commit_info" | cut -d'|' -f1)
            commit_datetime_utc=$(echo "$commit_date_full" | cut -d' ' -f1,2)
            commit_hash_full=$(echo "$commit_info" | cut -d'|' -f2)
            commit_hash_short=$(echo "$commit_info" | cut -d'|' -f3)
            commit_subject=$(echo "$commit_info" | cut -d'|' -f4)
            new_hash_for_link=${original_to_new_hash_map[$hash]}
            # Use the PR-specific commit link now that we have the PR number, with the NEW hash.
            commit_link="[\`${commit_hash_short}\`](https://github.com/$GITHUB_REPO/pull/${PR_NUMBER}/commits/${new_hash_for_link})"
            COMMIT_LIST_BODY+="${commit_datetime_utc}|${commit_link}|${commit_subject}
"
        done
    fi
    FINAL_PR_BODY="${PR_BODY_HEADER}${COMMIT_LIST_BODY}"

    echo "📝 Updating the PR body with the latest commit list..."
    gh pr edit "$EXISTING_PR_URL" --body "$FINAL_PR_BODY"

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

# 17. Find and link related PRs across the organization
if [ -n "$EXISTING_PR_URL" ]; then
    echo "🔗 Searching for related PRs in the '$GITHUB_ORG' organization..."
    # Search for open PRs in the org that contain the ticket ID.
    RELATED_PRS=(${(f)"$(gh search prs --owner "$GITHUB_ORG" "$CANONICAL_TICKET_ID" --state open --json url --jq '.[] | .url')"})

    RELATED_REVIEWS_MARKER="

---

### Related Reviews"

    RELATED_PRS_BODY=""
    if [ ${#RELATED_PRS[@]} -gt 1 ]; then
        echo "  - Found ${#RELATED_PRS[@]} related PRs. Updating them with links..."

        RELATED_PRS_BODY+="${RELATED_REVIEWS_MARKER}
"
        for pr_url in "${RELATED_PRS[@]}"; do
            RELATED_PRS_BODY+="* $pr_url
"
        done
    fi

    # Loop through each found PR and update its body
    for pr_url in "${RELATED_PRS[@]}"; do
        echo "    - Updating $pr_url"
        # Get the current body of the target PR
        target_pr_body=$(gh pr view "$pr_url" --json body --jq '.body')

        # Remove any previous "Related Reviews" section using string manipulation
        base_body=${target_pr_body%%$RELATED_REVIEWS_MARKER*}

        # Append the new list (which will be empty if there's only one PR)
        new_body="${base_body}${RELATED_PRS_BODY}"

        gh pr edit "$pr_url" --body "$new_body"
    done
fi


# Go back to the main branch for safety.
echo "↩️  Returning to '$MAIN_BRANCH' branch."
git checkout "$MAIN_BRANCH" > /dev/null 2>&1
