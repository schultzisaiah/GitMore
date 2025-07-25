#!/usr/bin/env python3
# ---
# Git Pre-Push Hook for ADO Integration
# ---
#
# This script automates interactions with Azure DevOps (ADO) before a push.
# It scans commit messages for ticket numbers (e.g., AB#12345), finds the
# current ADO iteration, and then tags the work items and sets their
# 'Fixed in Iteration' field.
#
# It automatically detects your repository's default branch (main/master) and
# includes optional test execution and various user-friendly checks
# to ensure dependencies and configurations are met.
#
# DEPENDENCIES:
# - python3
# - requests (a Python library)
#
# SETUP:
# 1. Save this script as 'pre-push' (no file extension) in your repository's
#    '.git/hooks/' directory.
# 2. Make it executable:
#    chmod +x .git/hooks/pre-push
# 3. Install the required Python library:
#    pip install requests
# 4. Create an ADO Personal Access Token, if you don't have one already.
#    - Go to your ADO User Settings > Personal Access Tokens
#    - Create a new token with 'Work Items (Read, write, and manage)' scope.
# 5. Configure your ADO Personal Access Token. The script will find it if you:
#    a) Set it in your shell config (e.g., ~/.zshrc or ~/.bash_profile):
#       export ADO_TOKEN="your_token_here"
#    b) OR export it in your current terminal session.
# 6. Edit the `TAG_VALUE` variable in the Configuration section below to match
#    your repository's settings.
#

import re
import sys
import os
import io
import json
import contextlib
from subprocess import check_output, CalledProcessError, call
from datetime import datetime, timezone

# --- Suppress SSL Warning ---
# This is a workaround for a persistent warning in some environments (like macOS + IntelliJ).
# We temporarily redirect stderr to /dev/null during the requests import to silence the
# benign NotOpenSSLWarning.
with contextlib.redirect_stderr(io.StringIO()):
  try:
    import requests
  except ImportError:
    print("❌ ERROR: The 'requests' library is not installed. Please run 'pip install requests'", file=sys.stderr)
    sys.exit(1)


# --- Configuration ---
# The tag to add to the ADO work item
TAG_VALUE = "App:TODO"
# Your Azure DevOps organization and project details
ADO_ORG = "tr-legal-tech"
ADO_PROJECT = "FindLaw"

def get_token_from_shell_config():
  """
  Reads the ADO_TOKEN from common shell config files in the user's home directory.
  This provides a fallback for GUI apps like IntelliJ that don't load shell environments.
  It checks in the following order: .zshrc, .bash_profile, .bashrc, .profile
  """
  config_files = ['.zshrc', '.bash_profile', '.bashrc', '.profile']
  token_regex = re.compile(r"^\s*(?:export\s+)?ADO_TOKEN=(['\"]?)(.*?)\1\s*(?:#.*)?$")

  for config_file in config_files:
    config_path = os.path.expanduser(os.path.join('~', config_file))
    if not os.path.exists(config_path):
      continue

    try:
      with open(config_path, 'r') as f:
        for line in f:
          match = token_regex.match(line)
          if match:
            # Return the first token found
            return match.group(2)
    except Exception:
      # Silently fail and try the next file
      continue

  return None

# Your Azure DevOps Personal Access Token.
# It's read first from the environment, then from shell configs, then defaults to 'TODO'.
TOKEN = os.getenv('ADO_TOKEN') or get_token_from_shell_config() or 'TODO'


# --- Helper for Styled Output ---
def print_status(icon, message, is_warning=False, is_error=False):
  """Prints a formatted status message with an icon."""
  if is_error:
    # Print errors to stderr
    print(f"❌ ERROR: {message}", file=sys.stderr)
  elif is_warning:
    print(f"⚠️  WARN: {message}", file=sys.stdout)
  else:
    print(f"{icon} {message}", file=sys.stdout)


def get_default_branch():
  """
  Determines the default branch (e.g., main, master) from the 'origin' remote.
  """
  print_status("🔎", "Auto-detecting default branch from remote 'origin'...")
  try:
    # This command is robust for finding the default branch name
    remote_info = check_output(['git', 'remote', 'show', 'origin']).decode('utf-8')
    match = re.search(r'HEAD branch:\s*(\S+)', remote_info)
    if match:
      branch_name = match.group(1)
      print_status("✅", f"Detected '{branch_name}' as the default remote branch.")
      return branch_name
    else:
      print_status("❌", "Could not determine default branch from 'git remote show origin'.", is_error=True)
      print_status("ℹ️", "Please ensure your 'origin' remote is configured correctly.")
      return None
  except CalledProcessError:
    print_status("❌", "Failed to run 'git remote show origin'. Is this a git repository with a remote named 'origin'?", is_error=True)
    return None
  except FileNotFoundError:
    print_status("❌", "The 'git' command was not found. Is git installed and in your PATH?", is_error=True)
    return None


