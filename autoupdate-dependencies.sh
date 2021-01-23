#!/bin/bash

token=$1
update_command=$2
update_path=$3
repo=$GITHUB_REPOSITORY #owner and repository: ie: user/repo
username=$GITHUB_ACTOR

branch_name="automated-dependencies-update"
email="noreply@github.com"

if [ -z "$token" ]; then
    echo "token is not defined"
    exit 1
fi

if [ -z "$update_command" ]; then
    echo "update-command cannot be empty"
    exit 1
fi

if [ -n "$update_path" ]; then
    # if path is set, use that. otherwise default to current working directory
    echo "Change directory to $update_path"
    # TODO cd ${update_path}
fi

echo "Switched to $update_path"
cd './test/go'

# assumes the repo is already cloned as a prerequisite for running the script

# fetch first to be able to detect if branch already exists 
git fetch

branch_exists=git branch --list automated-dependencies-update
branch_exists2= [! -z "git branch --list $branch_name"]
branch_exists3= [-n "git branch --list $branch_name"]

echo "*****************"
echo $branch_exists
echo $branch_exists2
echo $branch_exists3
echo "*****************"

# branch already exists, previous opened PR was not merged
if [ ${#branch_exists} == " ]
then
    echo "Branch name $branch_name already exists"

    echo "Check out branch instead" 
    # check out existing branch
    git checkout $branch_name
    git pull

    # reset with latest from main
    # this avoids merge conflicts when existing changes are not merged
    git reset --hard origin/main
else
    git checkout -b $branch_name
fi

echo "Running update command $update_command"
eval $update_command

if [ -n "git diff" ]
then
    echo "Updates detected"

    # configure git authorship
    git config --global user.email $email
    git config --global user.name $username

    # format: https://[username]:[token]@github.com/[organization]/[repo].git
    git remote add authenticated "https://$username:$token@github.com/$repo.git"

    # commit the changes to updated files
    git commit -a -m "Auto-updated dependencies"
    
    # push the changes
    git push authenticated -f

    echo "https://api.github.com/repos/$repo/pulls"

    # create the PR
    # if PR already exists, then update
    response=$(curl --write-out "%{message}\n" -X POST -H "Content-Type: application/json" -H "Authorization: token $token" \
         --data '{"title":"Autoupdate dependencies","head": "'"$branch_name"'","base":"main", "body":"Auto-generated pull request. \nThis pull request is generated by GitHub action based on the provided update commands."}' \
         "https://api.github.com/repos/$repo/pulls")
    
    echo $response   
    
    if [[ "$response" == *"already exist"* ]]; then
        echo "Pull request already opened. Updates were pushed to the existing PR instead"
        exit 0
    fi
else
    echo "No dependencies updates were detected"
    exit 0
fi
