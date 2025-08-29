#!/bin/zsh

# ---
# Git Long-Lived Review Script
# ---
#
# This script creates and maintains a "virtual" branch containing all commits
# for a specific ticket ID.
#
# MODE OF OPERATION:
# This script now uses a hybrid approach to be both quiet and resilient.
#
# 1. Append Mode (No Force-Push): For the common case of adding new commits or
#    manual fixes to the review branch. The script appends new commits without
#    rewriting history, keeping integrations like ADO/Jira clean.
#
# 2. Rebuild Mode (Force-Push): If the script detects that the original commit
#    history on the main branch has been rewritten (e.g., via `commit --amend`
#    or rebase), it knows a simple append is unsafe. It will automatically
#    fall back to rebuilding the branch from scratch to ensure correctness.
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
# git-review --continue
# git-review --abort
# git-review --update
#
# EXAMPLES:
# git-review "AB#1234"
# git-review "#5678"
# git-review "ab5678" develop
# git-review --continue
#

# --- Configuration ---
REVIEW_BRANCH_PREFIX="CR"
# The standard prefix for your tickets, including any separator.
# Example: "AB#", "JIRA-", "TICKET-"
TICKET_PREFIX="AB#"
# The URL to the raw script content for self-updating.
SCRIPT_URL="https://raw.githubusercontent.com/schultzisaiah/GitMore/refs/heads/main/scripts/git-review.sh"
# Set to 'true' to allow git hooks (e.g., pre-commit, pre-push) to run.
# Set to 'false' to bypass hooks for script operations using '--no-verify'.
GIT_HOOKS_ENABLED=false

# --- State Management ---
# Using a dedicated directory within .git to store state for resumable operations.
STATE_DIR=".git/git-review-state"
STATE_FILE="$STATE_DIR/state.vars"
COMMITS_TO_PICK_FILE="$STATE_DIR/commits_to_pick.txt"
ORIGINAL_COMMITS_FILE="$STATE_DIR/original_commits.txt"
NEW_HASHES_FILE="$STATE_DIR/new_hashes.txt"


# --- Self-Update Function ---
checkForUpdates() {
    local force_check=$1
    local update_url="$SCRIPT_URL"

    if [ "$force_check" = "true" ]; then
        local check_message="🚀 Force-checking for script updates..."
        # Append a cache-busting query parameter using the current Unix timestamp.
        update_url="${SCRIPT_URL}?cb=$(date +%s)"
    fi

    if [ "$force_check" = "true" ]; then
        echo "$check_message"
    fi

    local script_path="${(%):-%x}"
    local temp_file=$(mktemp)

    if ! curl -sSL --max-time 3 "$update_url" -o "$temp_file"; then
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

    if ! diff -q "$script_path" "$temp_file" >/dev/null; then
        echo "✨ A new version of this script is available."
        echo "   Updating now..."
        mv "$temp_file" "$script_path"
        chmod +x "$script_path"
        echo "✅ Script updated successfully. Please re-run your command."
        exit 0
    else
        if [ "$force_check" = "true" ]; then
            echo "✅ You are already running the latest version."
        fi
    fi

    rm "$temp_file"
}