def run_gradle_tests():
  """
  Runs Gradle tests and prints the status. Checks for gradlew permissions first.
  Returns True if tests pass, False otherwise.
  """
  gradlew_path = './gradlew'

  # First, check if the gradlew file exists at all.
  if not os.path.isfile(gradlew_path):
    print_status("❌", f"Gradle wrapper '{gradlew_path}' not found.", is_error=True)
    return False

  # Next, check if the script has execute permissions.
  if not os.access(gradlew_path, os.X_OK):
    print_status("❌", f"Gradle wrapper '{gradlew_path}' is not executable.", is_error=True)
    print_status("ℹ️", "To fix this, please run the following command in your terminal:")
    print_status("ℹ️", "chmod +x gradlew")
    return False

  print_status("🧪", "Running Gradle tests...")
  try:
    # Using check_output to capture stdout/stderr if needed, and it raises an error on failure
    check_output([gradlew_path, 'test'], stderr=sys.stdout)
    print_status("✅", "Gradle tests passed successfully.")
    return True
  except CalledProcessError as e:
    print_status("❌", f"Gradle tests failed. See output above for details.", is_error=True)
    return False
  except FileNotFoundError:
    # This is a fallback, but the os.path.isfile check should catch this.
    print_status("❌", f"Command '{gradlew_path}' not found.", is_error=True)
    return False


def find_current_iteration_recursive(nodes, current_date, current_year):
  """
  Recursively searches through iteration nodes to find the current iteration.
  """
  for node in nodes:
    path = node.get('path', '')
    node_name = node.get('name')

    if current_year in path and 'attributes' in node:
      attributes = node['attributes']
      start_date_str = attributes.get('startDate')
      end_date_str = attributes.get('finishDate')

      if start_date_str and end_date_str:
        try:
          start_date = datetime.fromisoformat(start_date_str.replace('Z', '+00:00')).astimezone(timezone.utc).date()
          end_date = datetime.fromisoformat(end_date_str.replace('Z', '+00:00')).astimezone(timezone.utc).date()

          if start_date <= current_date <= end_date:
            return node_name
        except ValueError as e:
          print_status("⚠️ ", f"Could not parse date for node '{node_name}': {e}", is_warning=True)

    if 'children' in node and node['children']:
      found_name = find_current_iteration_recursive(node['children'], current_date, current_year)
      if found_name:
        return found_name
  return None


def get_current_iteration():
  """
  Fetches the current iteration name from Azure DevOps.
  """
  print_status("🔎", "Fetching current iteration from Azure DevOps...")
  url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/classificationnodes/Iterations?$depth=5&api-version=7.1"
  headers = {"Content-Type": "application/json"}

  try:
    response = requests.get(url, headers=headers, auth=('', TOKEN), timeout=10)
    response.raise_for_status()
    data = response.json()

    current_date = datetime.now(timezone.utc).date()
    current_year = str(current_date.year)

    if 'children' in data:
      iteration = find_current_iteration_recursive(data['children'], current_date, current_year)
      if iteration:
        print_status("✅", f"Detected current iteration: {iteration}")
        return iteration
      else:
        print_status("❌", "No active iteration found for the current date.", is_error=True)
        return None
    else:
      print_status("❌", "Could not find 'children' in ADO API response.", is_error=True)
      return None

  except requests.exceptions.RequestException as e:
    print_status("❌", f"Failed to get current iteration from ADO. Error: {e}", is_error=True)
    return None
  except json.JSONDecodeError as e:
    print_status("❌", f"Could not decode JSON response from ADO API: {e}", is_error=True)
    return None


def add_tag(ticket_nums, tag_value, iteration_value):
  """
  Adds tags and sets the 'Fixed in Iteration' field for Azure DevOps work items.
  """
  print_status("�", f"Preparing to update {len(ticket_nums)} ticket(s)...")
  url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/workitems/{{}}?api-version=7.0"
  headers = {"Content-Type": "application/json-patch+json"}

  for ticket_num in ticket_nums:
    print_status("🏷️ ", f"Updating ticket AB#{ticket_num}...")
    body = [
      {"op": "add", "path": "/fields/System.Tags", "value": tag_value},
      {"op": "add", "path": "/fields/Custom.FixedinIteration", "value": iteration_value}
    ]
    try:
      response = requests.patch(url.format(ticket_num), json=body, headers=headers, auth=('', TOKEN), timeout=10)
      if response.status_code == 200:
        print_status("✅", f"Successfully updated ticket AB#{ticket_num}.")
      else:
        # Try to parse error message from ADO
        error_message = response.json().get('message', response.text)
        print_status("⚠️ ", f"Failed to update ticket AB#{ticket_num}. Status: {response.status_code}. Reason: {error_message}", is_warning=True)
    except requests.exceptions.RequestException as e:
      print_status("⚠️ ", f"A network error occurred while updating AB#{ticket_num}: {e}", is_warning=True)


