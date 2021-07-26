#!/bin/bash

# fail as soon as any command errors
set -e

# supported branch name: main and master
default_branch=$1
token=$2
# supported language: golang
# update_command=$2
update_path=$3
on_changes_command=$4
repo=$GITHUB_REPOSITORY #owner and repository, ie: user/repo
username=$GITHUB_ACTOR

branch_name="automated-dependencies-update"
email="noreply@github.com"

if [ -z "$default_branch" ]; then
    echo "Default branch is not defined, variable set to 'main'"
    default_branch="main"
fi

if [ -z "$token" ]; then
    echo "Token is not defined"
    exit 1
fi

# supported language: golang
# if [ -z "$update_command" ]; then
#     echo "update-command cannot be empty"
#     exit 1
# fi

# remove optional params markers
update_path_value=${update_path%?}
if [ -n "$update_path_value" ]; then
    # if path is set, use that. otherwise default to current working directory
    echo "Change directory to $update_path_value"
    cd "$update_path_value"

    # convert slesh to dash in path (monorepo support), ie: /test/path -> -test-path
    branch_path="$(echo "$update_path_value" | tr -d '.' | tr '/' '-')"
fi

# assumes the repo is already cloned as a prerequisite for running the script
git checkout $default_branch
# fetch first to be able to detect if branch already exists 
git fetch origin

# branch already exists, previous opened PR was not merged
branch_exists="$(git branch -r --list origin/$branch_name$branch_path)"
if [ -z "$branch_exists" ]; then
    # create new branch
    git checkout -b $branch_name$branch_path
else
    echo "Branch name $branch_name$branch_path already exists"

    # check out existing branch
    echo "Check out branch instead"
    git checkout -b $branch_name$branch_path origin/$branch_name$branch_path
    git pull

    # reset with latest from main
    # this avoids merge conflicts when existing changes are not merged
    git reset --hard origin/$default_branch
fi

echo "Running update command 'go get -u && go mod tidy'"
# extract upgraded dependencies to file, ie: remote_repo base_ref head_ref
eval "go get -u 2>&1 | awk '/upgraded/ {print \$4, \$5, \$7}' >> upgraded.log"
eval 'go mod tidy'

# preparation commit message
if [ -s upgraded.log ]; then
    echo "Generate commit message"
    echo "Dependency auto update $update_path_value" | tee -a commit.log
    while read p; do
        remote_repo="$(echo "$p" | awk '{ print $1}')"
        base_ref="$(echo "$p" | awk '{ print $2}')"
        head_ref="$(echo "$p" | awk '{ print $3}')"

        cat >> commit.log << EOF

## Bumps [$remote_repo](https://$remote_repo) from $base_ref to $head_ref.
- [Release notes](https://$remote_repo/releases)
- [Changelog](https://$remote_repo/blob/main/CHANGELOG.md)
- [Commits](https://$remote_repo/compare/$base_ref...$head_ref)

EOF
    done < upgraded.log
fi

# updates detected
status="$(git diff)"
if [ -n "$status" ]; then
    echo "Updates detected"

    # configure git authorship
    git config --global user.email $email
    git config --global user.name $username

    # add access to remote repository if not exist
    remote="$(git remote)"
    if [[ "$remote" == "origin" ]]; then
        echo "Configure access to remote repository"
        # format: https://[username]:[token]@github.com/[organization]/[repo].git
        git remote add authenticated "https://$username:$token@github.com/$repo.git"
    fi

    # execute command to run when changes are deteced, if provided
    on_changes_command_value=${on_changes_command%?}
    echo $on_changes_command_value
    if [ -n "$on_changes_command_value" ]; then
        echo "Run post-update command"
        eval $on_changes_command_value
    fi

    # commit the changes to updated files
    if [ -s commit.log ]; then
        git commit -a -F commit.log
    else
        git commit -a -m "Auto-updated dependencies $update_path_value"
    fi

    # push the changes
    git push authenticated -f

    echo "https://api.github.com/repos/$repo/pulls"

    if [ -s commit.log ]; then
        # preparation PR message
        commit="$(cat commit.log | sed -E 's/$/\\n/' | tr -d '\n')"
    fi

    # create the PR
    # if PR already exists, then update
    response=$(curl -X POST -H "Content-Type: application/json" -H "Authorization: token $token" \
         --data '{"title":"'"Autoupdate dependencies $update_path_value"'", "head":"'"$branch_name$branch_path"'", "base":"'"$default_branch"'", "body":"'"$commit"'Auto-generated pull request. \nThis pull request is generated by GitHub action based on the provided update commands."}' \
         "https://api.github.com/repos/$repo/pulls")

    # clean up temporary files
    echo "Clena up temporary files"
    eval "rm -f commit.log upgraded.log"

    if [[ "$response" == *"already exist"* ]]; then
        echo "Pull request already opened. Comment was pushed to the existing PR"
        exit 0
    else
        echo "New pull request created"
        exit 0
    fi
else
    echo "No dependencies updates were detected"
    exit 0
fi