# --- PR Body Generation Function ---
buildCommitListBody() {
    local pr_url_for_links=$1
    local commit_list_body=""
    # This file will always contain the full list of desired original commits.
    local original_commits_array=("${(@f)"$(cat "$ORIGINAL_COMMITS_FILE")"}")
    local new_hashes_array=("${(@f)"$(cat "$NEW_HASHES_FILE")"}")


    # Build the map from original to new hashes
    typeset -A original_to_new_hash_map
    for i in {1..${#original_commits_array[@]}}; do
        original_to_new_hash_map[${original_commits_array[i]}]=${new_hashes_array[i]}
    done

    if [ ${#original_commits_array[@]} -eq 0 ]; then
        echo ""
        return
    fi

    commit_list_body+="

---

### Commits Included in this Review

| Date & Time (UTC) | Commit | Description |
|---|---|---|
"
    # If we have a PR URL, get the PR number for building more specific commit links
    local pr_number=""
    if [ -n "$pr_url_for_links" ]; then
        pr_number=$(gh pr view "$pr_url_for_links" --json number --jq '.number')
    fi

    for hash in "${original_commits_array[@]}"; do
        commit_info=$(git show -s --format='%ci|%H|%h|%s' "$hash")
        commit_date_full=$(echo "$commit_info" | cut -d'|' -f1)
        commit_datetime_utc=$(echo "$commit_date_full" | cut -d' ' -f1,2)
        commit_hash_full=$(echo "$commit_info" | cut -d'|' -f2)
        commit_hash_short=$(echo "$commit_info" | cut -d'|' -f3)
        commit_subject=$(echo "$commit_info" | cut -d'|' -f4)
        new_hash_for_link=${original_to_new_hash_map[$hash]}

        local commit_link=""
        # If we have a PR number, create a PR-specific commit link. Otherwise, create a general one.
        if [ -n "$pr_number" ] && [ -n "$new_hash_for_link" ]; then
            commit_link="[\`${commit_hash_short}\`](https://github.com/$GITHUB_REPO/pull/${pr_number}/commits/${new_hash_for_link})"
        else
            # Fallback to general commit link if PR or new hash isn't available
            commit_link="[\`${commit_hash_short}\`](https://github.com/$GITHUB_REPO/commit/${commit_hash_full})"
        fi

        commit_list_body+="${commit_datetime_utc}|${commit_link}|${commit_subject}
"
    done

    echo "$commit_list_body"
}

# --- Cherry-pick and Post-Action Functions ---

# This function contains the logic that runs AFTER all cherry-picks are successful.
runPostCherryPickActions() {
    echo "✅ All commits have been processed."
    source "$STATE_FILE" # Load variables like GITHUB_REPO, etc.

    echo "📤 Pushing '$REVIEW_BRANCH_NAME' to origin..."
    if ! $GIT_HOOKS_ENABLED; then
      echo "🤫 Git hooks are disabled for this script's operations (using --no-verify)."
    fi

    if [ "$FORCE_PUSH" = "true" ]; then
        echo "   (Force-pushing to reflect rewritten history...)"
        git push -f $GIT_NO_VERIFY_FLAG origin "$REVIEW_BRANCH_NAME"
    else
        # If the remote branch exists, we do a normal push.
        # If not, it's a first-time push, so we set the upstream branch.
        if git rev-parse --verify "origin/$REVIEW_BRANCH_NAME" >/dev/null 2>&1; then
            git push $GIT_NO_VERIFY_FLAG origin "$REVIEW_BRANCH_NAME"
        else
            git push --set-upstream $GIT_NO_VERIFY_FLAG origin "$REVIEW_BRANCH_NAME"
        fi
    fi

    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to push to origin." >&2
        echo "   This can happen if the remote branch has changes you don't have locally." >&2
        echo "   To fix, you can delete the remote branch and let the script recreate it:" >&2
        echo "   git push origin --delete $REVIEW_BRANCH_NAME" >&2
        exit 1
    fi
    echo "✅ Branch pushed successfully."

    # Find commit authors
    local original_commits_array=("${(@f)"$(cat "$ORIGINAL_COMMITS_FILE")"}")
    echo "👥 Finding commit authors to assign to the PR..."
    ASSIGNEES=()
    for hash in "${original_commits_array[@]}"; do
        login=$(gh api "repos/$GITHUB_REPO/commits/$hash" --jq '.author.login // empty' 2>/dev/null)
        if [ -n "$login" ]; then
            ASSIGNEES+=("$login")
        else
            echo "  - Could not find a linked GitHub user for commit $hash"
        fi
    done
    UNIQUE_ASSIGNEES=("${(@u)ASSIGNEES}")
    ASSIGNEE_STRING=$(echo ${(j:,:)UNIQUE_ASSIGNEES})

    # Create or update the Pull Request
    echo "🔎 Checking for an existing Pull Request..."
    EXISTING_PR_URL=$(gh pr list --repo "$GITHUB_REPO" --head "$REVIEW_BRANCH_NAME" --json url --jq '.[0].url' 2>/dev/null)

    PR_BODY_HEADER=$(cat <<EOF
This is an automatically generated, long-lived PR for reviewing all commits related to **$CANONICAL_TICKET_ID**. This PR should **NEVER** be merged.

Any manual edits to this PR description will be overwritten on the next auto-update. Use the comments/discussion instead of editing here.

---
*Want to use this script for your own reviews? [Install \`git-review\` from this repo](https://github.com/schultzisaiah/GitMore/blob/main/scripts/git-review.sh).*
EOF
)

    if [ -z "$EXISTING_PR_URL" ]; then
        echo "🤝 No existing PR found. Creating a new draft PR..."
        echo "  (this may take longer than it feels like it should"
        echo "   due to the gh cli/api latency)"
        PR_TITLE="[REVIEW-ONLY] Feature: $CANONICAL_TICKET_ID"
        COMMIT_LIST_BODY=$(buildCommitListBody "")
        FINAL_PR_BODY="${PR_BODY_HEADER}${COMMIT_LIST_BODY}"

        CREATE_ARGS=("--repo" "$GITHUB_REPO" "--draft" "--title" "$PR_TITLE" "--body" "$FINAL_PR_BODY" "--head" "$REVIEW_BRANCH_NAME" "--base" "$MAIN_BRANCH")
        if [ -n "$ASSIGNEE_STRING" ]; then
            echo "  - Assigning users: $ASSIGNEE_STRING"
            CREATE_ARGS+=("--assignee" "$ASSIGNEE_STRING")
        fi
        NEW_PR_URL=$(gh pr create "${CREATE_ARGS[@]}")
        if [ $? -eq 0 ]; then
            echo "🎉 Success! New draft PR created at: $NEW_PR_URL"
            EXISTING_PR_URL=$NEW_PR_URL
        else
            echo "❌ Error: Failed to create Pull Request."
        fi
    else
        echo "✅ Existing PR found. Updating..."
        echo "  (this may take longer than it feels like it should"
        echo "   due to the gh cli/api latency)"
        COMMIT_LIST_BODY=$(buildCommitListBody "$EXISTING_PR_URL")
        FINAL_PR_BODY="${PR_BODY_HEADER}${COMMIT_LIST_BODY}"
        gh pr edit "$EXISTING_PR_URL" --body "$FINAL_PR_BODY"
        if [ -n "$ASSIGNEE_STRING" ]; then
          gh pr edit "$EXISTING_PR_URL" --add-assignee "$ASSIGNEE_STRING" >/dev/null 2>&1
        fi
        echo "➡️  Review it here: $EXISTING_PR_URL"
    fi

    # Find and link related PRs across the organization
    REPOS_WITH_PRS=()
    if [ -n "$EXISTING_PR_URL" ]; then
        echo "🔗 Searching for related PRs in the '$GITHUB_ORG' organization..."
        RELATED_PRS_JSON=$(gh search prs --owner "$GITHUB_ORG" "$CANONICAL_TICKET_ID" --state open --json url,repository --jq '.')
        RELATED_PRS=(${(f)"$(echo "$RELATED_PRS_JSON" | jq -r '.[] | .url')"})
        REPOS_WITH_PRS=(${(u)"$(echo "$RELATED_PRS_JSON" | jq -r '.[] | .repository.fullName')"})

        RELATED_REVIEWS_MARKER="

---

### Related Reviews"

        if [ ${#RELATED_PRS[@]} -gt 1 ]; then
            echo "  - Found ${#RELATED_PRS[@]} related PRs. Updating them with links..."
            for target_pr_url in "${RELATED_PRS[@]}"; do
                echo "    - Updating $target_pr_url"
                local current_pr_body="${RELATED_REVIEWS_MARKER}
"
                for pr_to_list in "${RELATED_PRS[@]}"; do
                    if [ "$pr_to_list" = "$target_pr_url" ]; then
                        current_pr_body+="* $pr_to_list (this PR)
"
                    else
                        current_pr_body+="* $pr_to_list
"
                    fi
                done
                target_pr_body_content=$(gh pr view "$target_pr_url" --json body --jq '.body')
                base_body=${target_pr_body_content%%$RELATED_REVIEWS_MARKER*}
                new_body="${base_body}${current_pr_body}"
                gh pr edit "$target_pr_url" --body "$new_body"
            done
        fi
    fi

    # Find Related Commits Across Organization
    echo "---"
    echo "🔎 Searching for commits referencing '$CANONICAL_TICKET_ID' in other repositories..."
    ALL_REPOS_WITH_COMMITS=(${(f)"$(gh search commits "$CANONICAL_TICKET_ID" --owner "$GITHUB_ORG" --json repository --jq '.[] | .repository.fullName' 2>/dev/null)"})

    if [ ${#ALL_REPOS_WITH_COMMITS[@]} -gt 0 ]; then
        UNIQUE_REPOS=(${(u)ALL_REPOS_WITH_COMMITS})
        # Filter out the current repository from the list.
        OTHER_REPOS=()
        for repo in "${UNIQUE_REPOS[@]}"; do
            if [ "$repo" != "$GITHUB_REPO" ]; then
                OTHER_REPOS+=("$repo")
            fi
        done

        if [ ${#OTHER_REPOS[@]} -gt 0 ]; then
            echo "✨ Found commits in other repositories:"
            for repo in "${OTHER_REPOS[@]}"; do
                if (( ${REPOS_WITH_PRS[(i)$repo]} )); then
                    echo "  - ✅ $repo (PR exists)"
                else
                    echo "  - ◻️ $repo (No PR found)"
                fi
            done
            echo "   You may want to run 'git-review' in those repositories as well."
        else
            echo "✅ No other repositories in '$GITHUB_ORG' found with commits for this ticket."
        fi
    else
        echo "✅ No repositories in '$GITHUB_ORG' found with commits for this ticket."
    fi
    echo "---"


    # Go back to the main branch for safety.
    echo "↩️  Returning to '$MAIN_BRANCH' branch."
    git checkout "$MAIN_BRANCH" > /dev/null 2>&1

    echo "🧹 Cleaning up temporary state..."
    rm -rf "$STATE_DIR"
    echo "✅ Done!"
}

# The core cherry-picking loop.
perform_cherry_picks() {
    source "$STATE_FILE" # Load state
    echo "🍒 Cherry-picking commits onto '$REVIEW_BRANCH_NAME'..."

    # Use a subshell and process substitution to read the file safely
    while IFS= read -r hash; do
        if [ -z "$hash" ]; then continue; fi

        echo "  -> Picking $(git show -s --format='%h %s' "$hash")"
        # The 2>&1 redirects stderr to stdout so we can capture all output.
        if ! git cherry-pick -x "$hash" 2>&1; then
            # A conflict occurred. Check if rerere fixed it automatically.
            # We check for the absence of "Unmerged paths" in the status.
            if ! git status --porcelain | grep -q '^UU'; then
                echo "  - ✅ Conflict auto-resolved by 'rerere'. Continuing script automatically..."
                # The conflict was resolved, but the cherry-pick is still paused.
                # We must continue it to finalize the commit.
                if ! git cherry-pick --continue; then
                    # This can happen if the resolution results in an empty commit.
                    echo "  - ⚠️ 'git cherry-pick --continue' failed, likely due to an empty commit. Skipping."
                    git cherry-pick --abort
                fi
            else
                # This is a new conflict that rerere couldn't handle.
                # Exit and ask the user to resolve it manually.
                echo ""
                echo "❌ ERROR: Cherry-pick of $hash failed due to a new conflict." >&2
                echo "" >&2
                echo "--- ACTION REQUIRED ---" >&2
                echo "1. Open another terminal in this repository." >&2
                echo "2. Resolve the conflicts in your editor." >&2
                echo "3. Stage the resolved files: git add <file1> <file2> ..." >&2
                echo "4. Continue the cherry-pick: git cherry-pick --continue" >&2
                echo "5. Once that succeeds, resume this script by running: git-review --continue" >&2
                echo "-----------------------" >&2
                echo "To give up, run: git-review --abort" >&2
                exit 1
            fi
        fi

        # Success! Record the new hash and remove the old one from the pending list.
        # This part runs for both successful picks and auto-resolved picks.
        git rev-parse HEAD >> "$NEW_HASHES_FILE"
        tail -n +2 "$COMMITS_TO_PICK_FILE" > "$COMMITS_TO_PICK_FILE.tmp" && mv "$COMMITS_TO_PICK_FILE.tmp" "$COMMITS_TO_PICK_FILE"

    done < "$COMMITS_TO_PICK_FILE"

    # After the loop, check if there are any commits left to pick. If so, something went wrong.
    if [ -s "$COMMITS_TO_PICK_FILE" ]; then
        # The file is not empty, indicating an incomplete process.
        # This case should ideally not be hit with the new logic, but serves as a safeguard.
        echo "⚠️  Warning: Cherry-pick loop finished, but there are still commits pending. Please check the state."
    fi
}


# --- Command Handlers for continue/abort ---

handle_continue() {
    echo "▶️ Resuming 'git-review' operation..."
    if [ ! -d "$STATE_DIR" ]; then
        echo "❌ Error: No saved state found. Cannot continue." >&2
        echo "   Please start a new review with 'git-review <TicketID>'." >&2
        exit 1
    fi

    source "$STATE_FILE"
    # Ensure we are on the correct branch to continue.
    if [ "$(git rev-parse --abbrev-ref HEAD)" != "$REVIEW_BRANCH_NAME" ]; then
        echo "❌ Error: You are not on the review branch ('$REVIEW_BRANCH_NAME')." >&2
        echo "   Please run 'git checkout $REVIEW_BRANCH_NAME' and resolve any issues." >&2
        exit 1
    fi

    # Check if the previous conflict was resolved.
    if [ -e ".git/CHERRY_PICK_HEAD" ]; then
        echo "❌ Error: A cherry-pick conflict is still in progress." >&2
        echo "   Please resolve it and run 'git cherry-pick --continue' before trying again." >&2
        exit 1
    fi

    echo "✅ Conflict resolved. Updating state for the completed commit..."
    # The user has run 'git cherry-pick --continue', so HEAD is now the newly created commit.
    # We need to record its hash and remove the original hash from our to-do list.
    git rev-parse HEAD >> "$NEW_HASHES_FILE"
    tail -n +2 "$COMMITS_TO_PICK_FILE" > "$COMMITS_TO_PICK_FILE.tmp" && mv "$COMMITS_TO_PICK_FILE.tmp" "$COMMITS_TO_PICK_FILE"

    echo "✅ State updated. Continuing with remaining commits..."
    perform_cherry_picks
    runPostCherryPickActions
}

handle_abort() {
    echo "🛑 Aborting 'git-review' operation..."
    if [ ! -d "$STATE_DIR" ]; then
        echo "⚠️ No saved state found to clean up. Already clean."
        exit 0
    fi
    source "$STATE_FILE"

    # Must checkout a different branch before trying to delete the review branch
    local main_branch_from_state
    main_branch_from_state=$(grep 'MAIN_BRANCH=' "$STATE_FILE" | cut -d"'" -f2)

    echo "  - Returning to '$main_branch_from_state' branch..."
    git checkout "$main_branch_from_state"

    if [ -e ".git/CHERRY_PICK_HEAD" ]; then
        echo "  - Aborting in-progress cherry-pick..."
        git cherry-pick --abort
    fi

    local review_branch_from_state
    review_branch_from_state=$(grep 'REVIEW_BRANCH_NAME=' "$STATE_FILE" | cut -d"'" -f2)

    if git show-ref --verify --quiet "refs/heads/$review_branch_from_state"; then
        echo "  - Deleting temporary local branch '$review_branch_from_state'..."
        git branch -D "$review_branch_from_state"
    fi

    echo "  - Cleaning up state files..."
    rm -rf "$STATE_DIR"
    echo "✅ Abort complete."
}


# --- Main Script Logic ---

# 1. Handle command flags
case "$1" in
    --update)
        checkForUpdates true
        exit 0
        ;;
    --continue)
        handle_continue
        exit 0
        ;;
    --abort)
        handle_abort
        exit 0
        ;;
    "")
        echo "❌ Error: No Ticket ID provided." >&2
        echo "Usage: $0 \"<TicketID>\" [MainBranch]" >&2
        exit 1
        ;;
esac

# On a normal run, perform a quiet update check.
checkForUpdates

# 2. Input Validation (now handled by the case statement)

# 3. Setup Git Hook Flag
GIT_NO_VERIFY_FLAG=""
if ! $GIT_HOOKS_ENABLED; then
  GIT_NO_VERIFY_FLAG="--no-verify"
fi

# 4. Input Processing and Normalization
TICKET_NUMBER=$(echo "$1" | tr -dc '0-9')
if [ -z "$TICKET_NUMBER" ]; then
    echo "❌ Error: Could not find any numbers in the provided Ticket ID '$1'." >&2
    exit 1
fi
CANONICAL_TICKET_ID="${TICKET_PREFIX}${TICKET_NUMBER}"
SANITIZED_TICKET_ID=$(echo "$CANONICAL_TICKET_ID" | sed 's/[^a-zA-Z0-9]/-/g')
REVIEW_BRANCH_NAME="$REVIEW_BRANCH_PREFIX/$SANITIZED_TICKET_ID"

echo "🚀 Starting review for Ticket ID: $CANONICAL_TICKET_ID"
echo "🌿 Review branch will be: $REVIEW_BRANCH_NAME"

# 5. Pre-flight Checks
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ Error: Your workspace is not ready. Please ensure you are on the main branch and shelve any uncommitted changes." >&2
  exit 1
fi
local missing_deps=()
if ! command -v git &> /dev/null; then missing_deps+=("git"); fi
if ! command -v curl &> /dev/null; then missing_deps+=("curl"); fi
if ! command -v gh &> /dev/null; then missing_deps+=("GitHub CLI ('gh')"); fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "❌ Error: The following required dependencies are not installed:"
    for dep in "${missing_deps[@]}"; do
        echo "  - $dep"
    done
    exit 1
fi

# --- Enable git rerere for easier conflict resolution ---
if [ "$(git config rerere.enabled)" != "true" ]; then
    echo "🔧 Enabling 'git rerere' in this repository to automatically resolve repeated conflicts."
    git config rerere.enabled true
    git config rerere.autoupdate true
    echo "✅ 'rerere' is now enabled. Your conflict resolutions will be remembered."
fi

# 6. Determine Main Branch
MAIN_BRANCH=""
if [ -n "$2" ]; then
    MAIN_BRANCH="$2"
else
    git fetch origin --prune
    DETECTED_BRANCH=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
    if [ -n "$DETECTED_BRANCH" ] && [ "$DETECTED_BRANCH" != "(unknown)" ]; then
        MAIN_BRANCH="$DETECTED_BRANCH"
    else
        if git show-ref --verify --quiet refs/remotes/origin/main; then
            MAIN_BRANCH="main"
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
            MAIN_BRANCH="master"
        fi
    fi
fi
if [ -z "$MAIN_BRANCH" ]; then echo "❌ Error: Could not auto-detect the default branch." >&2; exit 1; fi
echo "✅ Using main branch: $MAIN_BRANCH"

# 7. Auto-detect GitHub Repo
GIT_REMOTE_URL=$(git remote get-url origin 2>/dev/null)
GITHUB_REPO=$(echo "$GIT_REMOTE_URL" | sed -e 's/.*github.com[\/:]//' -e 's/\.git$//')
GITHUB_ORG=$(echo $GITHUB_REPO | cut -d'/' -f1)
echo "✅ Detected repository: $GITHUB_REPO"

# 8. Ensure local main branch is up-to-date
echo "🔄 Pulling latest changes for '$MAIN_BRANCH'..."
git checkout "$MAIN_BRANCH" > /dev/null 2>&1 && git pull origin "$MAIN_BRANCH" > /dev/null 2>&1

# 9. Find all commits related to the ticket
echo "🔎 Gathering commits..."
MAIN_BRANCH_COMMITS=(${(f)"$(git log "$MAIN_BRANCH" --grep="$CANONICAL_TICKET_ID" -i --pretty=format:"%H")"})
REMOTE_REVIEW_BRANCH="origin/$REVIEW_BRANCH_NAME"
REMOTE_BRANCH_COMMITS_RAW=()
if git rev-parse --verify "$REMOTE_REVIEW_BRANCH" >/dev/null 2>&1; then
    # In update mode, we only care about commits on main, as commits on the review branch are already "applied".
    # This prevents finding the same commit twice (once on main, once on the review branch)
    : # This is a no-op, we just want to avoid the else block.
else
    # In create mode, we need to check if the review branch exists locally but not remotely
    if git rev-parse --verify "$REVIEW_BRANCH_NAME" >/dev/null 2>&1; then
        MERGE_BASE=$(git merge-base "$MAIN_BRANCH" "$REVIEW_BRANCH_NAME")
        if [ -n "$MERGE_BASE" ]; then
          REMOTE_BRANCH_COMMITS_RAW=(${(f)"$(git log "$MERGE_BASE..$REVIEW_BRANCH_NAME" --pretty=format:"%H")"})
        fi
    fi
fi

ALL_CANDIDATE_HASHES=("${MAIN_BRANCH_COMMITS[@]}" "${REMOTE_BRANCH_COMMITS_RAW[@]}")
typeset -A patch_ids_to_hashes
for hash in "${ALL_CANDIDATE_HASHES[@]}"; do
    if [ -z "$hash" ]; then continue; fi
    patch_id=$(git show "$hash" | git patch-id | cut -d' ' -f1)
    if [[ ! -v patch_ids_to_hashes[$patch_id] ]]; then patch_ids_to_hashes[$patch_id]=$hash; fi
done
UNIQUE_HASHES=("${(@v)patch_ids_to_hashes}")
if [ ${#UNIQUE_HASHES[@]} -eq 0 ]; then
  echo "⚠️ No commits found for Ticket ID '$CANONICAL_TICKET_ID'."
  exit 0
fi
COMMIT_HASHES=$(echo "${UNIQUE_HASHES[@]}" | tr ' ' '\n' | git rev-list --stdin --reverse --no-walk)
COMMIT_ARRAY=("${(@f)COMMIT_HASHES}")

# --- State Setup ---
echo "📝 Setting up state for a resumable operation..."
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
(
    echo "export MAIN_BRANCH='$MAIN_BRANCH'"
    echo "export REVIEW_BRANCH_NAME='$REVIEW_BRANCH_NAME'"
    echo "export CANONICAL_TICKET_ID='$CANONICAL_TICKET_ID'"
    echo "export GITHUB_REPO='$GITHUB_REPO'"
    echo "export GITHUB_ORG='$GITHUB_ORG'"
    echo "export GIT_NO_VERIFY_FLAG='$GIT_NO_VERIFY_FLAG'"
    echo "export GIT_HOOKS_ENABLED=$GIT_HOOKS_ENABLED"
) > "$STATE_FILE"

# --- Main Logic: Decide between Create, Append, and Rebuild Mode ---

if git rev-parse --verify "$REMOTE_REVIEW_BRANCH" >/dev/null 2>&1; then
    # --- UPDATE LOGIC ---
    git checkout -B "$REVIEW_BRANCH_NAME" "$REMOTE_REVIEW_BRANCH"
    git pull

    ALL_DESIRED_COMMITS_FILE="$STATE_DIR/all_desired_commits.txt"
    echo "${COMMIT_ARRAY[@]}" | tr ' ' '\n' > "$ALL_DESIRED_COMMITS_FILE"

    # Find the point where this review branch diverged from the main branch.
    MERGE_BASE=$(git merge-base "$MAIN_BRANCH" "HEAD")

    APPLIED_COMMITS_FILE="$STATE_DIR/applied_commits.txt"
    # Only look for cherry-pick messages in the commits that are *unique* to this review branch.
    # Without the "$MERGE_BASE..HEAD" range, it would scan the entire history of main as well.
    if [ -n "$MERGE_BASE" ]; then
        git log "$MERGE_BASE..HEAD" --pretty=%b | grep "(cherry picked from commit" | sed -e 's/.*commit //' -e 's/)//' > "$APPLIED_COMMITS_FILE"
    else
        # If there's no merge base, it means the histories are unrelated, so we check the whole branch history.
        git log HEAD --pretty=%b | grep "(cherry picked from commit" | sed -e 's/.*commit //' -e 's/)//' > "$APPLIED_COMMITS_FILE"
    fi

    COMMITS_TO_REMOVE_FILE="$STATE_DIR/commits_to_remove.txt"
    grep -v -x -f "$ALL_DESIRED_COMMITS_FILE" "$APPLIED_COMMITS_FILE" > "$COMMITS_TO_REMOVE_FILE"

    if [ -s "$COMMITS_TO_REMOVE_FILE" ]; then
        # --- REBUILD MODE ---
        echo "⚠️  Detected rewritten history on main."
        echo "   The following commits are on the review branch but are no longer part of the desired history:"
        while IFS= read -r hash; do
            if [ -n "$hash" ]; then
                echo "     - $(git show -s --format='%h %s' "$hash")"
            fi
        done < "$COMMITS_TO_REMOVE_FILE"
        echo "   This typically happens if an original commit was amended or rebased."
        echo "   Rebuilding the review branch from scratch to match. This will require a force-push."
        echo "export FORCE_PUSH='true'" >> "$STATE_FILE"

        FIRST_COMMIT_HASH="${COMMIT_ARRAY[1]}"
        STARTING_POINT_HASH=$(git rev-parse "$FIRST_COMMIT_HASH^")
        if [ -z "$STARTING_POINT_HASH" ]; then echo "❌ Error: Could not find starting point."; exit 1; fi
        echo "export STARTING_POINT_HASH='$STARTING_POINT_HASH'" >> "$STATE_FILE"

        echo "${COMMIT_ARRAY[@]}" | tr ' ' '\n' > "$COMMITS_TO_PICK_FILE"
        cp "$COMMITS_TO_PICK_FILE" "$ORIGINAL_COMMITS_FILE"
        touch "$NEW_HASHES_FILE"

        git checkout -B "$REVIEW_BRANCH_NAME" "$STARTING_POINT_HASH"
    else
        # --- APPEND MODE ---
        echo "🔄 Found existing remote branch. Proceeding with incremental update."
        echo "export FORCE_PUSH='false'" >> "$STATE_FILE"

        grep -v -x -f "$APPLIED_COMMITS_FILE" "$ALL_DESIRED_COMMITS_FILE" > "$COMMITS_TO_PICK_FILE"

        cp "$ALL_DESIRED_COMMITS_FILE" "$ORIGINAL_COMMITS_FILE"
        # Re-populating NEW_HASHES_FILE needs the same scoping as APPLIED_COMMITS_FILE
        if [ -n "$MERGE_BASE" ]; then
            git log "$MERGE_BASE..HEAD" --pretty=%H --grep "(cherry picked from commit" --reverse > "$NEW_HASHES_FILE"
        else
            git log HEAD --pretty=%H --grep "(cherry picked from commit" --reverse > "$NEW_HASHES_FILE"
        fi

        if [ ! -s "$COMMITS_TO_PICK_FILE" ]; then
            echo "✅ Review branch is already up-to-date. Nothing to do."
            # PRs won't be cross-linked until a new commit is added.
            git checkout "$MAIN_BRANCH" > /dev/null 2>&1
            rm -rf "$STATE_DIR"
            exit 0
        else
            echo "➕ Found $(wc -l < "$COMMITS_TO_PICK_FILE") new commit(s) to apply."
        fi
    fi
else
    # --- CREATE MODE ---
    echo "🌿 No existing remote branch found. Creating a new review branch."
    echo "export FORCE_PUSH='true'" >> "$STATE_FILE"

    FIRST_COMMIT_HASH="${COMMIT_ARRAY[1]}"
    STARTING_POINT_HASH=$(git rev-parse "$FIRST_COMMIT_HASH^")
    if [ -z "$STARTING_POINT_HASH" ]; then echo "❌ Error: Could not find starting point."; exit 1; fi
    echo "export STARTING_POINT_HASH='$STARTING_POINT_HASH'" >> "$STATE_FILE"

    echo "${COMMIT_ARRAY[@]}" | tr ' ' '\n' > "$COMMITS_TO_PICK_FILE"
    cp "$COMMITS_TO_PICK_FILE" "$ORIGINAL_COMMITS_FILE"
    touch "$NEW_HASHES_FILE" # Start with an empty file for new hashes

    if git show-ref --verify --quiet "refs/heads/$REVIEW_BRANCH_NAME"; then
      git branch -D "$REVIEW_BRANCH_NAME"
    fi
    git checkout -b "$REVIEW_BRANCH_NAME" "$STARTING_POINT_HASH"
fi

# 12. Source the environment and start the process
source "$STATE_FILE"

# Only run cherry-picks if there's something to pick
if [ -s "$COMMITS_TO_PICK_FILE" ]; then
    perform_cherry_picks
fi
runPostCherryPickActions