def parse_commit_message(commit_messages):
  """
  Parses commit messages to extract unique ticket numbers (digits only).
  """
  print_status("🔎", "Scanning commit messages for ticket numbers...")
  ticket_numbers = set(re.findall(r'AB#(\d+)', commit_messages, re.IGNORECASE))

  if ticket_numbers:
    print_status("🎟️ ", f"Found ticket numbers: {', '.join(sorted(ticket_numbers))}")
  else:
    print_status("🤷", "No ticket numbers found in commit messages.", is_warning=True)

  return list(ticket_numbers)


def process_commits(local_ref, local_sha, remote_sha, default_branch):
  """
  Processes commits in a given range to extract ticket numbers and add tags.
  """
  try:
    branch_name = local_ref.split('/')[-1]
    print_status("🌿", f"Processing push to branch: {branch_name}")

    # If the branch is a Code Review branch, skip ADO processing.
    if branch_name.upper().startswith('CR/'):
      print_status("➡️", "Skipping ADO updates for Code Review branch.")
      return

    # If remote_sha is all zeros, it's a new branch
    if remote_sha == "0000000000000000000000000000000000000000":
      print_status("✨", "New branch detected.")
      base_sha = check_output(['git', 'merge-base', local_sha, f"origin/{default_branch}"]).decode('utf-8').strip()
      commit_range = f"{base_sha}..{local_sha}"
    else:
      commit_range = f"{remote_sha}..{local_sha}"

    print_status("📖", f"Reading commits in range: {commit_range}")
    git_log_output = check_output(['git', 'log', '--pretty=%B', commit_range])
    commit_messages = git_log_output.decode('utf-8').strip()

    if not commit_messages:
      print_status("✅", "No new commits to process.")
      return

    ticket_nums = parse_commit_message(commit_messages)
    if not ticket_nums:
      return # No tickets to process

    iteration_value = get_current_iteration()
    if not iteration_value:
      print_status("❌", "Aborting ADO updates because current iteration could not be determined.", is_error=True)
      # You might want to exit here if this is a critical failure
      # sys.exit(1)
      return

    add_tag(ticket_nums, TAG_VALUE, iteration_value)

  except CalledProcessError as e:
    print_status("❌", f"A git command failed: {e}", is_error=True)
    # Re-raise to ensure the git hook fails, preventing the push
    raise e


def main():
  """
  Main function for the pre-push hook.
  """
  print_status("🚀", "--- Starting Pre-Push Hook ---")

  default_branch = get_default_branch()
  if not default_branch:
    sys.exit(1) # Exit if we can't determine the default branch

  # --- Configuration Check ---
  print_status("🔧", "Checking configuration...")
  is_setup_complete = True
  if TOKEN == "TODO" or not TOKEN:
    print_status("⚠️ ", "ADO_TOKEN is not set. Please set it as an env variable or in your shell config file.", is_warning=True)
    is_setup_complete = False
  else:
    print_status("✅", "ADO Token is configured.")

  # --- Run Tests (Optional) ---
  # Uncomment the following lines to enforce passing tests before push
  # if not run_gradle_tests():
  #     print_status("❌", "Tests failed. Aborting push.", is_error=True)
  #     sys.exit(1)

  # --- Process Commits ---
  stdin_lines = sys.stdin.readlines()
  if not stdin_lines:
    print_status("🤷", "No input from git. Nothing to process.", is_warning=True)
    print_status("🏁", "--- Pre-Push Hook Finished ---")
    return

  if not is_setup_complete:
    print_status("🤷", "Skipping ADO integration due to incomplete setup.", is_warning=True)
    print_status("🏁", "--- Pre-Push Hook Finished ---")
    return

  for line in stdin_lines:
    line = line.strip()
    if not line:
      continue

    local_ref, local_sha, remote_ref, remote_sha = line.split()
    process_commits(local_ref, local_sha, remote_ref, remote_sha, default_branch)

  print_status("🏁", "--- Pre-Push Hook Finished ---")


if __name__ == "__main__":
  # Ensure the hook is being run from a git repository
  if not os.path.isdir('.git'):
    print_status("❌", "This script must be run from the root of a Git repository.", is_error=True)
    sys.exit(1)
  main()

�
